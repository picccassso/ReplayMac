import Foundation
@preconcurrency import CoreMedia

/// Receives raw system audio CMSampleBuffers from the capture delegate
/// and forwards them to a handler. Detects gaps in the audio stream
/// and emits silence buffers to maintain sync when the output device changes.
public final class SystemAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((CMSampleBuffer) -> Void)?
    private var nextExpectedPTS: CMTime?

    public init() {}

    public func setHandler(_ handler: @escaping (CMSampleBuffer) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    public func process(sampleBuffer: CMSampleBuffer) {
        // Deep-copy the buffer so SCK can recycle its original. SCK audio uses
        // a small internal pool (~1.3s) and stops delivering once we exhaust it
        // by retaining buffers in downstream ring buffers.
        guard let copied = Self.deepCopy(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(copied)
        let duration = CMSampleBufferGetDuration(copied)

        lock.lock()
        defer { lock.unlock() }

        if let nextExpected = nextExpectedPTS, pts > nextExpected {
            let gapSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, nextExpected))
            if gapSeconds > 0.005, let format = copied.formatDescription {
                if let silenceBuffer = makeSilenceBuffer(
                    duration: gapSeconds,
                    startingAt: nextExpected,
                    formatDescription: format
                ) {
                    handler?(silenceBuffer)
                }
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
