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
