import Foundation
@preconcurrency import CoreMedia
import ScreenCaptureKit
import os.log

public enum PerAppAudioCaptureError: LocalizedError {
    case noDisplay
    case appNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display is available for per-app audio capture."
        case .appNotFound(let bundleID):
            return "The selected app is not available for capture: \(bundleID)"
        }
    }
}

public enum SystemAudioFilterMode: Equatable, Sendable {
    case includeOnly(bundleID: String)
    case exclude(bundleIDs: [String])

    /// True when app launches or terminations can change which processes match
    /// this audio filter. Unfiltered `.exclude(bundleIDs: [])` captures all
    /// system audio and does not need workspace refreshes.
    public var needsWorkspaceRefresh: Bool {
        switch self {
        case .includeOnly:
            return true
        case .exclude(let bundleIDs):
            return !bundleIDs.isEmpty
        }
    }
}

public final class PerAppAudioCapture: @unchecked Sendable {
    // @unchecked: stream state is only touched inside `stateLock`.
    private let queue = DispatchQueue(label: "com.replaycap.per-app-audio", qos: .userInitiated)
    private let delegate = PerAppAudioCaptureDelegate()
    private let logger = Logger(subsystem: "com.replaycap", category: "PerAppAudioCapture")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var currentMode: SystemAudioFilterMode?
    private var currentExcludeOwnAppAudio = false
    private var currentDisplayID: CGDirectDisplayID?
    private var preferredDisplayID: CGDirectDisplayID?
    private var streamStartedAt: Date?
    private var isStoppingIntentionally = false
    private var unexpectedStopHandler: (@Sendable (Error) -> Void)?

    public init() {
        delegate.setStreamStoppedHandler { [weak self] error in
            self?.handleDelegateStreamStopped(error: error)
        }
    }

    public var isRunning: Bool {
        stateLock.withLock { stream != nil }
    }

    public var lastAudioSampleDate: Date? {
        delegate.lastAudioSampleDateSnapshot()
    }

    public var lastStreamStartedAt: Date? {
        stateLock.withLock { streamStartedAt }
    }

    public var capturedDisplayID: CGDirectDisplayID? {
        stateLock.withLock { currentDisplayID }
    }

    public var needsWorkspaceRefresh: Bool {
        stateLock.withLock { currentMode?.needsWorkspaceRefresh ?? false }
    }

    public func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        delegate.setHandler(handler)
    }

    public func setUnexpectedStopHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        stateLock.withLock {
            unexpectedStopHandler = handler
        }
    }

    public static func matchesBundleID(_ candidate: String, target: String) -> Bool {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty, !trimmedTarget.isEmpty else { return false }
        if trimmedCandidate.caseInsensitiveCompare(trimmedTarget) == .orderedSame {
            return true
        }
        return trimmedCandidate.lowercased().hasPrefix(trimmedTarget.lowercased() + ".")
    }

    public static func matchesAnyBundleID(_ candidate: String, in targets: some Collection<String>) -> Bool {
        targets.contains { matchesBundleID(candidate, target: $0) }
    }

    public func start(bundleID: String, excludeOwnAppAudio: Bool, preferredDisplayID: CGDirectDisplayID? = nil) async throws {
        try await start(
            mode: .includeOnly(bundleID: bundleID),
            excludeOwnAppAudio: excludeOwnAppAudio,
            preferredDisplayID: preferredDisplayID
        )
    }

    public func start(
        mode: SystemAudioFilterMode,
        excludeOwnAppAudio: Bool,
        preferredDisplayID: CGDirectDisplayID? = nil
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let preferredDisplay = preferredDisplayID.flatMap { targetID in
            content.displays.first { CGDirectDisplayID($0.displayID) == targetID }
        }
        guard let display = preferredDisplay ?? content.displays.first else {
            throw PerAppAudioCaptureError.noDisplay
        }

        let filter = try Self.makeFilter(for: mode, display: display, applications: content.applications)

        let existing = stateLock.withLock {
            (stream: stream, displayID: currentDisplayID, excludeOwn: currentExcludeOwnAppAudio)
        }

        if let activeStream = existing.stream, existing.displayID == display.displayID {
            do {
                try await activeStream.updateContentFilter(filter)
                if existing.excludeOwn != excludeOwnAppAudio {
                    let config = Self.makeStreamConfiguration(excludeOwnAppAudio: excludeOwnAppAudio)
                    try await activeStream.updateConfiguration(config)
                }
                stateLock.withLock {
                    currentMode = mode
                    currentExcludeOwnAppAudio = excludeOwnAppAudio
                    self.preferredDisplayID = preferredDisplayID
                }
                return
            } catch {
                // Fall back to starting a fresh stream if the active stream could not be updated in place.
            }
        }

        await stop()
        delegate.resetStats()

        let config = Self.makeStreamConfiguration(excludeOwnAppAudio: excludeOwnAppAudio)
        let newStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try newStream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: queue)
        try await newStream.startCapture()

        stateLock.withLock {
            isStoppingIntentionally = false
            stream = newStream
            currentMode = mode
            currentExcludeOwnAppAudio = excludeOwnAppAudio
            currentDisplayID = display.displayID
            self.preferredDisplayID = preferredDisplayID
            streamStartedAt = Date()
        }
    }

    public func refreshFilterIfNeeded(force: Bool = false) async {
        let snapshot: (mode: SystemAudioFilterMode, excludeOwn: Bool, preferredDisplayID: CGDirectDisplayID?)? = stateLock.withLock {
            guard stream != nil, let currentMode else { return nil }
            guard force || currentMode.needsWorkspaceRefresh else { return nil }
            return (currentMode, currentExcludeOwnAppAudio, preferredDisplayID)
        }
        guard let snapshot else { return }
        do {
            try await start(
                mode: snapshot.mode,
                excludeOwnAppAudio: snapshot.excludeOwn,
                preferredDisplayID: snapshot.preferredDisplayID
            )
        } catch {
            logger.error("Failed to refresh per-app audio filter: \(String(describing: error), privacy: .public)")
        }
    }

    public func stop() async {
        let activeStream: SCStream? = stateLock.withLock {
            isStoppingIntentionally = true
            let current = stream
            stream = nil
            currentMode = nil
            currentDisplayID = nil
            preferredDisplayID = nil
            streamStartedAt = nil
            return current
        }
        delegate.resetStats()
        defer {
            stateLock.withLock {
                isStoppingIntentionally = false
            }
        }
        guard let activeStream else {
            return
        }
        try? await activeStream.stopCapture()
    }

    private func handleDelegateStreamStopped(error: Error) {
        let handlerToNotify: (@Sendable (Error) -> Void)? = stateLock.withLock {
            let wasIntentional = isStoppingIntentionally
            let hadActiveStream = stream != nil
            stream = nil
            currentDisplayID = nil
            streamStartedAt = nil
            return (!wasIntentional && hadActiveStream) ? unexpectedStopHandler : nil
        }
        delegate.resetStats()
        handlerToNotify?(error)
    }

    /// Exposed for tests to verify stop-notification semantics without a live SCStream.
    internal func simulateStreamStopped(error: Error, wasRunning: Bool = true) {
        let handlerToNotify: (@Sendable (Error) -> Void)? = stateLock.withLock {
            let wasIntentional = isStoppingIntentionally
            stream = nil
            currentDisplayID = nil
            return (!wasIntentional && wasRunning) ? unexpectedStopHandler : nil
        }
        delegate.resetStats()
        handlerToNotify?(error)
    }

    private static func makeFilter(
        for mode: SystemAudioFilterMode,
        display: SCDisplay,
        applications: [SCRunningApplication]
    ) throws -> SCContentFilter {
        switch mode {
        case .includeOnly(let bundleID):
            let matches = applications.filter { app in
                matchesBundleID(app.bundleIdentifier, target: bundleID)
            }
            guard !matches.isEmpty else {
                throw PerAppAudioCaptureError.appNotFound(bundleID)
            }
            return SCContentFilter(display: display, including: matches, exceptingWindows: [])
        case .exclude(let bundleIDs):
            let excludedMatches = applications.filter { app in
                matchesAnyBundleID(app.bundleIdentifier, in: bundleIDs)
            }
            return SCContentFilter(display: display, excludingApplications: excludedMatches, exceptingWindows: [])
        }
    }

    private static func makeStreamConfiguration(excludeOwnAppAudio: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = excludeOwnAppAudio
        return config
    }
}

private final class PerAppAudioCaptureDelegate: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // @unchecked: all mutable state is only touched inside `lock`.
    private let lock = NSLock()
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?
    private var streamStoppedHandler: (@Sendable (Error) -> Void)?
    private var lastAudioSampleDate: Date?

    func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setStreamStoppedHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.lock()
        self.streamStoppedHandler = handler
        lock.unlock()
    }

    func resetStats() {
        lock.lock()
        lastAudioSampleDate = nil
        lock.unlock()
    }

    func lastAudioSampleDateSnapshot() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastAudioSampleDate
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid else {
            return
        }

        let now = Date()
        lock.lock()
        lastAudioSampleDate = now
        let handler = handler
        lock.unlock()
        handler?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let stoppedHandler = streamStoppedHandler
        lock.unlock()
        stoppedHandler?(error)
    }
}
