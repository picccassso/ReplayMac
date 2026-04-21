import XCTest
import ScreenCaptureKit
import CoreMedia
@testable import Capture

final class CaptureDelegateTests: XCTestCase {

    private func makeSampleBuffer(status: SCFrameStatus) -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: 0, preferredTimescale: 60000),
            decodeTimeStamp: .invalid
        )

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: 0,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: 0,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard let buffer = sampleBuffer else {
            XCTFail("Failed to create sample buffer")
            return sampleBuffer!
        }

        // Attach SCFrameStatus metadata
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) {
            let dict = Unmanaged<CFMutableDictionary>
                .fromOpaque(CFArrayGetValueAtIndex(attachments, 0))
                .takeUnretainedValue()
            let key = SCStreamFrameInfo.status.rawValue as NSString
            let value = NSNumber(value: status.rawValue)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(key).toOpaque(),
                Unmanaged.passUnretained(value).toOpaque()
            )
        }

        return buffer
    }

    func testCompleteFrameStatusIsExtracted() {
        let delegate = CaptureDelegate()
        let buffer = makeSampleBuffer(status: .complete)
        XCTAssertEqual(delegate.frameStatus(of: buffer), .complete)
    }

    func testStartedFrameStatusIsExtracted() {
        let delegate = CaptureDelegate()
        let buffer = makeSampleBuffer(status: .started)
        XCTAssertEqual(delegate.frameStatus(of: buffer), .started)
    }

    func testBlankFrameStatusIsExtracted() {
        let delegate = CaptureDelegate()
        let buffer = makeSampleBuffer(status: .blank)
        XCTAssertEqual(delegate.frameStatus(of: buffer), .blank)
    }

    func testIdleFrameStatusIsExtracted() {
        let delegate = CaptureDelegate()
        let buffer = makeSampleBuffer(status: .idle)
        XCTAssertEqual(delegate.frameStatus(of: buffer), .idle)
    }

    func testMissingAttachmentsReturnsNil() {
        let delegate = CaptureDelegate()

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: 0, preferredTimescale: 60000),
            decodeTimeStamp: .invalid
        )
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: 0,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0, dataLength: 0,
            flags: 0, blockBufferOut: &blockBuffer
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard let buffer = sampleBuffer else {
            XCTFail("Failed to create sample buffer")
            return
        }

        // Ensure no attachments are created
        XCTAssertNil(CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false))
        XCTAssertNil(delegate.frameStatus(of: buffer))
    }
}
