import Foundation
@preconcurrency import CoreMedia
import Synchronization

/// Passthrough audio handler.
/// SCK outputs raw PCM float32. We store it directly in the ring buffer
/// and let AVAssetWriterInput handle AAC encoding during save.
public final class AudioEncoder: Sendable {
    public typealias OutputHandler = @Sendable (CMSampleBuffer) -> Void

    private let _outputHandler = Mutex<OutputHandler?>(nil)

    public var outputHandler: OutputHandler? {
        get { _outputHandler.withLock { $0 } }
        set { _outputHandler.withLock { $0 = newValue } }
    }

    public init() {}

    public func stop() {}

    public func encode(sampleBuffer: CMSampleBuffer) {
        let handler = _outputHandler.withLock { $0 }
        handler?(sampleBuffer)
    }
}
