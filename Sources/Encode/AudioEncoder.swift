import Foundation
@preconcurrency import CoreMedia

/// Passthrough audio handler.
/// SCK outputs raw PCM float32. We store it directly in the ring buffer
/// and let AVAssetWriterInput handle AAC encoding during save.
public final class AudioEncoder: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (CMSampleBuffer) -> Void

    private let lock = NSLock()
    private var _outputHandler: OutputHandler?

    public var outputHandler: OutputHandler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _outputHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _outputHandler = newValue
        }
    }

    public init() {}

    public func stop() {}

    public func encode(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let handler = _outputHandler
        lock.unlock()
        handler?(sampleBuffer)
    }
}
