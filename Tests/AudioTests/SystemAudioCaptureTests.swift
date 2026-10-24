import XCTest
@preconcurrency import CoreMedia
@testable import Audio

final class SystemAudioCaptureTests: XCTestCase {
    private static let sampleRate: Double = 48_000
    private static let framesPerBuffer = 1024

    private func makeBuffer(pts: CMTime, value: Float = 0.5) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )

        let samples = [Float](repeating: value, count: Self.framesPerBuffer * 2)
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount
            )
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: Self.framesPerBuffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer
        )
        return buffer!
    }

    /// ScreenCaptureKit stamps audio with host time, so consecutive buffers can
    /// land a few microseconds earlier than the previous one's end. That jitter
    /// must not cost a whole buffer of audio.
    func testSlightlyEarlyTimestampKeepsTheBuffer() {
        let capture = SystemAudioCapture()
        var received: [CMSampleBuffer] = []
        capture.setHandler { received.append($0) }

        let bufferNanos = Int64(Double(Self.framesPerBuffer) / Self.sampleRate * 1_000_000_000)
        let jitterNanos: [Int64] = [0, 0, -2_000, 0, 0, 0]
        for (index, jitter) in jitterNanos.enumerated() {
            let pts = CMTime(value: 1_000_000_000 + Int64(index) * bufferNanos + jitter, timescale: 1_000_000_000)
            capture.process(sampleBuffer: makeBuffer(pts: pts))
        }

        let realBuffers = received.filter { CMSampleBufferGetNumSamples($0) == Self.framesPerBuffer && !isSilent($0) }
        let silentBuffers = received.filter(isSilent)
        XCTAssertEqual(realBuffers.count, jitterNanos.count, "a jittered buffer was dropped")
        XCTAssertTrue(silentBuffers.isEmpty, "silence was inserted where audio was dropped")
    }

    /// When capture hands off between the main and per-app streams, the new
    /// stream can redeliver audio that was already written. That buffer is dropped.
    func testRepeatedBufferFromStreamHandoffIsDropped() {
        let capture = SystemAudioCapture()
        var received: [CMSampleBuffer] = []
        capture.setHandler { received.append($0) }

        let bufferNanos = Int64(Double(Self.framesPerBuffer) / Self.sampleRate * 1_000_000_000)
        let starts: [Int64] = [0, bufferNanos, bufferNanos + 1_000, 2 * bufferNanos]
        for start in starts {
            capture.process(sampleBuffer: makeBuffer(pts: CMTime(value: 1_000_000_000 + start, timescale: 1_000_000_000)))
        }

        XCTAssertEqual(received.count, 3)
        XCTAssertTrue(received.allSatisfy { !isSilent($0) })
    }

    private func isSilent(_ buffer: CMSampleBuffer) -> Bool {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return true }
        let length = CMBlockBufferGetDataLength(block)
        var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        return data.allSatisfy { $0 == 0 }
    }
}
