import XCTest
import CoreMedia
@testable import Audio

final class MicrophoneTimelineTests: XCTestCase {
    private let sampleRate: Double = 48_000
    private let framesPerBuffer: Int64 = 1_024

    private func hostTime(seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }

    private func makeTimeline() -> MicrophoneTimeline {
        MicrophoneTimeline(resyncThresholdSeconds: 0.1)
    }

    /// Buffer duration at 48kHz/1024 frames, ~21.3ms.
    private var bufferSeconds: Double {
        Double(framesPerBuffer) / sampleRate
    }

    func testFirstBufferAnchorsToItsHostTime() {
        var timeline = makeTimeline()
        let stamp = timeline.stamp(
            hostTime: hostTime(seconds: 100),
            frameCount: framesPerBuffer,
            sampleRate: sampleRate
        )

        XCTAssertEqual(stamp.presentationTime.seconds, 100, accuracy: 0.0001)
        XCTAssertNil(stamp.reanchoredBySeconds)
    }

    func testContiguousBuffersAdvanceByFrameCount() {
        var timeline = makeTimeline()
        _ = timeline.stamp(hostTime: hostTime(seconds: 100), frameCount: framesPerBuffer, sampleRate: sampleRate)

        // Host times carry a little jitter; frame counting should ignore it.
        let jitter = [0.0011, -0.0007, 0.0019]
        for index in 1...3 {
            let nominal = 100 + Double(index) * bufferSeconds
            let stamp = timeline.stamp(
                hostTime: hostTime(seconds: nominal + jitter[index - 1]),
                frameCount: framesPerBuffer,
                sampleRate: sampleRate
            )
            XCTAssertNil(stamp.reanchoredBySeconds, "jitter must not re-anchor")
            XCTAssertEqual(stamp.presentationTime.seconds, nominal, accuracy: 0.0001)
        }
    }

    func testDropoutReanchorsInsteadOfShiftingTheTimeline() {
        var timeline = makeTimeline()
        _ = timeline.stamp(hostTime: hostTime(seconds: 100), frameCount: framesPerBuffer, sampleRate: sampleRate)

        // The engine goes away for 8 seconds, then delivers again.
        let resumeAt = 100 + bufferSeconds + 8
        let stamp = timeline.stamp(
            hostTime: hostTime(seconds: resumeAt),
            frameCount: framesPerBuffer,
            sampleRate: sampleRate
        )

        // The old behaviour stamped this at ~100.043 — 8s adrift of the video
        // clock, and permanently so for every buffer after it.
        XCTAssertEqual(stamp.presentationTime.seconds, resumeAt, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(stamp.reanchoredBySeconds), 8, accuracy: 0.001)
    }

    func testTimelineStaysAlignedAcrossRepeatedDropouts() {
        var timeline = makeTimeline()
        var now: Double = 100
        _ = timeline.stamp(hostTime: hostTime(seconds: now), frameCount: framesPerBuffer, sampleRate: sampleRate)

        for _ in 0..<5 {
            now += bufferSeconds + 3
            let stamp = timeline.stamp(
                hostTime: hostTime(seconds: now),
                frameCount: framesPerBuffer,
                sampleRate: sampleRate
            )
            XCTAssertEqual(
                stamp.presentationTime.seconds,
                now,
                accuracy: 0.0001,
                "each dropout must re-anchor rather than accumulate"
            )
        }
    }

    func testDriftBelowThresholdDoesNotReanchor() {
        var timeline = makeTimeline()
        _ = timeline.stamp(hostTime: hostTime(seconds: 100), frameCount: framesPerBuffer, sampleRate: sampleRate)

        let stamp = timeline.stamp(
            hostTime: hostTime(seconds: 100 + bufferSeconds + 0.09),
            frameCount: framesPerBuffer,
            sampleRate: sampleRate
        )
        XCTAssertNil(stamp.reanchoredBySeconds)
    }

    func testResetClearsTheAnchor() {
        var timeline = makeTimeline()
        _ = timeline.stamp(hostTime: hostTime(seconds: 100), frameCount: framesPerBuffer, sampleRate: sampleRate)
        timeline.reset()

        let stamp = timeline.stamp(
            hostTime: hostTime(seconds: 500),
            frameCount: framesPerBuffer,
            sampleRate: sampleRate
        )
        XCTAssertEqual(stamp.presentationTime.seconds, 500, accuracy: 0.0001)
        XCTAssertNil(stamp.reanchoredBySeconds, "a fresh timeline anchors rather than reporting drift")
    }

    func testDegenerateInputsAreStampedAtHostTime() {
        var timeline = makeTimeline()
        let zeroRate = timeline.stamp(hostTime: hostTime(seconds: 7), frameCount: framesPerBuffer, sampleRate: 0)
        XCTAssertEqual(zeroRate.presentationTime.seconds, 7, accuracy: 0.0001)

        let zeroFrames = timeline.stamp(hostTime: hostTime(seconds: 9), frameCount: 0, sampleRate: sampleRate)
        XCTAssertEqual(zeroFrames.presentationTime.seconds, 9, accuracy: 0.0001)
    }
}
