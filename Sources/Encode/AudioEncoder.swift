import Foundation
@preconcurrency import CoreMedia
import Synchronization

/// Passthrough audio handler.
/// SCK outputs raw PCM float32. It goes to the ring buffer as PCM (held
/// there as 16-bit) and AVAssetWriterInput handles AAC encoding during save.
public final class AudioEncoder: Sendable {
    public typealias OutputHandler = @Sendable (CMSampleBuffer) -> Void

    /// The handler must sit inside a struct: a bare function type in
    /// `Mutex` is reabstracted on every `withLock` inout writeback, so each
    /// call stacks another thunk layer until the audio thread overflows.
    private struct State {
        var outputHandler: OutputHandler?
    }

    private let state = Mutex(State())

    public var outputHandler: OutputHandler? {
        get { state.withLock { $0.outputHandler } }
        set { state.withLock { $0.outputHandler = newValue } }
    }

    public init() {}

    public func stop() {}

    public func encode(sampleBuffer: CMSampleBuffer) {
        let handler = state.withLock { $0.outputHandler }
        handler?(sampleBuffer)
    }
}
