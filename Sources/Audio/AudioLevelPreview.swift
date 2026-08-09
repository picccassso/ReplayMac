import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import ScreenCaptureKit

/// Drives the live audio level meters while the capture pipeline is idle.
///
/// During recording the meters are fed by the real capture path. When nothing
/// is recording there are no sample buffers at all, so this runs lightweight
/// measurement-only taps instead: an AVAudioEngine tap for the microphone and
/// an audio-only SCStream for system audio. Both are torn down as soon as the
/// capture pipeline takes over, so the two never contend for a device.
@MainActor
public final class AudioLevelPreview {
    public static let shared = AudioLevelPreview()

    public struct Configuration: Equatable, Sendable {
        public var monitorSystemAudio: Bool
        public var monitorMicrophone: Bool
        public var microphoneDeviceID: String
        /// Bundle ID for per-app system audio, or nil to measure all apps.
        public var perAppAudioBundleID: String?
        public var excludeOwnAppAudio: Bool
        public var systemAudioVolume: Double
        public var microphoneVolume: Double

        public init(
            monitorSystemAudio: Bool,
            monitorMicrophone: Bool,
            microphoneDeviceID: String,
            perAppAudioBundleID: String?,
            excludeOwnAppAudio: Bool,
            systemAudioVolume: Double,
            microphoneVolume: Double
        ) {
            self.monitorSystemAudio = monitorSystemAudio
            self.monitorMicrophone = monitorMicrophone
            self.microphoneDeviceID = microphoneDeviceID
            self.perAppAudioBundleID = perAppAudioBundleID
            self.excludeOwnAppAudio = excludeOwnAppAudio
            self.systemAudioVolume = systemAudioVolume
            self.microphoneVolume = microphoneVolume
        }
    }

    private let microphoneTap = MicrophoneLevelTap()
    private let systemAudioTap = SystemAudioLevelTap()

    private var requested: Configuration?
    private var requestedAt: TimeInterval?
    private var isCaptureActive = false

    private var isMicrophoneRunning = false
    private var runningMicrophoneDeviceID = ""
    private var isSystemAudioRunning = false
    private var runningSystemAudioBundleID: String?
    private var runningExcludesOwnAppAudio = false

    private var reconcileTask: Task<Void, Never>?
    private var needsAnotherReconcile = false
    private var heartbeatTask: Task<Void, Never>?

    /// A meter that has gone this long without reading levels is no longer on
    /// screen. Comfortably longer than the meters' 0.1s refresh interval.
    private static let readerTimeout: TimeInterval = 2

    private init() {}

    /// Called by whatever UI is showing meters. Pass nil when it goes away.
    public func setConfiguration(_ configuration: Configuration?) {
        requested = configuration
        requestedAt = configuration == nil ? nil : ProcessInfo.processInfo.systemUptime
        updateHeartbeat()
        scheduleReconcile()
    }

    /// The capture pipeline owns the audio devices while it runs; the preview
    /// stands down for the duration.
    public func setCaptureActive(_ isActive: Bool) {
        guard isCaptureActive != isActive else { return }
        isCaptureActive = isActive
        scheduleReconcile()
    }

    private var effectiveConfiguration: Configuration? {
        guard !isCaptureActive, isAnyMeterReadingLevels else { return nil }
        return requested
    }

    /// Guards against a meter view that never told us it went away — a closed
    /// settings window must not leave the microphone open.
    private var isAnyMeterReadingLevels: Bool {
        // A freshly requested configuration counts as live so the meters start
        // measuring immediately, before their first read lands.
        if let requestedAt, ProcessInfo.processInfo.systemUptime - requestedAt < Self.readerTimeout {
            return true
        }
        guard let elapsed = AudioLevelMonitor.shared.secondsSinceLastSnapshot() else {
            return false
        }
        return elapsed < Self.readerTimeout
    }

    private func updateHeartbeat() {
        guard requested != nil else {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            return
        }
        guard heartbeatTask == nil else { return }

        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.requested != nil, !Task.isCancelled else { return }
                self.scheduleReconcile()
            }
        }
    }

    private func scheduleReconcile() {
        guard reconcileTask == nil else {
            needsAnotherReconcile = true
            return
        }

        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.needsAnotherReconcile = false
                await self.reconcile()
            } while self.needsAnotherReconcile
            self.reconcileTask = nil
        }
    }

    private func reconcile() async {
        let target = effectiveConfiguration

        await reconcileMicrophone(target)
        await reconcileSystemAudio(target)
    }

    private func reconcileMicrophone(_ target: Configuration?) async {
        let wantsMicrophone = (target?.monitorMicrophone ?? false) && Self.isMicrophoneAuthorized
        guard wantsMicrophone, let target else {
            if isMicrophoneRunning {
                stopMicrophoneTap()
            }
            return
        }

        microphoneTap.setVolume(target.microphoneVolume)

        guard !isMicrophoneRunning || runningMicrophoneDeviceID != target.microphoneDeviceID else {
            return
        }

        stopMicrophoneTap()

        do {
            try microphoneTap.start(deviceID: target.microphoneDeviceID)
            isMicrophoneRunning = true
            runningMicrophoneDeviceID = target.microphoneDeviceID
        } catch {
            print("[LEVELS] Microphone level preview unavailable: \(error)")
        }
    }

    private func reconcileSystemAudio(_ target: Configuration?) async {
        guard let target, target.monitorSystemAudio else {
            if isSystemAudioRunning {
                await stopSystemAudioTap()
            }
            return
        }

        systemAudioTap.setVolume(target.systemAudioVolume)

        let isRunningWithSameSource = isSystemAudioRunning
            && runningSystemAudioBundleID == target.perAppAudioBundleID
            && runningExcludesOwnAppAudio == target.excludeOwnAppAudio
        guard !isRunningWithSameSource else {
            return
        }

        await stopSystemAudioTap()

        do {
            try await systemAudioTap.start(
                bundleID: target.perAppAudioBundleID,
                excludeOwnAppAudio: target.excludeOwnAppAudio
            )
            isSystemAudioRunning = true
            runningSystemAudioBundleID = target.perAppAudioBundleID
            runningExcludesOwnAppAudio = target.excludeOwnAppAudio
        } catch {
            print("[LEVELS] System audio level preview unavailable: \(error)")
        }
    }

    private func stopMicrophoneTap() {
        microphoneTap.stop()
        isMicrophoneRunning = false
        runningMicrophoneDeviceID = ""
        AudioLevelMonitor.shared.resetMicrophone()
    }

    private func stopSystemAudioTap() async {
        await systemAudioTap.stop()
        isSystemAudioRunning = false
        runningSystemAudioBundleID = nil
        AudioLevelMonitor.shared.resetSystemAudio()
    }

    /// Never prompts: the preview is a passive convenience, so an ungranted
    /// mic simply leaves the meter flat until recording asks for access.
    private static var isMicrophoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

/// Measurement-only microphone tap. Deliberately independent of `MicCapture`
/// so preview never touches the recording engine's timing state.
private final class MicrophoneLevelTap: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var volume: Double = 1
    private var isRunning = false

    func setVolume(_ volume: Double) {
        lock.lock()
        self.volume = volume
        lock.unlock()
    }

    func start(deviceID: String?) throws {
        stop()

        if let deviceID, !deviceID.isEmpty {
            try AudioDeviceLookup.applyInputDevice(uid: deviceID, to: engine)
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicCaptureError.cannotCreateTargetFormat
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let volume = self.volume
            let isRunning = self.isRunning
            self.lock.unlock()
            guard isRunning, let rms = Self.rootMeanSquare(of: buffer) else { return }

            let level = AudioLevelMonitor.normalizedLevel(forRootMeanSquare: rms * volume)
            AudioLevelMonitor.shared.recordMicrophone(level: level)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicCaptureError.engineStartFailed(error)
        }

        lock.lock()
        isRunning = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let wasRunning = isRunning
        isRunning = false
        lock.unlock()
        guard wasRunning else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func rootMeanSquare(of buffer: AVAudioPCMBuffer) -> Double? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let stride = buffer.stride

        var sumOfSquares = 0.0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let sample = Double(samples[frame * stride])
                sumOfSquares += sample * sample
            }
        }

        return sqrt(sumOfSquares / Double(frameCount * channelCount))
    }
}

/// Audio-only SCStream used to measure system audio while idle. The video
/// configuration is deliberately tiny and slow, and no screen output is added,
/// so the stream costs close to nothing.
private final class SystemAudioLevelTap: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.replaycap.audio-level-preview", qos: .utility)
    private let lock = NSLock()
    private var stream: SCStream?
    private var volume: Double = 1

    func setVolume(_ volume: Double) {
        lock.lock()
        self.volume = volume
        lock.unlock()
    }

    func start(bundleID: String?, excludeOwnAppAudio: Bool) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw PerAppAudioCaptureError.noDisplay
        }

        let filter: SCContentFilter
        if let bundleID, !bundleID.isEmpty {
            let matches = content.applications.filter { $0.bundleIdentifier == bundleID }
            guard !matches.isEmpty else {
                throw PerAppAudioCaptureError.appNotFound(bundleID)
            }
            filter = SCContentFilter(display: display, including: matches, exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = excludeOwnAppAudio

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await newStream.startCapture()
        stream = newStream
    }

    func stop() async {
        guard let activeStream = stream else { return }
        stream = nil
        try? await activeStream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              let rms = AudioLevelMonitor.rootMeanSquare(of: sampleBuffer) else {
            return
        }

        lock.lock()
        let volume = self.volume
        lock.unlock()

        let level = AudioLevelMonitor.normalizedLevel(forRootMeanSquare: rms * volume)
        AudioLevelMonitor.shared.recordSystemAudio(level: level)
    }
}
