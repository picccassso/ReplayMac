import Foundation
@preconcurrency import CoreMedia

/// Receives raw system audio CMSampleBuffers from the capture delegate
/// and forwards them to a handler. Detects gaps in the audio stream
/// and emits silence buffers to maintain sync when the output device changes.
public final class SystemAudioCapture: @unchecked Sendable {
    /// Longest delivery gap that is worth papering over with silence.
    static let maximumGapFillSeconds: TimeInterval = 5

    /// Keeps any one synthesized buffer small enough that ring-buffer eviction
    /// stays granular.
    static let gapFillChunkSeconds: TimeInterval = 0.5

    private let lock = NSLock()
    private var handler: ((CMSampleBuffer) -> Void)?
    private var nextExpectedPTS: CMTime?
    private var volume: Double = 1.0

    public init() {}

    public func setHandler(_ handler: @escaping (CMSampleBuffer) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    public func setVolume(_ volume: Double) {
        lock.lock()
        self.volume = volume
        lock.unlock()
    }

    public func process(sampleBuffer: CMSampleBuffer) {
        // Deep-copy the buffer so SCK can recycle its original. SCK audio uses
        // a small internal pool (~1.3s) and stops delivering once we exhaust it
        // by retaining buffers in downstream ring buffers.
        guard let copied = Self.deepCopy(sampleBuffer) else { return }

        lock.lock()
        let currentVolume = volume
        lock.unlock()

        Self.scaleVolume(of: copied, volume: currentVolume)
        AudioLevelMonitor.shared.recordSystemAudio(copied)

        let pts = CMSampleBufferGetPresentationTimeStamp(copied)
        let duration = CMSampleBufferGetDuration(copied)

        lock.lock()
        defer { lock.unlock() }

        if let nextExpected = nextExpectedPTS, pts > nextExpected {
            let gapSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, nextExpected))
            if gapSeconds > 0.005, let format = copied.formatDescription {
                fillGap(
                    seconds: gapSeconds,
                    startingAt: nextExpected,
                    formatDescription: format,
                    handler: handler
                )
            }
        }

        handler?(copied)
        nextExpectedPTS = CMTimeAdd(pts, duration)
    }

    private static func deepCopy(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let originalBlock = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let totalBytes = CMBlockBufferGetDataLength(originalBlock)
        guard totalBytes > 0 else { return nil }

        var newBlock: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &newBlock
        )
        guard blockStatus == noErr, let newBlock else { return nil }

        var destPtr: UnsafeMutablePointer<Int8>?
        let accessStatus = CMBlockBufferGetDataPointer(
            newBlock, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &destPtr
        )
        guard accessStatus == noErr, let destPtr else { return nil }

        if CMBlockBufferCopyDataBytes(originalBlock, atOffset: 0, dataLength: totalBytes, destination: destPtr) != noErr {
            return nil
        }

        var timingCount: CMItemCount = 0
        _ = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
        var timings: [CMSampleTimingInfo]
        if timingCount > 0 {
            timings = Array(repeating: CMSampleTimingInfo(), count: Int(timingCount))
            let status = CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer, entryCount: timingCount, arrayToFill: &timings, entriesNeededOut: nil
            )
            guard status == noErr else { return nil }
        } else {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            timings = [CMSampleTimingInfo(
                duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid
            )]
        }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        var newSample: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: newBlock,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: sampleCount,
            sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &newSample
        )
        guard createStatus == noErr else { return nil }
        return newSample
    }

    private static func scaleVolume(of sampleBuffer: CMSampleBuffer, volume: Double) {
        guard volume != 1.0 else { return }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalBytes = CMBlockBufferGetDataLength(dataBuffer)
        guard totalBytes > 0 else { return }

        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPtr
        ) == noErr, let dataPtr else { return }

        let floatCount = totalBytes / MemoryLayout<Float>.size
        let volumeFloat = Float(volume)
        dataPtr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
            for i in 0..<floatCount {
                floatPtr[i] *= volumeFloat
            }
        }
    }

    /// Emits silence across a delivery gap, in bounded chunks.
    ///
    /// A single buffer spanning the whole gap is a trap: an output-device change
    /// mid-call can stall the tap for tens of seconds, and 20s of 48kHz stereo
    /// float is one ~7.7MB allocation. Pushed into the ring buffer it exceeds
    /// the audio memory cap by itself, so eviction drops every real sample
    /// ahead of it and the recovered stream is all that survives — the outage
    /// erases the audio that preceded it. Chunking keeps eviction granular, and
    /// past `maximumGapFillSeconds` the gap is left as a genuine hole: the
    /// save-time mixer already renders unwritten regions as silence.
    private func fillGap(
        seconds: TimeInterval,
        startingAt startPTS: CMTime,
        formatDescription: CMFormatDescription,
        handler: ((CMSampleBuffer) -> Void)?
    ) {
        guard let handler else { return }

        let fillSeconds = min(seconds, Self.maximumGapFillSeconds)
        var emitted: TimeInterval = 0
        while emitted < fillSeconds {
            let chunkSeconds = min(Self.gapFillChunkSeconds, fillSeconds - emitted)
            let chunkStart = CMTimeAdd(startPTS, CMTime(seconds: emitted, preferredTimescale: 48_000))
            guard let silenceBuffer = makeSilenceBuffer(
                duration: chunkSeconds,
                startingAt: chunkStart,
                formatDescription: formatDescription
            ) else {
                break
            }
            handler(silenceBuffer)
            emitted += chunkSeconds
        }
    }

    private func makeSilenceBuffer(
        duration: TimeInterval,
        startingAt pts: CMTime,
        formatDescription: CMFormatDescription
    ) -> CMSampleBuffer? {
        guard let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let asbd = asbdPointer.pointee
        let sampleRate = asbd.mSampleRate
        let bytesPerFrame = asbd.mBytesPerFrame
        let totalFrames = Int64(duration * Double(sampleRate))
        let totalBytes = Int(totalFrames) * Int(bytesPerFrame)
        guard totalBytes > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }

        let zeroStatus = CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: totalBytes)
        guard zeroStatus == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        _ = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(totalFrames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}
