@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import CoreVideo
import os.log

public struct CaptureConfig: Sendable {
    public let width: Int
    public let height: Int
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let sourcePointPixelScale: Double
    public let sourcePixelWidth: Int
    public let sourcePixelHeight: Int
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
    private static let screenPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    // Single-display state
    private var stream: SCStream?
    private nonisolated let delegate = CaptureDelegate()

    // Dual-display state
    private var stream1: SCStream?
    private var stream2: SCStream?
    private nonisolated let delegate1 = CaptureDelegate()
    private nonisolated let delegate2 = CaptureDelegate()

    private let videoQueue = DispatchQueue(label: "com.replaymac.video", qos: .userInteractive)
    private let secondaryVideoQueue = DispatchQueue(label: "com.replaymac.video.secondary", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.replaymac.audio", qos: .userInitiated)

    // Single-display config for restart
    private var currentFilter: SCContentFilter?
    private var currentConfiguration: SCStreamConfiguration?

    // Dual-display config for restart
    private var dualFilter1: SCContentFilter?
    private var dualFilter2: SCContentFilter?
    private var dualConfiguration1: SCStreamConfiguration?
    private var dualConfiguration2: SCStreamConfiguration?

    private var isDualMode = false
    private var userInitiatedStop = false

    private var interruptionHandler: (@Sendable (CaptureInterruption) -> Void)?
    private let logger = Logger(subsystem: "com.replaymac", category: "CaptureRecovery")

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
                await self.handleStreamStopped(error: error)
            }
        }
        delegate1.setStreamStoppedHandler { [weak self] error in
            guard let self else { return }
            Task {
                await self.handleStreamStopped(error: error)
            }
        }
        delegate2.setStreamStoppedHandler { [weak self] error in
            guard let self else { return }
            Task {
                await self.handleStreamStopped(error: error)
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
        excludeOwnAppAudio: Bool = false,
        captureAudio: Bool = true
    ) async throws -> CaptureConfig {
        delegate.resetStats()
        let permissions = CapturePermissions()
        let content = try await permissions.requestAccess(interactive: interactivePermissionPrompt)

        let selectedDisplay = content.displays.first { display in
            String(display.displayID) == captureDisplayID
        }

        guard let display = selectedDisplay ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let pointPixelScale = max(Double(filter.pointPixelScale), 1.0)
        let displayID = CGDirectDisplayID(display.displayID)
        let displayMode = CGDisplayCopyDisplayMode(displayID)
        let pixelWidth = max(CGDisplayPixelsWide(displayID), displayMode?.pixelWidth ?? 0)
        let pixelHeight = max(CGDisplayPixelsHigh(displayID), displayMode?.pixelHeight ?? 0)

        let captureWidth = outputWidth ?? Int(display.width)
        let captureHeight = outputHeight ?? Int(display.height)

        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = queueDepth
        config.pixelFormat = Self.screenPixelFormat
        config.capturesAudio = captureAudio
        config.excludesCurrentProcessAudio = excludeOwnAppAudio

        let newStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try newStream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: videoQueue)
        if captureAudio {
            try newStream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await newStream.startCapture()

        userInitiatedStop = false
        isDualMode = false
        currentFilter = filter
        currentConfiguration = config
        self.stream = newStream

        return CaptureConfig(
            width: captureWidth,
            height: captureHeight,
            sourceWidth: Int(display.width),
            sourceHeight: Int(display.height),
            sourcePointPixelScale: pointPixelScale,
            sourcePixelWidth: pixelWidth,
            sourcePixelHeight: pixelHeight,
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
        excludeOwnAppAudio: Bool = false,
        captureAudio: Bool = true
    ) async throws -> (config1: CaptureConfig, config2: CaptureConfig) {
        delegate1.resetStats()
        delegate2.resetStats()
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
        let pointPixelScale1 = max(Double(filter1.pointPixelScale), 1.0)
        let pointPixelScale2 = max(Double(filter2.pointPixelScale), 1.0)
        let displayID1 = CGDirectDisplayID(display1.displayID)
        let displayID2 = CGDirectDisplayID(display2.displayID)
        let displayMode1 = CGDisplayCopyDisplayMode(displayID1)
        let displayMode2 = CGDisplayCopyDisplayMode(displayID2)
        let pixelWidth1 = max(CGDisplayPixelsWide(displayID1), displayMode1?.pixelWidth ?? 0)
        let pixelHeight1 = max(CGDisplayPixelsHigh(displayID1), displayMode1?.pixelHeight ?? 0)
        let pixelWidth2 = max(CGDisplayPixelsWide(displayID2), displayMode2?.pixelWidth ?? 0)
        let pixelHeight2 = max(CGDisplayPixelsHigh(displayID2), displayMode2?.pixelHeight ?? 0)

        let capWidth1 = outputWidth1 ?? Int(display1.width)
        let capHeight1 = outputHeight1 ?? Int(display1.height)
        let capWidth2 = outputWidth2 ?? Int(display2.width)
        let capHeight2 = outputHeight2 ?? Int(display2.height)

        let config1 = SCStreamConfiguration()
        config1.width = capWidth1
        config1.height = capHeight1
        config1.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config1.queueDepth = queueDepth
        config1.pixelFormat = Self.screenPixelFormat
        config1.capturesAudio = captureAudio
        config1.excludesCurrentProcessAudio = excludeOwnAppAudio

        let config2 = SCStreamConfiguration()
        config2.width = capWidth2
        config2.height = capHeight2
        config2.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config2.queueDepth = queueDepth
        config2.pixelFormat = Self.screenPixelFormat
        config2.capturesAudio = false

        let newStream1 = SCStream(filter: filter1, configuration: config1, delegate: delegate1)
        try newStream1.addStreamOutput(delegate1, type: .screen, sampleHandlerQueue: videoQueue)
        if captureAudio {
            try newStream1.addStreamOutput(delegate1, type: .audio, sampleHandlerQueue: audioQueue)
        }

        let newStream2 = SCStream(filter: filter2, configuration: config2, delegate: delegate2)
        try newStream2.addStreamOutput(delegate2, type: .screen, sampleHandlerQueue: secondaryVideoQueue)

        try await startDualStreams(newStream1, newStream2)

        userInitiatedStop = false
        isDualMode = true
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
                sourcePointPixelScale: pointPixelScale1,
                sourcePixelWidth: pixelWidth1,
                sourcePixelHeight: pixelHeight1,
                fps: fps
            ),
            config2: CaptureConfig(
                width: capWidth2,
                height: capHeight2,
                sourceWidth: Int(display2.width),
                sourceHeight: Int(display2.height),
                sourcePointPixelScale: pointPixelScale2,
                sourcePixelWidth: pixelWidth2,
                sourcePixelHeight: pixelHeight2,
                fps: fps
            )
        )
    }

    // MARK: - Stop

    public func stop() async {
        await performStop()
    }

    private func performStop(requestStreamStop: Bool = true) async {
        userInitiatedStop = true

        if isDualMode {
            if requestStreamStop {
                try? await stream1?.stopCapture()
                try? await stream2?.stopCapture()
            }
            stream1 = nil
            stream2 = nil
            dualFilter1 = nil
            dualFilter2 = nil
            dualConfiguration1 = nil
            dualConfiguration2 = nil
        } else {
            if requestStreamStop {
                try? await stream?.stopCapture()
            }
            stream = nil
            currentFilter = nil
            currentConfiguration = nil
        }

        isDualMode = false
        userInitiatedStop = false
    }

    // MARK: - Stream stopped handler

    private func handleStreamStopped(error: Error) async {
        guard !userInitiatedStop else {
            return
        }

        let nsError = error as NSError
        let isSystemStopped = CaptureInterruptionClassifier.isSystemStoppedStream(error)
        logger.error(
            "ScreenCaptureKit stream stopped domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) systemStopped=\(isSystemStopped, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
        )
        if isSystemStopped {
            interruptionHandler?(.systemStopped)
            await performStop(requestStreamStop: false)
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

        // The delegate callback means the single stream is already stopped;
        // asking ScreenCaptureKit to stop it again produces
        // attemptToStopStreamState (-3808). Dual mode still needs to stop the
        // other stream if only one display stream failed.
        await performStop(requestStreamStop: isDualMode)
    }

    private func startDualStreams(_ firstStream: SCStream, _ secondStream: SCStream) async throws {
        do {
            try await firstStream.startCapture()
            try await secondStream.startCapture()
        } catch {
            try? await secondStream.stopCapture()
            try? await firstStream.stopCapture()
            throw error
        }
    }

}

public enum CaptureInterruption: Sendable {
    case systemStopped
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
