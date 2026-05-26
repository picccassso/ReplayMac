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

public final class PerAppAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.replaymac.per-app-audio", qos: .userInitiated)
    private let delegate = PerAppAudioCaptureDelegate()
    private var stream: SCStream?

    public init() {}

    public func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        delegate.setHandler(handler)
    }

    public func start(bundleID: String, excludeOwnAppAudio: Bool) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw PerAppAudioCaptureError.noDisplay
        }

        let matches = content.applications.filter { app in
            app.bundleIdentifier == bundleID
        }
        guard !matches.isEmpty else {
            throw PerAppAudioCaptureError.appNotFound(bundleID)
        }

        let filter = SCContentFilter(display: display, including: matches, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = excludeOwnAppAudio

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: queue)
        try await newStream.startCapture()
        stream = newStream
    }

    public func stop() async {
        guard let activeStream = stream else {
            return
        }
        stream = nil
        try? await activeStream.stopCapture()
    }
}

private final class PerAppAudioCaptureDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?

    func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        lock.lock()
        self.handler = handler
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
}
