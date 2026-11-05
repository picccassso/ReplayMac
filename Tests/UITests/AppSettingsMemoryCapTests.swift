import XCTest
@testable import UI

final class AppSettingsMemoryCapTests: XCTestCase {
    func testSingleDisplayAllocatesOneVideoBufferShare() {
        let caps = AppSettings.ringBufferMemoryCaps(
            isDualMode: false,
            captureSystemAudio: true,
            captureMicrophone: true,
            totalCapMB: 1024
        )

        XCTAssertGreaterThanOrEqual(caps.videoPerBuffer, 32 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(caps.audioPerBuffer, 8 * 1024 * 1024)

        let totalBytes = Int(1024 * 1024 * 1024)
        let allocated = caps.videoPerBuffer + (caps.audioPerBuffer * 2)
        XCTAssertLessThanOrEqual(allocated, totalBytes)
    }

    func testDualDisplayAllocatesThreeVideoBuffers() {
        let singleCaps = AppSettings.ringBufferMemoryCaps(
            isDualMode: false,
            captureSystemAudio: true,
            captureMicrophone: false,
            totalCapMB: 1536
        )
        let dualCaps = AppSettings.ringBufferMemoryCaps(
            isDualMode: true,
            captureSystemAudio: true,
            captureMicrophone: false,
            totalCapMB: 1536
        )

        XCTAssertLessThan(dualCaps.videoPerBuffer, singleCaps.videoPerBuffer)
    }

    func testAudioDisabledStillReturnsAudioCapFloor() {
        let caps = AppSettings.ringBufferMemoryCaps(
            isDualMode: false,
            captureSystemAudio: false,
            captureMicrophone: false,
            totalCapMB: 512
        )

        XCTAssertGreaterThanOrEqual(caps.audioPerBuffer, 8 * 1024 * 1024)
    }

    /// Audio is buffered as raw PCM, so a fixed 15% share ran the audio buffers
    /// out long before video and clips opened on silence. Every split has to
    /// leave audio holding at least as long as video.
    func testAudioBuffersHoldAsLongAsVideoBuffers() {
        for capMB in [256.0, 512, 1024, 1408, 1536, 4096] {
            for mbps in [4.0, 10, 25, 50, 100] {
                for (system, mic) in [(true, false), (false, true), (true, true)] {
                    for dual in [false, true] {
                        let caps = AppSettings.ringBufferMemoryCaps(
                            isDualMode: dual,
                            captureSystemAudio: system,
                            captureMicrophone: mic,
                            bitrateMbps: mbps,
                            totalCapMB: capMB
                        )
                        let videoSeconds = Double(caps.videoPerBuffer) / (mbps * 1_000_000 / 8)
                        let audioSeconds = Double(caps.audioPerBuffer) / AppSettings.audioRingBufferBytesPerSecond
                        XCTAssertGreaterThanOrEqual(
                            audioSeconds, videoSeconds - 0.5,
                            "cap=\(capMB) mbps=\(mbps) system=\(system) mic=\(mic) dual=\(dual): audio \(audioSeconds)s < video \(videoSeconds)s"
                        )

                        let buffers = (dual ? 3 : 1) * caps.videoPerBuffer
                            + caps.audioPerBuffer * ((system ? 1 : 0) + (mic ? 1 : 0))
                        XCTAssertLessThanOrEqual(buffers, Int(capMB * 1024 * 1024) + 1)
                    }
                }
            }
        }
    }

    /// The setup that produced 13 s of silence: a 5 minute buffer with both
    /// audio sources at a 1408 MB cap held only about 288 s of audio.
    func testFiveMinuteBufferWithBothAudioSourcesFitsBelowDefaultCap() {
        let caps = AppSettings.ringBufferMemoryCaps(
            isDualMode: false,
            captureSystemAudio: true,
            captureMicrophone: true,
            bitrateMbps: 20,
            totalCapMB: 1408
        )
        let audioSeconds = Double(caps.audioPerBuffer) / AppSettings.audioRingBufferBytesPerSecond
        XCTAssertGreaterThanOrEqual(audioSeconds, 300 + AppSettings.ringBufferHeadroomSeconds)
    }

    func testAudioRingBufferRateMatchesStereoFloatPCM() {
        XCTAssertEqual(AppSettings.audioRingBufferBytesPerSecond, 48_000 * 2 * Double(MemoryLayout<Float>.size))
    }

    func testRetinaPixelDimensionUsesBackingScale() {
        XCTAssertEqual(AppSettings.retinaPixelDimension(for: 1512, pointPixelScale: 2.0), 3024)
    }

    func testRetinaPixelDimensionFallsBackToCurrentSizeForOneTimesDisplays() {
        XCTAssertEqual(AppSettings.retinaPixelDimension(for: 1920, pointPixelScale: 1.0), 1920)
        XCTAssertEqual(AppSettings.retinaPixelDimension(for: 1920, pointPixelScale: 0.0), 1920)
    }

    func testRetinaPixelDimensionIsCappedAtDisplayPixelSize() {
        XCTAssertEqual(
            AppSettings.retinaPixelDimension(
                for: 3024,
                pointPixelScale: 2.0,
                maxPixelDimension: 3024
            ),
            3024
        )
    }

    func testAudioRingBufferHeadroomMatchesVideoRingBufferHeadroom() {
        XCTAssertGreaterThanOrEqual(
            AppSettings.ringBufferHeadroomSeconds, 2.0,
            "Audio and video ring buffer headroom must be at least one full GOP interval (~2s)"
        )
        XCTAssertEqual(
            AppSettings.ringBufferTimeCapSeconds,
            TimeInterval(AppSettings.bufferDurationSeconds) + AppSettings.ringBufferHeadroomSeconds
        )
    }
}
