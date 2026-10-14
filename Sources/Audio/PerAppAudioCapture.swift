import Foundation
@preconcurrency import CoreMedia
import ScreenCaptureKit

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
}

public final class PerAppAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.replaycap.per-app-audio", qos: .userInitiated)
    private let delegate = PerAppAudioCaptureDelegate()
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var currentMode: SystemAudioFilterMode?
    private var currentExcludeOwnAppAudio = false
    private var currentDisplayID: CGDirectDisplayID?

    public init() {
        delegate.setStreamStoppedHandler { [weak self] in
            self?.clearStreamState()
        }
    }

    public var isRunning: Bool {
        stateLock.withLock { stream != nil }
    }

    public func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        delegate.setHandler(handler)
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

    public func start(bundleID: String, excludeOwnAppAudio: Bool) async throws {
        try await start(mode: .includeOnly(bundleID: bundleID), excludeOwnAppAudio: excludeOwnAppAudio)
    }

    public func start(mode: SystemAudioFilterMode, excludeOwnAppAudio: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
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
                }
                return
            } catch {
                // Fall back to starting a fresh stream if the active stream could not be updated in place.
            }
        }

        await stop()

        let config = Self.makeStreamConfiguration(excludeOwnAppAudio: excludeOwnAppAudio)
        let newStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try newStream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: queue)
        try await newStream.startCapture()

        stateLock.withLock {
            stream = newStream
            currentMode = mode
            currentExcludeOwnAppAudio = excludeOwnAppAudio
            currentDisplayID = display.displayID
        }
    }

    public func refreshFilterIfNeeded() async {
        let snapshot: (mode: SystemAudioFilterMode, excludeOwn: Bool)? = stateLock.withLock {
            guard stream != nil, let currentMode else { return nil }
            return (currentMode, currentExcludeOwnAppAudio)
        }
        guard let snapshot else { return }
        try? await start(mode: snapshot.mode, excludeOwnAppAudio: snapshot.excludeOwn)
    }

    public func stop() async {
        let activeStream: SCStream? = stateLock.withLock {
            let current = stream
            stream = nil
            currentMode = nil
            currentDisplayID = nil
            return current
        }
        guard let activeStream else {
            return
        }
        try? await activeStream.stopCapture()
    }

    private func clearStreamState() {
        stateLock.withLock {
            stream = nil
            currentDisplayID = nil
        }
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
    private let lock = NSLock()
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?
    private var streamStoppedHandler: (@Sendable () -> Void)?

    func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setStreamStoppedHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.streamStoppedHandler = handler
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid else {
            return
        }

        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let stoppedHandler = streamStoppedHandler
        lock.unlock()
        stoppedHandler?()
    }
}
