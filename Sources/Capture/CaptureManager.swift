import ScreenCaptureKit
import CoreMedia
import CoreVideo
import os.log

public struct CaptureConfig: Sendable {
    public let width: Int
    public let height: Int
    public let fps: Int
}

public actor CaptureManager {
    private var stream: SCStream?
    private nonisolated let delegate = CaptureDelegate()
    private let videoQueue = DispatchQueue(label: "com.replaymac.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.replaymac.audio", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.replaymac", category: "Capture")

    private var currentFilter: SCContentFilter?
    private var currentConfiguration: SCStreamConfiguration?
    private var restartAttempts: [Date] = []
    private var userInitiatedStop = false
    private let maxRestartAttempts = 5
    private let restartWindowSeconds: TimeInterval = 60

    private var interruptionHandler: (@Sendable (CaptureInterruption) -> Void)?

    public init() {}

    public func setVideoHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        delegate.setVideoHandler(handler)
    }

    public func setAudioHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        delegate.setAudioHandler(handler)
    }

    public nonisolated func captureStats() -> CaptureStats {
        delegate.snapshot()
    }

    public func setInterruptionHandler(
        _ handler: @escaping @Sendable (CaptureInterruption) -> Void
    ) {
        interruptionHandler = handler
    }

    public func activateDelegateCallbacks() {
        delegate.setStreamStoppedHandler { [weak self] error in
            guard let self else { return }
            Task {
                await self.handleStreamStopped(error: error)
            }
        }
    }

    @discardableResult
    public func start(interactivePermissionPrompt: Bool = true, fps: Int, queueDepth: Int) async throws -> CaptureConfig {
        let permissions = CapturePermissions()
        let content = try await permissions.requestAccess(interactive: interactivePermissionPrompt)

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = queueDepth
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = true
        // Known macOS 15 issue: setting this to true can cause SCK to deliver
        // ~1.3s of audio then stop. Leave false for now.
        config.excludesCurrentProcessAudio = false

        let newStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try newStream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: videoQueue)
        try newStream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()

        userInitiatedStop = false
        restartAttempts.removeAll()
        currentFilter = filter
        currentConfiguration = config
        self.stream = newStream

        return CaptureConfig(width: Int(display.width), height: Int(display.height), fps: fps)
    }

    public nonisolated func stop() {
        Task {
            await performStop()
        }
    }

    private func performStop() async {
        userInitiatedStop = true
        try? await stream?.stopCapture()
        stream = nil
        currentFilter = nil
        currentConfiguration = nil
        restartAttempts.removeAll()
        userInitiatedStop = false
    }

    private func handleStreamStopped(error: Error) async {
        guard !userInitiatedStop else {
            return
        }

        let nsError = error as NSError
        if nsError.code == -3821 {
            await attemptRestartAfterGPUDisconnect()
            return
        }

        let message = nsError.localizedDescription.lowercased()
        if message.contains("permission") || message.contains("denied") {
            interruptionHandler?(.permissionRevoked)
        } else if message.contains("display") || message.contains("disconnected") {
            interruptionHandler?(.displayDisconnected)
        } else {
            interruptionHandler?(.stopped(nsError.localizedDescription))
        }

        await performStop()
    }

    private func attemptRestartAfterGPUDisconnect() async {
        let now = Date()
        restartAttempts = restartAttempts.filter { now.timeIntervalSince($0) <= restartWindowSeconds }

        guard restartAttempts.count < maxRestartAttempts else {
            logger.error("Capture restart halted after repeated -3821 failures")
            interruptionHandler?(.gpuPressurePaused)
            await performStop()
            return
        }

        restartAttempts.append(now)
        logger.error("Received SCK -3821. Restart attempt \(self.restartAttempts.count)")

        do {
            try await Task.sleep(for: .milliseconds(500))
        } catch {
            return
        }

        do {
            try await recreateStreamFromCurrentConfiguration()
            logger.info("Capture stream restarted after SCK -3821")
            interruptionHandler?(.restartedAfterGPUPressure)
        } catch {
            logger.error("Capture restart failed: \(error.localizedDescription, privacy: .public)")
            interruptionHandler?(.stopped("Restart failed: \(error.localizedDescription)"))
        }
    }

    private func recreateStreamFromCurrentConfiguration() async throws {
        guard let filter = currentFilter, let configuration = currentConfiguration else {
            throw CaptureRestartError.missingConfiguration
        }

        try? await stream?.stopCapture()
        stream = nil

        let replacement = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try replacement.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: videoQueue)
        try replacement.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: audioQueue)
        try await replacement.startCapture()
        stream = replacement
    }
}

public enum CaptureInterruption: Sendable {
    case restartedAfterGPUPressure
    case gpuPressurePaused
    case permissionRevoked
    case displayDisconnected
    case stopped(String)
}

public enum CaptureRestartError: Error {
    case missingConfiguration
}

public enum CaptureError: Error {
    case noDisplay
}
