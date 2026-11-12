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
    /// updating encoder state on the caller's. Run under
    /// `swift test --sanitize=thread` to catch unguarded state.
    func testOutputCallbackDoesNotRaceWithEncode() throws {
        let encoder = VideoEncoder()
        let delivered = expectation(description: "encoded frame delivered")
        delivered.assertForOverFulfill = false
        encoder.outputHandler = { _ in delivered.fulfill() }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)
        defer { encoder.stop() }

        for index in 0..<30 {
            encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: Self.time(ms: index * 33)))
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
        XCTAssertFalse(IdleFrameRefreshPolicy.shouldRefresh(lastSubmitTime: last, now: CMTime(value: 1_000_200, timescale: 1_000)))
        XCTAssertTrue(IdleFrameRefreshPolicy.shouldRefresh(lastSubmitTime: last, now: CMTime(value: 1_000_250, timescale: 1_000)))
        XCTAssertFalse(IdleFrameRefreshPolicy.shouldRefresh(lastSubmitTime: .invalid, now: last))
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
        let clock = SimulatedClock(Self.time(ms: 0))
        let encoder = VideoEncoder(idleRefreshEnabled: false, clock: { clock.now })
        let outputs = Mutex<[(pts: Double, isKeyframe: Bool)]>([])
        encoder.outputHandler = { sample in
            outputs.withLock { $0.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, Self.isKeyframe(sample))) }
        }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)

        encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: Self.time(ms: 0)))
        XCTAssertFalse(encoder.refreshIfIdle(now: Self.time(ms: 100)), "Refreshed before the screen had gone idle")
        for ms in stride(from: 200, through: 20_000, by: 100) {
            clock.now = Self.time(ms: ms)
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
        let clock = SimulatedClock(Self.time(ms: 0))
        let encoder = VideoEncoder(idleRefreshEnabled: false, clock: { clock.now })
        let times = Mutex<[Double]>([])
        encoder.outputHandler = { sample in
            times.withLock { $0.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)

        encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: Self.time(ms: 0)))
        clock.now = Self.time(ms: 500)
        XCTAssertTrue(encoder.refreshIfIdle(now: Self.time(ms: 500)))
        encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: Self.time(ms: 450)))
        encoder.stop()

        let recorded = times.withLock { $0 }
        XCTAssertEqual(recorded.count, 3)
        XCTAssertEqual(recorded, recorded.sorted())
        XCTAssertEqual(Set(recorded).count, 3)
    }

    /// Frames that reach the encoder well after capture are a live stream, not
    /// a still screen: no repeats may be squeezed in between them.
    func testLateArrivingFramesAreNotTreatedAsIdle() throws {
        let clock = SimulatedClock(Self.time(ms: 0))
        let encoder = VideoEncoder(idleRefreshEnabled: false, clock: { clock.now })
        let times = Mutex<[Double]>([])
        encoder.outputHandler = { sample in
            times.withLock { $0.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        }
        try encoder.start(width: 64, height: 64, fps: 60, codec: .h264, bitrate: 1_000_000)

        // 60 fps, each frame delivered 0.3 s after it was captured, with the
        // idle check running every 0.1 s.
        var nextTick = 300
        for index in 0..<120 {
            let captured = index * 1_000 / 60
            let delivered = captured + 300
            while nextTick <= delivered {
                clock.now = Self.time(ms: nextTick)
                XCTAssertFalse(encoder.refreshIfIdle(now: Self.time(ms: nextTick)), "repeat at \(nextTick) ms")
                nextTick += 100
            }
            clock.now = Self.time(ms: delivered)
            encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: Self.time(ms: captured)))
        }
        encoder.stop()

        let recorded = times.withLock { $0 }
        XCTAssertEqual(recorded.count, 120)
        let gaps = zip(recorded, recorded.dropFirst()).map { $1 - $0 }
        XCTAssertGreaterThan(gaps.min() ?? 0, 0.01, "frames were squeezed together")
    }

    func testStopIdleRefreshEndsRepeatsButKeepsEncoding() throws {
        let clock = SimulatedClock(Self.time(ms: 0))
        let encoder = VideoEncoder(idleRefreshEnabled: false, clock: { clock.now })
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)
        defer { encoder.stop() }

        encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: Self.time(ms: 0)))
        encoder.stopIdleRefresh()
        clock.now = Self.time(ms: 1_000)
        XCTAssertFalse(encoder.refreshIfIdle(now: Self.time(ms: 1_000)))
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

    private final class SimulatedClock: @unchecked Sendable {
        // @unchecked: only touched under `lock`.
        private let lock = NSLock()
        private var _now: CMTime
        init(_ now: CMTime) { _now = now }
        var now: CMTime {
            get { lock.lock(); defer { lock.unlock() }; return _now }
            set { lock.lock(); _now = newValue; lock.unlock() }
        }
    }

    private static func time(ms: Int) -> CMTime {
        CMTime(value: 1_000_000 + Int64(ms), timescale: 1_000)
    }

    /// The compositor hands the encoder 8-bit 4:2:0 full-range canvases tagged
    /// BT.709 (the same layout the screen is captured in). Both codecs have to
    /// take them as they are and still write BT.709 into the stream.
    func testEncodesBT709TaggedFullRange420Frames() throws {
        for codec in [VideoCodec.hevc, .h264] {
            let encoder = VideoEncoder(idleRefreshEnabled: false)
            let outputs = Mutex<[(matrix: String?, primaries: String?, fullRange: Bool?)]>([])
            let delivered = expectation(description: "\(codec) frames delivered")
            delivered.assertForOverFulfill = false
            encoder.outputHandler = { sample in
                let extensions = sample.formatDescription
                    .flatMap { CMFormatDescriptionGetExtensions($0) as? [CFString: Any] } ?? [:]
                let tags = (
                    matrix: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String,
                    primaries: extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String,
                    fullRange: extensions[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool
                )
                let count = outputs.withLock { $0.append(tags); return $0.count }
                if count >= 5 { delivered.fulfill() }
            }
            try encoder.start(width: 320, height: 180, fps: 30, codec: codec, bitrate: 2_000_000)

            for index in 0..<10 {
                encoder.encode(sampleBuffer: try makeFrame(
                    width: 320,
                    height: 180,
                    presentationTime: Self.time(ms: 1_000 + index * 33),
                    pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                    taggedBT709: true
                ))
            }
            wait(for: [delivered], timeout: 10)
            encoder.stop()

            let tags = try XCTUnwrap(outputs.withLock { $0.first })
            XCTAssertEqual(tags.matrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
            XCTAssertEqual(tags.primaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
            XCTAssertEqual(tags.fullRange, true)
        }
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    private func makeFrame(
        width: Int,
        height: Int,
        presentationTime: CMTime,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        taggedBT709: Bool = false
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &pixelBuffer),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        if taggedBT709 {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }

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
