import XCTest
@preconcurrency import CoreMedia
@testable import RingBuffer

final class RingBufferTests: XCTestCase {

    // MARK: - Helpers

    private static func makeSampleBuffer(pts: Double, isKeyframe: Bool, sampleSize: Int = 1000) -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 60000),
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
            sampleSizeEntryCount: 1,
            sampleSizeArray: [sampleSize],
            sampleBufferOut: &sampleBuffer
        )

        guard let buffer = sampleBuffer else {
            XCTFail("Failed to create sample buffer")
            return sampleBuffer!
        }

        if !isKeyframe {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) {
                let dict = Unmanaged<CFMutableDictionary>
                    .fromOpaque(CFArrayGetValueAtIndex(attachments, 0))
                    .takeUnretainedValue()
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        return buffer
    }

    // MARK: - Tests

    func testAppendAndKeyframeDetection() {
        let buffer = VideoRingBuffer(timeCap: 30, memoryCap: 1_500_000_000)

        buffer.append(encodedSample: Self.makeSampleBuffer(pts: 0.0, isKeyframe: true))
        buffer.append(encodedSample: Self.makeSampleBuffer(pts: 0.016, isKeyframe: false))
        buffer.append(encodedSample: Self.makeSampleBuffer(pts: 0.033, isKeyframe: false))
        buffer.append(encodedSample: Self.makeSampleBuffer(pts: 2.0, isKeyframe: true))

        XCTAssertEqual(buffer.totalSampleCount, 4)
        XCTAssertEqual(buffer.keyframeCount, 2)
    }

    func testEvictionByTime() {
        let buffer = VideoRingBuffer(timeCap: 5.0, memoryCap: 1_500_000_000)

        // Append 10 seconds of frames, GOP = 2s
        for i in 0..<600 {
            let pts = Double(i) / 60.0
            let isKeyframe = (i % 120 == 0)
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: isKeyframe))
        }

        // Duration should be capped near 5s (plus one GOP)
        let duration = buffer.duration
        XCTAssertLessThanOrEqual(duration, 7.0)
        XCTAssertGreaterThan(duration, 3.5)
    }

    /// Regression: GOP-granular eviction settles the buffer just under `timeCap`,
    /// so retaining exactly the requested window returns less than that window.
    /// Retaining the window plus one-GOP-plus headroom must hand out the full
    /// requested duration. Mirrors "Save Last 30 Seconds" with 2s keyframes.
    func testSamplesLastReturnsFullWindowWithHeadroom() {
        let requested = 30.0
        let headroom = 3.0 // AppSettings.ringBufferHeadroomSeconds
        let buffer = VideoRingBuffer(timeCap: requested + headroom, memoryCap: 1_500_000_000)

        // 60 seconds of 60fps frames, keyframe every 2 seconds (GOP = 2s).
        for i in 0..<3600 {
            let pts = Double(i) / 60.0
            let isKeyframe = (i % 120 == 0)
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: isKeyframe))
        }

        let samples = buffer.samples(last: requested)
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(samples.first!).seconds
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(samples.last!).seconds
        XCTAssertGreaterThanOrEqual(
            lastPTS - firstPTS, requested,
            "Buffer with headroom must retain the full requested window"
        )

        // Sanity check the failure mode: without headroom the window comes up short.
        let tight = VideoRingBuffer(timeCap: requested, memoryCap: 1_500_000_000)
        for i in 0..<3600 {
            let pts = Double(i) / 60.0
            let isKeyframe = (i % 120 == 0)
            tight.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: isKeyframe))
        }
        let tightSamples = tight.samples(last: requested)
        let tightSpan = CMSampleBufferGetPresentationTimeStamp(tightSamples.last!).seconds
            - CMSampleBufferGetPresentationTimeStamp(tightSamples.first!).seconds
        XCTAssertLessThan(tightSpan, requested, "Without headroom the window is short by up to one GOP")
    }

    func testEvictionByMemory() {
        let buffer = VideoRingBuffer(timeCap: 100.0, memoryCap: 5000)

        for i in 0..<20 {
            let pts = Double(i)
            let isKeyframe = (i % 5 == 0)
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: isKeyframe, sampleSize: 1000))
        }

        let memory = buffer.currentMemoryBytes
        XCTAssertLessThanOrEqual(memory, 5000)
    }

    func testSamplesLastStartsAtKeyframe() {
        let buffer = VideoRingBuffer(timeCap: 30, memoryCap: 1_500_000_000)

        // GOP = 2s, 60fps
        for i in 0..<300 {
            let pts = Double(i) / 60.0
            let isKeyframe = (i % 120 == 0)
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: isKeyframe))
        }

        let samples = buffer.samples(last: 3.0)
        XCTAssertFalse(samples.isEmpty)

        let first = samples.first!
        let attachments = CMSampleBufferGetSampleAttachmentsArray(first, createIfNecessary: false) as? [[String: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
        XCTAssertTrue(isKeyframe, "Extracted range must start at a keyframe")
    }

    func testMemoryAccounting() {
        let buffer = VideoRingBuffer(timeCap: 30, memoryCap: 1_500_000_000)

        buffer.append(encodedSample: Self.makeSampleBuffer(pts: 0.0, isKeyframe: true, sampleSize: 500))
        buffer.append(encodedSample: Self.makeSampleBuffer(pts: 1.0, isKeyframe: true, sampleSize: 700))

        let memory = buffer.currentMemoryBytes
        XCTAssertEqual(memory, 1200)
    }

    func testGOPAwareEviction() {
        let buffer = VideoRingBuffer(timeCap: 4.0, memoryCap: 1_500_000_000)

        // 10 seconds of frames, 2s GOP
        for i in 0..<600 {
            let pts = Double(i) / 60.0
            let isKeyframe = (i % 120 == 0)
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: isKeyframe))
        }

        let samples = buffer.samples(last: 10.0)
        let first = samples.first!
        let attachments = CMSampleBufferGetSampleAttachmentsArray(first, createIfNecessary: false) as? [[String: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
        XCTAssertTrue(isKeyframe, "Head of ring buffer must be a keyframe after eviction")
    }

    func testClear() {
        let buffer = VideoRingBuffer(timeCap: 30, memoryCap: 1_500_000_000)
        buffer.append(encodedSample: Self.makeSampleBuffer(pts: 0.0, isKeyframe: true))
        buffer.clear()

        XCTAssertEqual(buffer.totalSampleCount, 0)
        XCTAssertEqual(buffer.keyframeCount, 0)
        XCTAssertEqual(buffer.currentMemoryBytes, 0)
        XCTAssertEqual(buffer.duration, 0)
    }

    // MARK: - AudioRingBuffer Tests

    func testAudioRingBufferAppendAndRetrieve() {
        let buffer = AudioRingBuffer(timeCap: 30, memoryCap: 50_000_000)

        buffer.append(Self.makeSampleBuffer(pts: 0.0, isKeyframe: true, sampleSize: 100))
        buffer.append(Self.makeSampleBuffer(pts: 1.0, isKeyframe: true, sampleSize: 100))
        buffer.append(Self.makeSampleBuffer(pts: 2.0, isKeyframe: true, sampleSize: 100))

        XCTAssertEqual(buffer.totalSampleCount, 3)
        XCTAssertEqual(buffer.currentMemoryBytes, 300)

        let samples = buffer.samples(last: 1.5)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(samples.first!).seconds, 1.0, accuracy: 0.001)
    }

    func testAudioRingBufferEvictionByTime() {
        let buffer = AudioRingBuffer(timeCap: 5.0, memoryCap: 50_000_000)

        for i in 0..<600 {
            let pts = Double(i) / 60.0
            buffer.append(Self.makeSampleBuffer(pts: pts, isKeyframe: true, sampleSize: 100))
        }

        let duration = buffer.duration
        XCTAssertLessThanOrEqual(duration, 5.5)
        XCTAssertGreaterThan(duration, 4.0)
    }

    func testAudioRingBufferEvictionByMemory() {
        let buffer = AudioRingBuffer(timeCap: 100.0, memoryCap: 500)

        for i in 0..<20 {
            let pts = Double(i)
            buffer.append(Self.makeSampleBuffer(pts: pts, isKeyframe: true, sampleSize: 100))
        }

        let memory = buffer.currentMemoryBytes
        XCTAssertLessThanOrEqual(memory, 500)
    }

    func testAudioRingBufferSamplesLastAccuracy() {
        let buffer = AudioRingBuffer(timeCap: 30, memoryCap: 50_000_000)

        for i in 0..<300 {
            let pts = Double(i) / 60.0
            buffer.append(Self.makeSampleBuffer(pts: pts, isKeyframe: true, sampleSize: 50))
        }

        let samples = buffer.samples(last: 3.0)
        XCTAssertFalse(samples.isEmpty)

        let firstPTS = CMSampleBufferGetPresentationTimeStamp(samples.first!).seconds
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(samples.last!).seconds
        let span = lastPTS - firstPTS
        XCTAssertGreaterThanOrEqual(span, 2.5)
        XCTAssertLessThanOrEqual(span, 3.5)
    }

    func testAudioRingBufferSamplesBetweenRange() {
        let buffer = AudioRingBuffer(timeCap: 30, memoryCap: 50_000_000)

        for i in 0..<10 {
            buffer.append(Self.makeSampleBuffer(pts: Double(i), isKeyframe: true, sampleSize: 100))
        }

        let samples = buffer.samples(between: 3.0, and: 6.0)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(samples.first!).seconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(samples.last!).seconds, 6.0, accuracy: 0.001)
    }

    func testAudioRingBufferSamplesBetweenRangeReturnsEmptyWhenOutOfWindow() {
        let buffer = AudioRingBuffer(timeCap: 30, memoryCap: 50_000_000)
        for i in 0..<5 {
            buffer.append(Self.makeSampleBuffer(pts: Double(i), isKeyframe: true, sampleSize: 100))
        }

        let samples = buffer.samples(between: 10.0, and: 20.0)
        XCTAssertTrue(samples.isEmpty)
    }

    func testAudioRingBufferClear() {
        let buffer = AudioRingBuffer(timeCap: 30, memoryCap: 50_000_000)
        buffer.append(Self.makeSampleBuffer(pts: 0.0, isKeyframe: true, sampleSize: 100))
        buffer.clear()

        XCTAssertEqual(buffer.totalSampleCount, 0)
        XCTAssertEqual(buffer.currentMemoryBytes, 0)
        XCTAssertEqual(buffer.duration, 0)
    }

    // MARK: - Regression: Non-default buffer duration

    func testVideoRingBufferNonDefaultDuration() {
        let configuredDuration: TimeInterval = 100
        let buffer = VideoRingBuffer(timeCap: configuredDuration, memoryCap: 1_500_000_000)

        // Append 60 seconds of frames at 60fps, GOP=2s
        for i in 0..<3600 {
            let pts = Double(i) / 60.0
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: i % 120 == 0))
        }

        // Should retain all 60 seconds since timeCap is 100
        let duration = buffer.duration
        XCTAssertGreaterThanOrEqual(duration, 58)
        XCTAssertLessThanOrEqual(duration, configuredDuration + 2)

        // samples(last:) should be able to return the full configured window
        let samples = buffer.samples(last: configuredDuration)
        XCTAssertFalse(samples.isEmpty)

        let firstPTS = CMSampleBufferGetPresentationTimeStamp(samples.first!).seconds
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(samples.last!).seconds
        let span = lastPTS - firstPTS
        // Should cover at least 58s of the configured duration (after keyframe alignment)
        XCTAssertGreaterThanOrEqual(span, 58)
    }

    func testVideoRingBufferDynamicTimeCapDecrease() {
        let buffer = VideoRingBuffer(timeCap: 100, memoryCap: 1_500_000_000)

        // Append 60 seconds of frames
        for i in 0..<3600 {
            let pts = Double(i) / 60.0
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: i % 120 == 0))
        }

        // Dynamically reduce timeCap to 30 and trim
        buffer.timeCap = 30
        buffer.trimToDuration(maxSeconds: 30)

        // Duration should now be ~30s (plus one GOP)
        let duration = buffer.duration
        XCTAssertLessThanOrEqual(duration, 33)
        XCTAssertGreaterThan(duration, 25)
    }

    func testVideoRingBufferDynamicTimeCapIncrease() {
        let buffer = VideoRingBuffer(timeCap: 30, memoryCap: 1_500_000_000)

        // Append 60 seconds of frames
        for i in 0..<3600 {
            let pts = Double(i) / 60.0
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: i % 120 == 0))
        }

        // Duration should be capped at ~30s
        var duration = buffer.duration
        XCTAssertLessThanOrEqual(duration, 33)

        // Increase timeCap — buffer should now allow growth on future appends
        buffer.timeCap = 100
        // Already-evicted data cannot be recovered, but no crash or corruption
        duration = buffer.duration
        XCTAssertGreaterThan(duration, 25)
        XCTAssertLessThanOrEqual(duration, 33)

        // Append 60 more seconds — now the buffer should retain more
        for i in 3600..<7200 {
            let pts = Double(i) / 60.0
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: i % 120 == 0))
        }

        duration = buffer.duration
        XCTAssertGreaterThan(duration, 55)
        XCTAssertLessThanOrEqual(duration, 102)
    }

    func testAudioRingBufferNonDefaultDuration() {
        let configuredDuration: TimeInterval = 100
        let buffer = AudioRingBuffer(timeCap: configuredDuration, memoryCap: 50_000_000)

        // Append 60 seconds of audio samples at 60Hz
        for i in 0..<3600 {
            let pts = Double(i) / 60.0
            buffer.append(Self.makeSampleBuffer(pts: pts, isKeyframe: true, sampleSize: 100))
        }

        // Should retain all 60 seconds
        let duration = buffer.duration
        XCTAssertGreaterThanOrEqual(duration, 58)
        XCTAssertLessThanOrEqual(duration, configuredDuration)

        // samples(last:) should return the full configured window
        let samples = buffer.samples(last: configuredDuration)
        XCTAssertFalse(samples.isEmpty)

        let firstPTS = CMSampleBufferGetPresentationTimeStamp(samples.first!).seconds
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(samples.last!).seconds
        let span = lastPTS - firstPTS
        XCTAssertGreaterThanOrEqual(span, 58)
    }

    func testAudioRingBufferDynamicTimeCapDecrease() {
        let buffer = AudioRingBuffer(timeCap: 100, memoryCap: 50_000_000)

        for i in 0..<3600 {
            let pts = Double(i) / 60.0
            buffer.append(Self.makeSampleBuffer(pts: pts, isKeyframe: true, sampleSize: 100))
        }

        buffer.timeCap = 5
        buffer.trimToDuration(maxSeconds: 5)

        let duration = buffer.duration
        XCTAssertLessThanOrEqual(duration, 6)
        XCTAssertGreaterThan(duration, 3)
    }

    func testAudioRingBufferDynamicTimeCapIncrease() {
        let buffer = AudioRingBuffer(timeCap: 5, memoryCap: 50_000_000)

        for i in 0..<600 {
            let pts = Double(i) / 60.0
            buffer.append(Self.makeSampleBuffer(pts: pts, isKeyframe: true, sampleSize: 100))
        }

        var duration = buffer.duration
        XCTAssertLessThanOrEqual(duration, 6)

        buffer.timeCap = 30

        for i in 600..<1800 {
            let pts = Double(i) / 60.0
            buffer.append(Self.makeSampleBuffer(pts: pts, isKeyframe: true, sampleSize: 100))
        }

        duration = buffer.duration
        XCTAssertGreaterThan(duration, 15)
        XCTAssertLessThanOrEqual(duration, 31)
    }

    func testVideoRingBufferSetMemoryCapEvictsExistingSamples() {
        let buffer = VideoRingBuffer(timeCap: 100.0, memoryCap: 10_000)

        for i in 0..<20 {
            let pts = Double(i)
            let isKeyframe = (i % 5 == 0)
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: pts, isKeyframe: isKeyframe, sampleSize: 1000))
        }

        XCTAssertGreaterThan(buffer.currentMemoryBytes, 5000)

        buffer.setMemoryCap(5000)

        XCTAssertLessThanOrEqual(buffer.currentMemoryBytes, 5000)
    }

    func testAudioRingBufferSetMemoryCapEvictsExistingSamples() {
        let buffer = AudioRingBuffer(timeCap: 100.0, memoryCap: 10_000)

        for i in 0..<20 {
            let pts = Double(i)
            buffer.append(Self.makeSampleBuffer(pts: pts, isKeyframe: true, sampleSize: 1000))
        }

        XCTAssertGreaterThan(buffer.currentMemoryBytes, 5000)

        buffer.setMemoryCap(5000)

        XCTAssertLessThanOrEqual(buffer.currentMemoryBytes, 5000)
    }

    // MARK: - Regression: timeCap is written on the main actor while capture appends

    /// Run with `swift test --sanitize=thread` to catch a regression: the caps
    /// used to be plain vars, so a settings change racing a capture-thread
    /// append was a data race.
    func testVideoRingBufferTimeCapConcurrentSetAndAppend() {
        let buffer = VideoRingBuffer(timeCap: 30, memoryCap: 1_500_000_000)
        let samples = (0..<600).map { i in
            Self.makeSampleBuffer(pts: Double(i) / 60.0, isKeyframe: i % 60 == 0)
        }

        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            if worker == 0 {
                for sample in samples {
                    buffer.append(encodedSample: sample)
                }
            } else {
                for i in 0..<600 {
                    buffer.timeCap = i.isMultiple(of: 2) ? 2 : 30
                    _ = buffer.timeCap
                }
            }
        }

        buffer.timeCap = 2
        XCTAssertEqual(buffer.timeCap, 2)
        buffer.append(encodedSample: Self.makeSampleBuffer(pts: 10.0, isKeyframe: true))
        XCTAssertLessThanOrEqual(buffer.duration, 3.0, "New timeCap must apply on the next append")
    }

    func testAudioRingBufferTimeCapConcurrentSetAndAppend() {
        let buffer = AudioRingBuffer(timeCap: 30, memoryCap: 50_000_000)
        let samples = (0..<600).map { i in
            Self.makeSampleBuffer(pts: Double(i) / 60.0, isKeyframe: true, sampleSize: 100)
        }

        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            if worker == 0 {
                for sample in samples {
                    buffer.append(sample)
                }
            } else {
                for i in 0..<600 {
                    buffer.timeCap = i.isMultiple(of: 2) ? 2 : 30
                    _ = buffer.timeCap
                }
            }
        }

        buffer.timeCap = 2
        XCTAssertEqual(buffer.timeCap, 2)
        buffer.append(Self.makeSampleBuffer(pts: 10.0, isKeyframe: true, sampleSize: 100))
        XCTAssertLessThanOrEqual(buffer.duration, 2.0, "New timeCap must apply on the next append")
    }
    // MARK: - Regression: eviction must not spin when no GOP can be dropped

    /// Appends on a background queue so a regression (an eviction loop that
    /// never makes progress while holding the lock) fails on timeout instead
    /// of hanging the whole test run.
    private func appendFinishesPromptly(
        _ buffer: VideoRingBuffer,
        _ samples: [CMSampleBuffer],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let finished = expectation(description: "append returns")
        DispatchQueue.global(qos: .userInitiated).async {
            for sample in samples {
                buffer.append(encodedSample: sample)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }

    func testVideoRingBufferSingleGOPLargerThanMemoryCapDoesNotHang() {
        let buffer = VideoRingBuffer(timeCap: 100, memoryCap: 5000)
        let samples = (0..<20).map { i in
            Self.makeSampleBuffer(pts: Double(i) / 60.0, isKeyframe: i == 0, sampleSize: 1000)
        }

        appendFinishesPromptly(buffer, samples)

        // Nothing is evictable without a second keyframe, so the GOP is kept whole.
        XCTAssertEqual(buffer.totalSampleCount, 20)
        XCTAssertEqual(buffer.keyframeCount, 1)

        // Once the next keyframe arrives the oversized GOP is dropped.
        buffer.append(encodedSample: Self.makeSampleBuffer(pts: 1.0, isKeyframe: true, sampleSize: 1000))
        XCTAssertEqual(buffer.totalSampleCount, 1)
        XCTAssertLessThanOrEqual(buffer.currentMemoryBytes, 5000)
    }

    func testVideoRingBufferSingleGOPLongerThanTimeCapDoesNotHang() {
        let buffer = VideoRingBuffer(timeCap: 1, memoryCap: 1_500_000_000)
        let samples = (0..<180).map { i in
            Self.makeSampleBuffer(pts: Double(i) / 60.0, isKeyframe: i == 0)
        }

        appendFinishesPromptly(buffer, samples)

        XCTAssertEqual(buffer.totalSampleCount, 180)
        XCTAssertGreaterThan(buffer.duration, 1)
    }

    func testVideoRingBufferWithoutKeyframesDoesNotHang() {
        let buffer = VideoRingBuffer(timeCap: 1, memoryCap: 5000)
        let samples = (0..<180).map { i in
            Self.makeSampleBuffer(pts: Double(i) / 60.0, isKeyframe: false, sampleSize: 1000)
        }

        appendFinishesPromptly(buffer, samples)

        XCTAssertEqual(buffer.keyframeCount, 0)
        XCTAssertEqual(buffer.totalSampleCount, 180)
    }

    func testVideoRingBufferSetMemoryCapWithSingleGOPDoesNotHang() {
        let buffer = VideoRingBuffer(timeCap: 100, memoryCap: 1_500_000_000)
        for i in 0..<20 {
            buffer.append(encodedSample: Self.makeSampleBuffer(pts: Double(i) / 60.0, isKeyframe: i == 0, sampleSize: 1000))
        }

        let finished = expectation(description: "setMemoryCap returns")
        DispatchQueue.global(qos: .userInitiated).async {
            buffer.setMemoryCap(1000)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(buffer.totalSampleCount, 20)
    }
}

