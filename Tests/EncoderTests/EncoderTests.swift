import XCTest
import CoreMedia
import CoreVideo
import Synchronization
@testable import Encode

final class EncoderTests: XCTestCase {
    func testHDRRejectsH264() {
        let encoder = VideoEncoder()
        defer { encoder.stop() }
        XCTAssertThrowsError(try encoder.start(width: 128, height: 64, fps: 30, codec: .h264, captureHDR: true)) { error in
            guard case VideoEncoderError.hdrRequiresHEVC = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHEVCInitialization() throws {
        let encoder = VideoEncoder()
        try encoder.start(width: 1920, height: 1080, fps: 60, codec: .hevc, bitrate: 20_000_000)
        XCTAssertEqual(
            encoder.currentConfiguration,
            VideoEncoderConfiguration(width: 1920, height: 1080, fps: 60, codec: .hevc, bitrate: 20_000_000)
        )
        encoder.stop()
    }

    func testH264Initialization() throws {
        let encoder = VideoEncoder()
        try encoder.start(width: 1920, height: 1080, fps: 60, codec: .h264, bitrate: 20_000_000)
        XCTAssertEqual(
            encoder.currentConfiguration,
            VideoEncoderConfiguration(width: 1920, height: 1080, fps: 60, codec: .h264, bitrate: 20_000_000)
        )
        encoder.stop()
    }

    func testBitrateIsReflectedInCurrentConfiguration() throws {
        let encoder = VideoEncoder()
        try encoder.start(width: 1280, height: 720, fps: 30, codec: .hevc, bitrate: 35_000_000)

        XCTAssertEqual(encoder.currentConfiguration?.bitrate, 35_000_000)

        encoder.stop()
        XCTAssertNil(encoder.currentConfiguration)
    }

    /// The output callback runs on a VideoToolbox thread while `encode` keeps
    /// counting frames on the caller's. Zero timestamps take the callback's
    /// logging path, which reads the counter. Run under
    /// `swift test --sanitize=thread` to catch unguarded state.
    func testOutputCallbackDoesNotRaceWithEncode() throws {
        let encoder = VideoEncoder()
        let delivered = expectation(description: "encoded frame delivered")
        delivered.assertForOverFulfill = false
        encoder.outputHandler = { _ in delivered.fulfill() }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)
        defer { encoder.stop() }

        for _ in 0..<30 {
            encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: .zero))
        }
        wait(for: [delivered], timeout: 5)
    }

    /// Storing the handler closure directly in a `Mutex` made every
    /// `withLock { $0 }` write back a re-thunked closure, so each audio
    /// buffer added two stack frames to the next call until the audio
    /// thread overflowed after ~6,600 buffers.
    func testAudioEncodeDoesNotGrowHandlerCallDepth() throws {
        let encoder = AudioEncoder()
        let depths = Mutex<[Int]>([])
        encoder.outputHandler = { _ in
            let depth = Thread.callStackSymbols.count
            depths.withLock { $0.append(depth) }
        }
        let sample = try makeFrame(width: 16, height: 16, presentationTime: .zero)

        for _ in 0..<500 {
            encoder.encode(sampleBuffer: sample)
            _ = encoder.outputHandler
        }

        let recorded = depths.withLock { $0 }
        XCTAssertEqual(recorded.count, 500)
        XCTAssertEqual(recorded.first, recorded.last)
    }

    // MARK: - Idle refresh

    func testIdlePolicyWaitsForTheIdleInterval() {
        let last = CMTime(value: 1_000_000, timescale: 1_000)
        XCTAssertFalse(IdleFrameRefreshPolicy.shouldRefresh(lastSubmittedPTS: last, now: CMTime(value: 1_000_200, timescale: 1_000)))
        XCTAssertTrue(IdleFrameRefreshPolicy.shouldRefresh(lastSubmittedPTS: last, now: CMTime(value: 1_000_250, timescale: 1_000)))
        XCTAssertFalse(IdleFrameRefreshPolicy.shouldRefresh(lastSubmittedPTS: .invalid, now: last))
    }

    func testIdlePolicyKeepsPresentationTimesIncreasing() {
        let last = CMTime(value: 1_000_500, timescale: 1_000)
        let late = CMTime(value: 1_000_450, timescale: 1_000)
        XCTAssertGreaterThan(IdleFrameRefreshPolicy.monotonicPTS(late, after: last), last)
        XCTAssertGreaterThan(IdleFrameRefreshPolicy.monotonicPTS(last, after: last), last)
        let later = CMTime(value: 1_000_600, timescale: 1_000)
        XCTAssertEqual(IdleFrameRefreshPolicy.monotonicPTS(later, after: last), later)
    }

    func testIdlePolicyForcesKeyframeOnlyPastTheBackstop() {
        let keyframe = CMTime(value: 1_000_000, timescale: 1_000)
        XCTAssertFalse(IdleFrameRefreshPolicy.shouldForceKeyframe(pts: CMTime(value: 1_002_000, timescale: 1_000), lastKeyframePTS: keyframe))
        XCTAssertTrue(IdleFrameRefreshPolicy.shouldForceKeyframe(pts: CMTime(value: 1_002_500, timescale: 1_000), lastKeyframePTS: keyframe))
        XCTAssertFalse(IdleFrameRefreshPolicy.shouldForceKeyframe(pts: keyframe, lastKeyframePTS: .invalid))
    }

    /// One frame, then 20 s of still screen: the encoder must keep emitting the
    /// last frame on the clock, with keyframes no further apart than the ring
    /// buffers' headroom assumes.
    func testStillScreenKeepsStreamOnTheClockWithRegularKeyframes() throws {
        let encoder = VideoEncoder(idleRefreshEnabled: false)
        let outputs = Mutex<[(pts: Double, isKeyframe: Bool)]>([])
        encoder.outputHandler = { sample in
            outputs.withLock { $0.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, Self.isKeyframe(sample))) }
        }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)

        encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: Self.time(ms: 0)))
        XCTAssertFalse(encoder.refreshIfIdle(now: Self.time(ms: 100)), "Refreshed before the screen had gone idle")
        for ms in stride(from: 200, through: 20_000, by: 100) {
            encoder.refreshIfIdle(now: Self.time(ms: ms))
        }
        encoder.stop()

        let frames = outputs.withLock { $0 }
        let times = frames.map(\.pts)
        XCTAssertGreaterThan(frames.count, 50)
        XCTAssertEqual(try XCTUnwrap(times.last), 1_020, accuracy: IdleFrameRefreshPolicy.idleInterval.seconds + 0.11)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, times.count)

        let maximumFrameGap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
        XCTAssertLessThanOrEqual(maximumFrameGap, IdleFrameRefreshPolicy.idleInterval.seconds + 0.1 + 0.001)

        let keyframes = frames.filter(\.isKeyframe).map(\.pts)
        let maximumKeyframeGap = zip(keyframes, keyframes.dropFirst()).map { $1 - $0 }.max() ?? .infinity
        XCTAssertLessThanOrEqual(maximumKeyframeGap, IdleFrameRefreshPolicy.worstCaseKeyframeSpacing)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(keyframes.last), 1_020 - IdleFrameRefreshPolicy.worstCaseKeyframeSpacing)
    }

    /// A real frame captured just before a repeat, but delivered just after it,
    /// must not reach the session out of order.
    func testLateRealFrameAfterRefreshStaysInOrder() throws {
        let encoder = VideoEncoder(idleRefreshEnabled: false)
        let times = Mutex<[Double]>([])
        encoder.outputHandler = { sample in
            times.withLock { $0.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)

        encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: Self.time(ms: 0)))
        XCTAssertTrue(encoder.refreshIfIdle(now: Self.time(ms: 500)))
        encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: Self.time(ms: 450)))
        encoder.stop()

        let recorded = times.withLock { $0 }
        XCTAssertEqual(recorded.count, 3)
        XCTAssertEqual(recorded, recorded.sorted())
        XCTAssertEqual(Set(recorded).count, 3)
    }

    /// The real timer, on the host clock: frames keep coming with no input, and
    /// stop once the encoder is stopped.
    func testIdleRefreshTimerRepeatsFramesUntilStopped() throws {
        let encoder = VideoEncoder()
        let times = Mutex<[Double]>([])
        encoder.outputHandler = { sample in
            times.withLock { $0.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)

        let hostClock = CMClockGetHostTimeClock()
        encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: CMClockGetTime(hostClock)))
        Thread.sleep(forTimeInterval: 1.0)
        let now = CMClockGetTime(hostClock).seconds
        encoder.stop()

        let whileRunning = times.withLock { $0 }
        XCTAssertGreaterThanOrEqual(whileRunning.count, 3, "Expected repeated frames while idle, got \(whileRunning.count)")
        XCTAssertEqual(try XCTUnwrap(whileRunning.last), now, accuracy: 0.5)

        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(times.withLock { $0.count }, whileRunning.count, "Encoder kept emitting after stop()")
    }

    private static func time(ms: Int) -> CMTime {
        CMTime(value: 1_000_000 + Int64(ms), timescale: 1_000)
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    private func makeFrame(width: Int, height: Int, presentationTime: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return try XCTUnwrap(sampleBuffer)
    }
}
