import Foundation
@preconcurrency import CoreMedia

/// Zero-filled linear PCM sample buffers in a given format.
enum PCMSilence {
    /// One buffer of silence starting at `start` and lasting `seconds`, in
    /// `formatDescription`'s PCM format, or nil if the format is not PCM.
    static func buffer(formatDescription: CMFormatDescription, start: CMTime, seconds: Double) -> CMSampleBuffer? {
        guard let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0, seconds > 0 else { return nil }

        let frameCount = Int((seconds * asbd.mSampleRate).rounded())
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerFrame = isNonInterleaved
            ? Int(asbd.mBytesPerFrame) * max(1, Int(asbd.mChannelsPerFrame))
            : Int(asbd.mBytesPerFrame)
        let byteCount = frameCount * bytesPerFrame
        guard frameCount > 0, byteCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount) == noErr else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: start,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    /// When a PCM buffer stops playing: its start plus frames over sample rate.
    static func endTime(of sample: CMSampleBuffer) -> Double? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric,
              let format = sample.formatDescription,
              let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate,
              rate > 0 else {
            return nil
        }
        return pts.seconds + Double(CMSampleBufferGetNumSamples(sample)) / rate
    }
}
