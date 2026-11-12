import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import os.log

public enum CameraCaptureError: Error, Sendable {
    /// `AVCaptureDevice.authorizationStatus(for: .video)` was not `.authorized`
    /// when `start` was called. The caller decides how to prompt (just-in-time
    /// only — never at launch, never polled).
    case permissionDenied
    /// No video device exists at all (headless Mac, all cameras unplugged).
    case noDeviceAvailable
    /// `AVCaptureDevice(uniqueID:)` returned nil for the requested ID.
    case deviceNotFound(String)
    case inputFailed(Error)
    case outputFailed(Error)
    case sessionStartFailed(Error)
    case sessionRuntimeError(Error)
    /// The requested camera was unplugged mid-recording.
    case deviceDisconnected(String)
}

/// One enumerated camera. `uniqueID` persists across reconnects and reboots,
/// so it is the right thing to store in user defaults.
public struct CameraDeviceInfo: Sendable, Identifiable, Hashable {
    public let uniqueID: String
    public let localizedName: String
    public let isContinuityCamera: Bool
    public var id: String { uniqueID }

    public init(uniqueID: String, localizedName: String, isContinuityCamera: Bool) {
        self.uniqueID = uniqueID
        self.localizedName = localizedName
        self.isContinuityCamera = isContinuityCamera
    }
}

/// Captures webcam video via `AVCaptureSession` + `AVCaptureVideoDataOutput` and
/// hands raw `CMSampleBuffer`s (32BGRA, which the compositor draws from) to a
/// frame handler.
///
/// Patterned on `MicCapture`: all mutable state sits behind `lock`, all session
/// work happens on the private serial queue `com.replaycap.camera` (Apple
/// requires a serial delegate queue so frames arrive in order), and device
/// disconnect/reconnect recovery is an epoch-guarded restart with exponential
/// backoff — a retry queued against a stopped/started run can never tear down
/// a later session.
///
/// Frames are delivered on the serial queue; the handler must not block.
/// `alwaysDiscardsLateVideoFrames = true` plus `activeVideoMinFrameDuration =
/// 1/30` cap the camera at 30 fps and drop late frames instead of queueing,
/// so a slow compositor can never back up the camera pipeline.
public final class CameraCapture: @unchecked Sendable {
    // @unchecked: mutable state is only touched inside `lock`; session work runs on `sessionQueue`.
    public typealias FrameHandler = @Sendable (CMSampleBuffer) -> Void
    public typealias ErrorHandler = @Sendable (CameraCaptureError) -> Void

    /// Rebuild attempts for a reconnected device. The device is often briefly
    /// unavailable right after it comes back, so the first try can fail.
    private static let maximumRebuildAttempts = 5

    /// Backoff cap for rebuild retries, mirroring `MicCapture`:
    /// `min(0.5 * 2^attempt, 4)` seconds.
    private static func rebuildDelay(attempt: Int) -> TimeInterval {
        min(0.5 * pow(2, Double(attempt)), 4)
    }

    /// Serial queue for all session work AND delegate callbacks (Apple's
    /// requirement for `AVCaptureVideoDataOutput` sample buffer delivery).
    private let sessionQueue = DispatchQueue(label: "com.replaycap.camera", qos: .userInitiated)
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.replaycap", category: "CameraCapture")
    private let delegate = CameraCaptureDelegate()

    private var frameHandler: FrameHandler?
    private var errorHandler: ErrorHandler?

    private var session: AVCaptureSession?
    private var deviceInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var activeDevice: AVCaptureDevice?

    private var running = false
    /// The device ID the caller asked for, retained so a rebuild can re-bind it.
    private var requestedDeviceID: String?
    /// The resolved device's uniqueID; disconnect/connect notifications are
    /// filtered against it.
    private var activeDeviceID: String?
    private var requestedResolution: CameraCaptureResolution = .hd720p30

    /// When the last frame was delivered. Never set by a rebuild.
    private var lastFrameUptime: TimeInterval?

    private var isRestarting = false
    /// Invalidates in-flight rebuild retries. `stop` and `start` bump it so a
    /// retry queued against a previous run cannot tear down a later session.
    private var restartEpoch = 0

    private var observers: [NSObjectProtocol] = []

    public init() {
        delegate.owner = self
    }

    // MARK: - Permission (TCC)

    /// Current camera authorization status. Polling this never triggers a
    /// system prompt — only `requestAccess()` on `.notDetermined` does.
    public static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Asks for camera permission. Call just-in-time only (when the user first
    /// enables the overlay / starts a recording with it), never at launch and
    /// never in a loop.
    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// All video devices Apple exposes to us. On macOS the list is empty until
    /// camera permission is granted, so callers should gate this on
    /// `authorizationStatus() == .authorized`.
    public static func availableDevices() -> [CameraDeviceInfo] {
        discoverySession().devices.map {
            CameraDeviceInfo(
                uniqueID: $0.uniqueID,
                localizedName: $0.localizedName,
                isContinuityCamera: $0.deviceType == .continuityCamera
            )
        }
    }

    private static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
    }

    // MARK: - State

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public func setFrameHandler(_ handler: FrameHandler?) {
        lock.lock()
        frameHandler = handler
        lock.unlock()
    }

    public func setErrorHandler(_ handler: ErrorHandler?) {
        lock.lock()
        errorHandler = handler
        lock.unlock()
    }

    /// Age of the most recently delivered frame, or nil if none has arrived
    /// since `start`.
    public func secondsSinceLastFrame() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastFrameUptime else { return nil }
        return max(0, ProcessInfo.processInfo.systemUptime - lastFrameUptime)
    }

    // MARK: - Lifecycle

    /// Starts capture. Throws `.permissionDenied` unless camera access is
    /// already `.authorized` (the caller owns prompting), `.noDeviceAvailable`
    /// / `.deviceNotFound` for an unusable `deviceID` (nil/empty = system
    /// default video device).
    public func start(deviceID: String? = nil, resolution: CameraCaptureResolution = .hd720p30) throws {
        guard Self.authorizationStatus() == .authorized else {
            throw CameraCaptureError.permissionDenied
        }
        let device = try Self.resolveDevice(deviceID: deviceID)

        lock.lock()
        requestedDeviceID = deviceID
        requestedResolution = resolution
        activeDeviceID = device.uniqueID
        // Retire any retry still queued against a previous run.
        restartEpoch += 1
        isRestarting = false
        lock.unlock()

        var startError: Error?
        sessionQueue.sync {
            do {
                try self.buildAndStartSession(device: device, resolution: resolution)
            } catch {
                startError = error
            }
        }
        if let startError {
            lock.lock()
            session = nil
            deviceInput = nil
            videoOutput = nil
            activeDevice = nil
            activeDeviceID = nil
            lock.unlock()
            throw startError
        }

        lock.lock()
        running = true
        lastFrameUptime = nil
        lock.unlock()

        installObservers()
        logger.info("Camera capture started: \(device.localizedName, privacy: .public) \(resolution.rawValue, privacy: .public)")
    }

    /// Tears down the session, removes observers, and retires in-flight
    /// retries. Safe to call when not running.
    public func stop() {
        removeObservers()

        lock.lock()
        running = false
        // Always retire in-flight retries, even on a stop that finds nothing
        // running: a failed rebuild may still have one queued.
        restartEpoch += 1
        isRestarting = false
        requestedDeviceID = nil
        activeDeviceID = nil
        lastFrameUptime = nil
        lock.unlock()

        sessionQueue.async { [weak self] in
            self?.teardownSession()
        }
    }

    // MARK: - Session construction

    private static func resolveDevice(deviceID: String?) throws -> AVCaptureDevice {
        if let deviceID, !deviceID.isEmpty {
            guard let device = AVCaptureDevice(uniqueID: deviceID) else {
                throw CameraCaptureError.deviceNotFound(deviceID)
            }
            return device
        }
        // "Default" prefers the built-in camera, but Mac mini/Studio/Pro have
        // none and a MacBook with its lid closed hides it, so fall back to the
        // system's default video device and then to any camera the picker
        // lists (USB or Continuity Camera).
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
            ?? discoverySession().devices.first {
            return device
        }
        throw CameraCaptureError.noDeviceAvailable
    }

    /// Builds and starts a session for `device`. Must be called on `sessionQueue`.
    private func buildAndStartSession(device: AVCaptureDevice, resolution: CameraCaptureResolution) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let preset = resolution.sessionPreset
        guard session.canSetSessionPreset(preset) else {
            throw CameraCaptureError.sessionStartFailed(
                Self.makeError(code: -1, description: "session cannot use preset \(preset)")
            )
        }
        session.sessionPreset = preset

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraCaptureError.inputFailed(error)
        }
        guard session.canAddInput(input) else {
            throw CameraCaptureError.inputFailed(
                Self.makeError(code: -2, description: "session cannot add camera input")
            )
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // 32BGRA: the compositor reads camera frames through Core Image.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // Drop late frames instead of queueing them: the overlay only ever
        // needs the newest frame.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: sessionQueue)
        guard session.canAddOutput(output) else {
            throw CameraCaptureError.outputFailed(
                Self.makeError(code: -3, description: "session cannot add video output")
            )
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            // Cap the camera at 30 fps regardless of the preset. On macOS the
            // connection-level property is `videoMinFrameDuration` (the
            // `activeVideoMinFrameDuration` name is iOS-only).
            connection.videoMinFrameDuration = CMTime(value: 1, timescale: 30)
            // FaceTime-style mirroring for front cameras only.
            connection.isVideoMirrored = device.position == .front
        }

        session.commitConfiguration()

        // Without a floor, macOS lowers the frame rate in dim light to
        // lengthen exposure (often to 15 fps or less), which makes the overlay
        // stutter. Hold the device at 30 fps instead; the image gets a little
        // darker in a dim room but stays smooth. The lock is held across
        // `startRunning` so the session doesn't reset the duration to the
        // format default when it starts.
        let lockedFrameRate = lockMinimumFrameRate(device)
        session.startRunning()
        if lockedFrameRate {
            device.unlockForConfiguration()
        }

        lock.lock()
        self.session = session
        self.deviceInput = input
        self.videoOutput = output
        self.activeDevice = device
        lock.unlock()
    }

    /// Sets `activeVideoMaxFrameDuration` to 1/30 s when the active format
    /// supports 30 fps. Returns true if the device was left locked for
    /// configuration (the caller unlocks it after `startRunning`). Invalid
    /// values raise an Objective-C exception, so every precondition is
    /// checked first; any failure just leaves the device's default.
    private func lockMinimumFrameRate(_ device: AVCaptureDevice) -> Bool {
        let target = CMTime(value: 1, timescale: 30)
        guard !device.isAutoVideoFrameRateEnabled,
              device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                  $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
              }) else {
            logger.info("Camera format does not support a 30 fps floor; keeping the device default")
            return false
        }
        do {
            try device.lockForConfiguration()
        } catch {
            logger.warning("Could not lock camera for configuration: \(String(describing: error), privacy: .public)")
            return false
        }
        // The format supports 30 fps (checked above), so 1/30 s is never
        // shorter than its minimum frame duration.
        device.activeVideoMaxFrameDuration = target
        return true
    }

    /// Stops and dismantles the current session. Must be called on `sessionQueue`.
    private func teardownSession() {
        lock.lock()
        let session = self.session
        let output = self.videoOutput
        lock.unlock()

        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        if let session {
            for input in session.inputs {
                session.removeInput(input)
            }
            for out in session.outputs {
                session.removeOutput(out)
            }
        }

        lock.lock()
        self.session = nil
        self.deviceInput = nil
        self.videoOutput = nil
        self.activeDevice = nil
        lock.unlock()
    }

    private static func makeError(code: Int, description: String) -> NSError {
        NSError(domain: "com.replaycap.camera", code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }

    // MARK: - Delegate callbacks (sessionQueue)

    /// Called by the delegate object (same file) on the serial session queue.
    fileprivate func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        let handler = frameHandler
        lock.unlock()
        handler?(sampleBuffer)
    }

    private func handleSessionError(_ error: Error) {
        logger.error("Camera session failed: \(String(describing: error), privacy: .public)")
        reportError(.sessionRuntimeError(error))
    }

    /// macOS delivers session runtime errors via
    /// `AVCaptureSession.runtimeErrorNotification` (there is no
    /// `AVCaptureSessionDelegate` on macOS); the userInfo carries the NSError
    /// under `AVCaptureSessionErrorKey`.
    private func handleSessionRuntimeError(_ notification: Notification) {
        lock.lock()
        let currentSession = session
        lock.unlock()
        // Only react to errors from the session this run owns.
        if let errorSession = notification.object as? AVCaptureSession, errorSession !== currentSession {
            return
        }
        let error = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError) ??
            Self.makeError(code: -1, description: "camera session runtime error")
        handleSessionError(error)
    }

    private func reportError(_ error: CameraCaptureError) {
        lock.lock()
        let handler = errorHandler
        lock.unlock()
        handler?(error)
    }

    // MARK: - Device hot-plug observers

    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        let disconnected = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            self?.handleDeviceDisconnected(device)
        }
        let connected = center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            self?.handleDeviceConnected(device)
        }
        let interrupted = center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionWasInterrupted(notification)
        }
        let interruptionEnded = center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterruptionEnded(notification)
        }
        let runtimeError = center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionRuntimeError(notification)
        }
        lock.lock()
        observers = [disconnected, connected, interrupted, interruptionEnded, runtimeError]
        lock.unlock()
    }

    private func removeObservers() {
        lock.lock()
        let current = observers
        observers = []
        lock.unlock()
        for observer in current {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Only react to the device this run was started with.
    private func isRequestedDevice(_ device: AVCaptureDevice) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return device.uniqueID == activeDeviceID
    }

    private func handleDeviceDisconnected(_ device: AVCaptureDevice) {
        guard isRequestedDevice(device) else { return }
        lock.lock()
        let wasRunning = running
        let handler = errorHandler
        lock.unlock()
        guard wasRunning else { return }

        logger.error("Camera device disconnected: \(device.uniqueID, privacy: .public)")
        sessionQueue.async { [weak self] in
            self?.teardownSession()
        }
        handler?(.deviceDisconnected(device.uniqueID))
    }

    private func handleDeviceConnected(_ device: AVCaptureDevice) {
        guard isRequestedDevice(device) else { return }
        lock.lock()
        let wasRunning = running
        lock.unlock()
        guard wasRunning else { return }

        logger.info("Camera device reconnected: \(device.uniqueID, privacy: .public); rebuilding session")
        scheduleRebuild()
    }

    // MARK: - Reconnect rebuild (epoch-guarded, backoff — mirrors MicCapture)

    /// Returns false when a rebuild is already in flight or the camera is stopped.
    @discardableResult
    private func scheduleRebuild() -> Bool {
        lock.lock()
        guard running, !isRestarting else {
            lock.unlock()
            return false
        }
        isRestarting = true
        let epoch = restartEpoch
        lock.unlock()

        sessionQueue.async { [weak self] in
            self?.performRebuild(attempt: 0, epoch: epoch)
        }
        return true
    }

    private func performRebuild(attempt: Int, epoch: Int) {
        lock.lock()
        let isRunning = running
        let deviceID = requestedDeviceID
        let resolution = requestedResolution
        let isCurrent = epoch == restartEpoch
        // Only the run that owns this epoch may clear the flag; a retired
        // retry must not unlatch a rebuild belonging to a later run.
        if !isRunning || !isCurrent {
            if isCurrent {
                isRestarting = false
            }
            lock.unlock()
            return
        }
        lock.unlock()

        teardownSession()

        do {
            let device = try Self.resolveDevice(deviceID: deviceID)
            try buildAndStartSession(device: device, resolution: resolution)
            lock.lock()
            activeDeviceID = device.uniqueID
            // `stop` may have landed while the session was being rebuilt; the
            // rebuilt session has to come straight back down in that case.
            let superseded = !running || epoch != restartEpoch
            if !superseded {
                isRestarting = false
            }
            lock.unlock()
            if superseded {
                teardownSession()
            } else {
                logger.info("Camera session rebuilt after reconnect (attempt \(attempt + 1, privacy: .public))")
            }
            return
        } catch {
            logger.error(
                "Camera rebuild attempt \(attempt + 1, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }

        let nextAttempt = attempt + 1
        guard nextAttempt < Self.maximumRebuildAttempts else {
            logger.error("Camera rebuild gave up after \(Self.maximumRebuildAttempts, privacy: .public) attempts")
            lock.lock()
            if epoch == restartEpoch {
                isRestarting = false
            }
            let handler = errorHandler
            let deviceID = activeDeviceID ?? requestedDeviceID ?? ""
            lock.unlock()
            handler?(.deviceDisconnected(deviceID))
            return
        }

        // The device is often still settling right after it reconnects.
        let delay = Self.rebuildDelay(attempt: attempt)
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performRebuild(attempt: nextAttempt, epoch: epoch)
        }
    }

    // MARK: - Session interruption notifications

    private func handleSessionWasInterrupted(_ notification: Notification) {
        // `AVCaptureSessionInterruptionReasonKey` is iOS-only; on macOS the
        // userInfo simply carries no reason.
        let reason = notification.userInfo?["AVCaptureSessionInterruptionReasonKey"] as? Int ?? -1
        logger.warning("Camera session interrupted (reason \(reason, privacy: .public)); it resumes automatically")
        reportError(.sessionRuntimeError(
            Self.makeError(code: reason, description: "Camera session was interrupted (reason \(reason))")
        ))
    }

    private func handleSessionInterruptionEnded(_ notification: Notification) {
        logger.info("Camera session interruption ended; session resumes automatically")
        reportError(.sessionRuntimeError(
            Self.makeError(code: 0, description: "Camera session interruption ended")
        ))
    }
}

/// Maps the persisted resolution enum onto the session preset. Kept here (not
/// in `CameraOverlayLayout.swift`) so the layout file stays free of
/// AVFoundation and purely testable.
extension CameraCaptureResolution {
    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd720p30: return .hd1280x720
        case .hd1080p30: return .hd1920x1080
        }
    }
}

/// ObjC delegate target. Sample-buffer callbacks arrive on `sessionQueue` (the
/// serial queue the output was given) and are forwarded into the owning
/// `CameraCapture`. Session-level failures on macOS arrive as notifications
/// (see `installObservers`).
private final class CameraCaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // @unchecked: only ever touched from `sessionQueue` / via the owner's lock.
    weak var owner: CameraCapture?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        owner?.handleSampleBuffer(sampleBuffer)
    }
}
