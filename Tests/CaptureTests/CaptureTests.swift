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

final class CaptureHealthTests: XCTestCase {
    func testDetectsMissingVideoAfterStartupGracePeriod() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(CaptureHealth.isVideoStalled(
            isCaptureRunning: true,
            isSessionActive: true,
            monitoringStartedAt: start,
            lastVideoSampleDate: nil,
            now: start.addingTimeInterval(15),
            timeout: 15
        ))
    }

    func testRecentVideoSampleKeepsCaptureHealthy() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertFalse(CaptureHealth.isVideoStalled(
            isCaptureRunning: true,
            isSessionActive: true,
            monitoringStartedAt: start,
            lastVideoSampleDate: start.addingTimeInterval(20),
            now: start.addingTimeInterval(30),
            timeout: 15
        ))
    }

    func testInactiveSessionDoesNotTriggerWatchdog() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertFalse(CaptureHealth.isVideoStalled(
            isCaptureRunning: true,
            isSessionActive: false,
            monitoringStartedAt: start,
            lastVideoSampleDate: nil,
            now: start.addingTimeInterval(60),
            timeout: 15
        ))
    }

    func testRecoveryWaitsUntilSessionAndScreensAreActive() {
        XCTAssertFalse(CaptureRecoveryPolicy.shouldScheduleRecovery(
            automaticResumeEnabled: true,
            shouldResume: true,
            isSessionActive: false,
            areScreensAwake: true,
            isPreparingRecovery: false,
            hasScheduledRecovery: false
        ))
        XCTAssertFalse(CaptureRecoveryPolicy.shouldScheduleRecovery(
            automaticResumeEnabled: true,
            shouldResume: true,
            isSessionActive: true,
            areScreensAwake: false,
            isPreparingRecovery: false,
            hasScheduledRecovery: false
        ))
    }

    func testRecoverySchedulesAfterSessionReactivation() {
        XCTAssertTrue(CaptureRecoveryPolicy.shouldScheduleRecovery(
            automaticResumeEnabled: true,
            shouldResume: true,
            isSessionActive: true,
            areScreensAwake: true,
            isPreparingRecovery: false,
            hasScheduledRecovery: false
        ))
    }

    func testUnexpectedStopDuringSleepPreservesRecoveryIntent() {
        XCTAssertTrue(CaptureRecoveryPolicy.shouldPreserveTransitionStop(
            automaticResumeEnabled: true,
            shouldResume: true,
            isSessionActive: true,
            areScreensAwake: false,
            isPreparingRecovery: false
        ))
        XCTAssertTrue(CaptureRecoveryPolicy.shouldPreserveTransitionStop(
            automaticResumeEnabled: true,
            shouldResume: true,
            isSessionActive: true,
            areScreensAwake: true,
            isPreparingRecovery: true
        ))
    }

    func testActiveSessionDoesNotLookLikeTransitionStop() {
        XCTAssertFalse(CaptureRecoveryPolicy.shouldPreserveTransitionStop(
            automaticResumeEnabled: true,
            shouldResume: true,
            isSessionActive: true,
            areScreensAwake: true,
            isPreparingRecovery: false
        ))
        XCTAssertFalse(CaptureRecoveryPolicy.shouldPreserveTransitionStop(
            automaticResumeEnabled: false,
            shouldResume: true,
            isSessionActive: false,
            areScreensAwake: false,
            isPreparingRecovery: true
        ))
    }

    func testUnexpectedGenericStopRecoversEvenBeforeSleepNotification() {
        XCTAssertTrue(CaptureRecoveryPolicy.shouldRecoverUnexpectedStreamStop(
            automaticResumeEnabled: true,
            captureWasRunning: true
        ))
        XCTAssertFalse(CaptureRecoveryPolicy.shouldRecoverUnexpectedStreamStop(
            automaticResumeEnabled: false,
            captureWasRunning: true
        ))
        XCTAssertFalse(CaptureRecoveryPolicy.shouldRecoverUnexpectedStreamStop(
            automaticResumeEnabled: true,
            captureWasRunning: false
        ))
    }

    func testRecoveryRetryBackoffAllowsDisplaysTimeToReturn() {
        XCTAssertEqual(CaptureRecoveryPolicy.maximumAttempts, 5)
        XCTAssertEqual(CaptureRecoveryPolicy.retryDelay(completedAttempts: 0), 2)
        XCTAssertEqual(CaptureRecoveryPolicy.retryDelay(completedAttempts: 1), 4)
        XCTAssertEqual(CaptureRecoveryPolicy.retryDelay(completedAttempts: 2), 8)
        XCTAssertEqual(CaptureRecoveryPolicy.retryDelay(completedAttempts: 3), 10)
        XCTAssertEqual(CaptureRecoveryPolicy.retryDelay(completedAttempts: 4), 10)
    }

    func testRecoveryRequiresRecentVideoBeforeReportingSuccess() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000)

        XCTAssertTrue(CaptureRecoveryPolicy.isStableRestart(
            isCaptureRunning: true,
            lastVideoSampleDate: now.addingTimeInterval(-1),
            now: now
        ))
        XCTAssertFalse(CaptureRecoveryPolicy.isStableRestart(
            isCaptureRunning: true,
            lastVideoSampleDate: nil,
            now: now
        ))
        XCTAssertFalse(CaptureRecoveryPolicy.isStableRestart(
            isCaptureRunning: false,
            lastVideoSampleDate: now,
            now: now
        ))
        XCTAssertFalse(CaptureRecoveryPolicy.isStableRestart(
            isCaptureRunning: true,
            lastVideoSampleDate: now.addingTimeInterval(-6),
            now: now
        ))
    }

    func testRecognizesSystemStoppedStreamError() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.systemStoppedStream.rawValue
        )

        XCTAssertTrue(CaptureInterruptionClassifier.isSystemStoppedStream(error))
    }

    func testRecognizesWrappedSystemStoppedStreamError() {
        let underlying = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.systemStoppedStream.rawValue
        )
        let wrapper = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        XCTAssertTrue(CaptureInterruptionClassifier.isSystemStoppedStream(wrapper))
    }

    func testAttemptToStopAlreadyStoppedStreamIsNotSystemStopCause() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.attemptToStopStreamState.rawValue
        )

        XCTAssertFalse(CaptureInterruptionClassifier.isSystemStoppedStream(error))
    }
}
