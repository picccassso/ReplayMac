import ScreenCaptureKit
import CoreMedia
import CoreVideo
import os.log

public struct CaptureConfig: Sendable {
    public let width: Int
    public let height: Int
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let fps: Int
}

public struct CaptureResolutionConfig: Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public actor CaptureManager {
    // Single-display state
    private var stream: SCStream?
    private nonisolated let delegate = CaptureDelegate()

    // Dual-display state
    private var stream1: SCStream?
    private var stream2: SCStream?
    private nonisolated let delegate1 = CaptureDelegate()
    private nonisolated let delegate2 = CaptureDelegate()

    private let videoQueue = DispatchQueue(label: "com.replaymac.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.replaymac.audio", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.replaymac", category: "Capture")

    // Single-display config for restart
    private var currentFilter: SCContentFilter?
    private var currentConfiguration: SCStreamConfiguration?

    // Dual-display config for restart
    private var dualFilter1: SCContentFilter?
    private var dualFilter2: SCContentFilter?
    private var dualConfiguration1: SCStreamConfiguration?
    private var dualConfiguration2: SCStreamConfiguration?

    private var isDualMode = false
    private var restartAttempts: [Date] = []
    private var userInitiatedStop = false
    private let maxRestartAttempts = 5
    private let restartWindowSeconds: TimeInterval = 60

    private var interruptionHandler: (@Sendable (CaptureInterruption) -> Void)?

    public init() {}

    // MARK: - SCK Configuration updates

    public func updateStreamConfiguration(
        fps: Int,
        queueDepth: Int,
        excludeOwnAppAudio: Bool,
        resolution: CaptureResolutionConfig? = nil
    ) async throws {
        guard !isDualMode else { return }
        guard let activeStream = stream, let currentConfig = currentConfiguration else {
            throw CaptureRestartError.missingConfiguration
        }

        let config = SCStreamConfiguration()
        config.width = resolution?.width ?? currentConfig.width
        config.height = resolution?.height ?? currentConfig.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = queueDepth
        config.pixelFormat = currentConfig.pixelFormat
        config.capturesAudio = currentConfig.capturesAudio
        config.excludesCurrentProcessAudio = excludeOwnAppAudio

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            activeStream.updateConfiguration(config) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        self.currentConfiguration = config
    }

    public func updateDualStreamConfigurations(
        fps: Int,
        queueDepth: Int,
        excludeOwnAppAudio: Bool,
        resolution1: CaptureResolutionConfig? = nil,
        resolution2: CaptureResolutionConfig? = nil
    ) async throws {
        guard isDualMode else { return }
        guard let activeStream1 = stream1,
              let activeStream2 = stream2,
              let currentConfig1 = dualConfiguration1,
              let currentConfig2 = dualConfiguration2 else {
            throw CaptureRestartError.missingConfiguration
        }

        let config1 = SCStreamConfiguration()
        config1.width = resolution1?.width ?? currentConfig1.width
        config1.height = resolution1?.height ?? currentConfig1.height
        config1.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config1.queueDepth = queueDepth
        config1.pixelFormat = currentConfig1.pixelFormat
        config1.capturesAudio = currentConfig1.capturesAudio
        config1.excludesCurrentProcessAudio = excludeOwnAppAudio

        let config2 = SCStreamConfiguration()
        config2.width = resolution2?.width ?? currentConfig2.width
        config2.height = resolution2?.height ?? currentConfig2.height
        config2.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config2.queueDepth = queueDepth
        config2.pixelFormat = currentConfig2.pixelFormat
        config2.capturesAudio = currentConfig2.capturesAudio
        config2.excludesCurrentProcessAudio = excludeOwnAppAudio

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            activeStream1.updateConfiguration(config1) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            activeStream2.updateConfiguration(config2) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        self.dualConfiguration1 = config1
        self.dualConfiguration2 = config2
    }

    // MARK: - Single-display handlers (backward compatible)

    public func setVideoHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        delegate.setVideoHandler(handler)
    }

    public func setAudioHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        delegate.setAudioHandler(handler)
    }

    // MARK: - Dual-display handlers

    public func setVideoHandler1(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        delegate1.setVideoHandler(handler)
    }

    public func setVideoHandler2(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        delegate2.setVideoHandler(handler)
    }

    public func setAudioHandler1(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        delegate1.setAudioHandler(handler)
    }

    // MARK: - Stats

    public nonisolated func captureStats() -> CaptureStats {
        delegate.snapshot()
    }

    public nonisolated func captureStats1() -> CaptureStats {
        delegate1.snapshot()
    }

    // MARK: - Interruption handler

    public func setInterruptionHandler(
        _ handler: @escaping @Sendable (CaptureInterruption) -> Void
    ) {
        interruptionHandler = handler
    }

    public func activateDelegateCallbacks() {
        delegate.setStreamStoppedHandler { [weak self] error in
            guard let self else { return }
            Task {
                await self.handleStreamStopped(error: error, isDual: false)
            }
        }
        delegate1.setStreamStoppedHandler { [weak self] error in
            guard let self else { return }
            Task {
                await self.handleStreamStopped(error: error, isDual: true, streamLabel: "1")
            }
        }
        delegate2.setStreamStoppedHandler { [weak self] error in
            guard let self else { return }
            Task {
                await self.handleStreamStopped(error: error, isDual: true, streamLabel: "2")
            }
        }
    }

    // MARK: - Start single display

    @discardableResult
    public func start(
        interactivePermissionPrompt: Bool = true,
        captureDisplayID: String? = nil,
        fps: Int,
        queueDepth: Int,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        excludeOwnAppAudio: Bool = false
    ) async throws -> CaptureConfig {
        let permissions = CapturePermissions()
        let content = try await permissions.requestAccess(interactive: interactivePermissionPrompt)

        let selectedDisplay = content.displays.first { display in
            String(display.displayID) == captureDisplayID
        }

        guard let display = selectedDisplay ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let captureWidth = outputWidth ?? Int(display.width)
        let captureHeight = outputHeight ?? Int(display.height)

        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = queueDepth
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = excludeOwnAppAudio

        let newStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try newStream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: videoQueue)
        try newStream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()

        userInitiatedStop = false
        isDualMode = false
        restartAttempts.removeAll()
        currentFilter = filter
        currentConfiguration = config
        self.stream = newStream

        return CaptureConfig(
            width: captureWidth,
            height: captureHeight,
            sourceWidth: Int(display.width),
            sourceHeight: Int(display.height),
            fps: fps
        )
    }

    // MARK: - Start dual display

    @discardableResult
    public func startDual(
        interactivePermissionPrompt: Bool = true,
        captureDisplayID1: String? = nil,
        captureDisplayID2: String? = nil,
        fps: Int,
        queueDepth: Int,
        outputWidth1: Int? = nil,
        outputHeight1: Int? = nil,
        outputWidth2: Int? = nil,
        outputHeight2: Int? = nil,
        excludeOwnAppAudio: Bool = false
    ) async throws -> (config1: CaptureConfig, config2: CaptureConfig) {
        let permissions = CapturePermissions()
        let content = try await permissions.requestAccess(interactive: interactivePermissionPrompt)

        let displays = content.displays
        guard displays.count >= 2 else {
            throw CaptureError.notEnoughDisplays
        }

        let selectedDisplay1 = displays.first { String($0.displayID) == captureDisplayID1 }
            ?? displays.first
        let remainingDisplays = displays.filter { $0.displayID != selectedDisplay1?.displayID }
        let selectedDisplay2 = remainingDisplays.first { String($0.displayID) == captureDisplayID2 }
            ?? remainingDisplays.first

        guard let display1 = selectedDisplay1, let display2 = selectedDisplay2 else {
            throw CaptureError.noDisplay
        }

        if display1.displayID == display2.displayID {
            throw CaptureError.sameDisplay
        }

        let filter1 = SCContentFilter(display: display1, excludingApplications: [], exceptingWindows: [])
        let filter2 = SCContentFilter(display: display2, excludingApplications: [], exceptingWindows: [])

        let capWidth1 = outputWidth1 ?? Int(display1.width)
        let capHeight1 = outputHeight1 ?? Int(display1.height)
        let capWidth2 = outputWidth2 ?? Int(display2.width)
        let capHeight2 = outputHeight2 ?? Int(display2.height)

        let config1 = SCStreamConfiguration()
        config1.width = capWidth1
        config1.height = capHeight1
        config1.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config1.queueDepth = queueDepth
        config1.pixelFormat = kCVPixelFormatType_32BGRA
        config1.capturesAudio = true
        config1.excludesCurrentProcessAudio = excludeOwnAppAudio

        let config2 = SCStreamConfiguration()
        config2.width = capWidth2
        config2.height = capHeight2
        config2.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config2.queueDepth = queueDepth
        config2.pixelFormat = kCVPixelFormatType_32BGRA
        config2.capturesAudio = false

        let newStream1 = SCStream(filter: filter1, configuration: config1, delegate: delegate1)
        try newStream1.addStreamOutput(delegate1, type: .screen, sampleHandlerQueue: videoQueue)
        try newStream1.addStreamOutput(delegate1, type: .audio, sampleHandlerQueue: audioQueue)

        let newStream2 = SCStream(filter: filter2, configuration: config2, delegate: delegate2)
        try newStream2.addStreamOutput(delegate2, type: .screen, sampleHandlerQueue: videoQueue)

        try await newStream1.startCapture()
        try await newStream2.startCapture()

        userInitiatedStop = false
        isDualMode = true
        restartAttempts.removeAll()
        dualFilter1 = filter1
        dualFilter2 = filter2
        dualConfiguration1 = config1
        dualConfiguration2 = config2
        self.stream1 = newStream1
        self.stream2 = newStream2

        return (
            config1: CaptureConfig(
                width: capWidth1,
                height: capHeight1,
                sourceWidth: Int(display1.width),
                sourceHeight: Int(display1.height),
                fps: fps
            ),
            config2: CaptureConfig(
                width: capWidth2,
                height: capHeight2,
                sourceWidth: Int(display2.width),
                sourceHeight: Int(display2.height),
                fps: fps
            )
        )
    }

    // MARK: - Stop

    public func stop() async {
        await performStop()
    }

    private func performStop() async {
        userInitiatedStop = true

        if isDualMode {
            try? await stream1?.stopCapture()
            try? await stream2?.stopCapture()
            stream1 = nil
            stream2 = nil
            dualFilter1 = nil
            dualFilter2 = nil
            dualConfiguration1 = nil
            dualConfiguration2 = nil
        } else {
            try? await stream?.stopCapture()
            stream = nil
            currentFilter = nil
            currentConfiguration = nil
        }

        restartAttempts.removeAll()
        isDualMode = false
        userInitiatedStop = false
    }

    // MARK: - Stream stopped handler

    private func handleStreamStopped(error: Error, isDual: Bool, streamLabel: String = "") async {
        guard !userInitiatedStop else {
            return
        }

        let nsError = error as NSError
        if nsError.code == -3821 {
            await attemptRestartAfterGPUDisconnect(isDual: isDual, streamLabel: streamLabel)
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

    private func attemptRestartAfterGPUDisconnect(isDual: Bool, streamLabel: String = "") async {
        let now = Date()
        restartAttempts = restartAttempts.filter { now.timeIntervalSince($0) <= restartWindowSeconds }

        guard restartAttempts.count < maxRestartAttempts else {
            logger.error("Capture restart halted after repeated -3821 failures")
            interruptionHandler?(.gpuPressurePaused)
            await performStop()
            return
        }

        restartAttempts.append(now)
        logger.error("Received SCK -3821 on stream\(streamLabel). Restart attempt \(self.restartAttempts.count)")

        do {
            try await Task.sleep(for: .milliseconds(500))
        } catch {
            return
        }

        do {
            try await recreateStreamFromCurrentConfiguration(isDual: isDual)
            logger.info("Capture stream\(streamLabel) restarted after SCK -3821")
            interruptionHandler?(.restartedAfterGPUPressure)
        } catch {
            logger.error("Capture restart failed: \(error.localizedDescription, privacy: .public)")
            interruptionHandler?(.stopped("Restart failed: \(error.localizedDescription)"))
        }
    }

    private func recreateStreamFromCurrentConfiguration(isDual: Bool) async throws {
        if isDual {
            guard let filter1 = dualFilter1,
                  let filter2 = dualFilter2,
                  let config1 = dualConfiguration1,
                  let config2 = dualConfiguration2 else {
                throw CaptureRestartError.missingConfiguration
            }

            try? await stream1?.stopCapture()
            try? await stream2?.stopCapture()
            stream1 = nil
            stream2 = nil

            let replacement1 = SCStream(filter: filter1, configuration: config1, delegate: delegate1)
            try replacement1.addStreamOutput(delegate1, type: .screen, sampleHandlerQueue: videoQueue)
            try replacement1.addStreamOutput(delegate1, type: .audio, sampleHandlerQueue: audioQueue)

            let replacement2 = SCStream(filter: filter2, configuration: config2, delegate: delegate2)
            try replacement2.addStreamOutput(delegate2, type: .screen, sampleHandlerQueue: videoQueue)

            try await replacement1.startCapture()
            try await replacement2.startCapture()
            stream1 = replacement1
            stream2 = replacement2
        } else {
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
    case notEnoughDisplays
    case sameDisplay
}
