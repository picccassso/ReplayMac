import XCTest
import AVFoundation
@testable import Audio

/// The microphone slider goes past 100%, so the gain stage has to make a
/// quiet voice louder without turning its loud moments into clipping.
final class MicBoostLimiterTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testQuietVoiceIsBoostedByExactlyTheGain() {
        var limiter = PeakLimiter()
        let input = tone(amplitude: 0.05, seconds: 0.2)
        let output = process(input, gain: 4, limiter: &limiter)

        for (before, after) in zip(input, output) {
            XCTAssertEqual(after, before * 4, accuracy: 1e-6)
        }
        XCTAssertEqual(limiter.reduction, 1, "nothing crossed the ceiling, so the limiter stays out of the way")
    }

    func testAudioUnderTheCeilingAtUnityIsUntouched() {
        var limiter = PeakLimiter()
        let input = tone(amplitude: 0.99, seconds: 0.2)
        XCTAssertEqual(process(input, gain: 1, limiter: &limiter), input)
    }

    func testBoostedLoudPassageStaysUnderFullScaleWithoutFlatTops() {
        var limiter = PeakLimiter()
        // 0.5 at 400% would peak at 2.0.
        let output = process(tone(amplitude: 0.5, seconds: 0.5), gain: 4, limiter: &limiter)

        let peak = output.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(peak, PeakLimiter.ceiling)
        XCTAssertGreaterThan(peak, 0.95, "limited to the ceiling, not turned down further")

        // A clamp leaves long runs pinned at full scale. Once the limiter has
        // settled, a 440 Hz tone should only touch it around each crest.
        let settled = output.suffix(Int(sampleRate * 0.25))
        let pinned = settled.filter { abs($0) >= 0.999 }.count
        XCTAssertLessThan(
            Double(pinned) / Double(settled.count),
            0.1,
            "the tone is flat-topped, which is what clipping sounds like"
        )
    }

    func testGainRecoversAfterALoudMoment() {
        var limiter = PeakLimiter()
        _ = process(tone(amplitude: 0.9, seconds: 0.1), gain: 4, limiter: &limiter)
        XCTAssertLessThan(limiter.reduction, 0.5)

        // A second of quiet speech is several release times.
        let quiet = tone(amplitude: 0.05, seconds: 1)
        let output = process(quiet, gain: 4, limiter: &limiter)
        XCTAssertGreaterThan(limiter.reduction, 0.99)
        XCTAssertEqual(abs(output[output.count - 27]), abs(quiet[quiet.count - 27]) * 4, accuracy: 0.005)
    }

    func testReleaseCarriesAcrossBuffers() {
        var whole = PeakLimiter()
        var chunked = PeakLimiter()
        let input = tone(amplitude: 0.9, seconds: 0.05) + tone(amplitude: 0.1, seconds: 0.2)

        let expected = process(input, gain: 3, limiter: &whole)
        var actual: [Float] = []
        for start in stride(from: 0, to: input.count, by: 1024) {
            let chunk = Array(input[start..<min(start + 1024, input.count)])
            actual += process(chunk, gain: 3, limiter: &chunked)
        }

        XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: 1e-5)
        }
    }

    func testStereoChannelsShareOneGain() {
        var limiter = PeakLimiter()
        // Left is loud, right is quiet. Limiting each side on its own would
        // pull the voice toward the quiet side.
        var samples: [Float] = []
        for frame in 0..<4_800 {
            let value = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            samples.append(value * 0.9)
            samples.append(value * 0.09)
        }
        let output = process(samples, gain: 4, limiter: &limiter, channels: 2)

        for frame in stride(from: 100, to: 4_800, by: 97) where abs(output[frame * 2]) > 0.01 {
            XCTAssertEqual(output[frame * 2 + 1] / output[frame * 2], 0.1, accuracy: 0.001)
        }
        XCTAssertLessThanOrEqual(output.map(abs).max() ?? 0, PeakLimiter.ceiling)
    }

    func testTurnedDownMicIsSimplyQuieter() {
        var limiter = PeakLimiter()
        let input = tone(amplitude: 0.8, seconds: 0.1)
        let output = process(input, gain: 0.25, limiter: &limiter)
        for (before, after) in zip(input, output) {
            XCTAssertEqual(after, before * 0.25, accuracy: 1e-6)
        }
    }

    func testMutedMicIsSilent() {
        var limiter = PeakLimiter()
        let output = process(tone(amplitude: 0.8, seconds: 0.05), gain: 0, limiter: &limiter)
        XCTAssertEqual(output.map(abs).max(), 0)
    }

    /// The path `MicCapture` runs on each converted buffer.
    func testApplyVolumeBoostsAndLimitsAnInterleavedBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        ))
        let frames = AVAudioFrameCount(4_800)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<Int(frames) {
            // Quiet for the first half, loud for the second.
            let amplitude: Float = frame < 2_400 ? 0.05 : 0.6
            let value = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate)) * amplitude
            data[frame * 2] = value
            data[frame * 2 + 1] = value
        }
        let quietPeakBefore = (0..<4_800).map { abs(data[$0]) }.max() ?? 0

        var limiter = PeakLimiter()
        MicCapture.applyVolume(4, to: buffer, limiter: &limiter)

        let quietPeakAfter = (0..<4_800).map { abs(data[$0]) }.max() ?? 0
        XCTAssertEqual(quietPeakAfter, quietPeakBefore * 4, accuracy: 0.001)
        let loudPeak = (4_800..<9_600).map { abs(data[$0]) }.max() ?? 0
        XCTAssertLessThanOrEqual(loudPeak, 1)
        XCTAssertGreaterThan(loudPeak, 0.95)
    }

    func testNonFiniteSamplesDoNotReachTheRecording() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        let data = try XCTUnwrap(buffer.floatChannelData)[0]
        let input: [Float] = [0.1, .nan, 0.2, .infinity, -.infinity, 0.3, -0.3, 0.1]
        for (index, value) in input.enumerated() { data[index] = value }

        var limiter = PeakLimiter()
        MicCapture.applyVolume(2, to: buffer, limiter: &limiter)

        for index in 0..<8 {
            XCTAssertTrue(data[index].isFinite, "sample \(index) is \(data[index])")
            XCTAssertLessThanOrEqual(abs(data[index]), 1)
        }
        XCTAssertTrue(limiter.reduction.isFinite)
    }

    // MARK: - Helpers

    private func tone(amplitude: Float, seconds: Double) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { frame in
            Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate)) * amplitude
        }
    }

    private func process(
        _ samples: [Float],
        gain: Float,
        limiter: inout PeakLimiter,
        channels: Int = 1
    ) -> [Float] {
        var samples = samples
        samples.withUnsafeMutableBufferPointer { pointer in
            limiter.process(pointer, channelCount: channels, gain: gain, sampleRate: sampleRate)
        }
        return samples
    }
}
