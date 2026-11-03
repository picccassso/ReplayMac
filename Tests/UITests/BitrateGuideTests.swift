import XCTest
@testable import UI

final class BitrateGuideTests: XCTestCase {
    func testSweetSpotRunsFromPerformanceToUltra() {
        // 1512 × 982 at 120 fps is about 0.4 of the 1440p reference, doubled for fps.
        let guide = BitrateGuide(width: 1512, height: 982, frameRate: 120, isH264SDR: false)

        XCTAssertEqual(guide.sweetSpot, 14...32)
        XCTAssertEqual(guide.recommendedMbps, 20)
    }

    func testCustomRecommendsWhatQualityWould() {
        let custom = BitrateGuide.recommendedMbps(preset: .custom, width: 2560, height: 1440, frameRate: 60, isH264SDR: false)
        let quality = BitrateGuide.recommendedMbps(preset: .quality, width: 2560, height: 1440, frameRate: 60, isH264SDR: false)

        XCTAssertEqual(custom, 25)
        XCTAssertEqual(custom, quality)
    }

    func testZones() {
        let guide = BitrateGuide(width: 1512, height: 982, frameRate: 120, isH264SDR: false)

        XCTAssertEqual(guide.zone(for: 13), .low)
        XCTAssertEqual(guide.zone(for: 14), .sweetSpot)
        XCTAssertEqual(guide.zone(for: 32), .sweetSpot)
        XCTAssertEqual(guide.zone(for: 50), .high)
    }

    func testRetinaAt120NeedsTheTopOfTheSlider() {
        let guide = BitrateGuide(width: 3024, height: 1964, frameRate: 120, isH264SDR: false)

        XCTAssertEqual(guide.sweetSpot, 50...50)
        XCTAssertEqual(guide.zone(for: 50), .sweetSpot)
        XCTAssertEqual(guide.zone(for: 49), .low)
    }

    func testSmallLowFrameRateOutputSitsAtTheBottom() {
        let guide = BitrateGuide(width: 756, height: 491, frameRate: 30, isH264SDR: false)

        XCTAssertEqual(guide.sweetSpot, 10...10)
        XCTAssertEqual(guide.zone(for: 11), .high)
    }

    func testH264NeedsMoreThanHEVC() {
        let hevc = BitrateGuide(width: 2560, height: 1440, frameRate: 60, isH264SDR: false)
        let h264 = BitrateGuide(width: 2560, height: 1440, frameRate: 60, isH264SDR: true)

        XCTAssertGreaterThan(h264.recommendedMbps, hevc.recommendedMbps)
        XCTAssertGreaterThan(h264.sweetSpot.lowerBound, hevc.sweetSpot.lowerBound)
    }

    func testBytesPerMinute() {
        // 20 Mbps is 2.5 MB/s, so 150 MB a minute.
        XCTAssertEqual(BitrateGuide.bytesPerMinute(20), 150_000_000)
    }

    func testMessagesFollowTheZone() {
        let guide = BitrateGuide(width: 1512, height: 982, frameRate: 120, isH264SDR: false)

        XCTAssertTrue(guide.message(for: 10).contains("below 14 Mbps"))
        XCTAssertTrue(guide.message(for: 20).contains("14–32 Mbps"))
        XCTAssertTrue(guide.message(for: 50).contains("Above 32 Mbps"))
    }

    func testIllustrativeQualityStartsTheSweetSpotAt85PercentAndFlattens() {
        let guide = BitrateGuide(width: 1512, height: 982, frameRate: 120, isH264SDR: false)

        XCTAssertEqual(guide.illustrativeQuality(at: 14), 0.85, accuracy: 0.001)
        let gainInBand = guide.illustrativeQuality(at: 24) - guide.illustrativeQuality(at: 14)
        let gainPastBand = guide.illustrativeQuality(at: 50) - guide.illustrativeQuality(at: 40)
        XCTAssertGreaterThan(gainInBand, gainPastBand * 5)
    }

    func testPreviewOnlyBreaksUpBelowTheSweetSpot() {
        XCTAssertEqual(BitrateSampleScene.blockSize(forQuality: 0.85), 1)
        XCTAssertEqual(BitrateSampleScene.blockSize(forQuality: 0.99), 1)
        XCTAssertGreaterThan(BitrateSampleScene.blockSize(forQuality: 0.5), 5)
    }

    func testBitsPerPixel() {
        // 1920 × 1080 at 60 fps is about 124 million pixels a second.
        XCTAssertEqual(BitrateGuide.bitsPerPixel(mbps: 25, width: 1920, height: 1080, frameRate: 60), 0.2, accuracy: 0.001)
        XCTAssertEqual(BitrateGuide.bitsPerPixel(mbps: 25, width: 0, height: 0, frameRate: 60), 0)
    }
}
