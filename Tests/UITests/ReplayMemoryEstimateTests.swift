import XCTest
@testable import UI

final class ReplayMemoryEstimateTests: XCTestCase {
    private func estimate(
        seconds: Int,
        mbps: Double,
        dual: Bool = false,
        separate: Bool = false,
        capMB: Double = 1536
    ) -> ReplayMemoryEstimate {
        ReplayMemoryEstimate.make(
            bufferSeconds: seconds,
            bitrateMbps: mbps,
            isDualMode: dual,
            isSeparateDualSave: separate,
            captureSystemAudio: true,
            captureMicrophone: true,
            memoryCapMB: capMB
        )
    }

    func testFiveMinutesAtDefaultBitrateFitsDefaultCap() {
        let result = estimate(seconds: 300, mbps: 25)

        XCTAssertFalse(result.isCapLimited)
        // (25 + 0.4 audio) Mbps over 303s is about 962 MB.
        XCTAssertEqual(Double(result.requiredBytes), 962_000_000, accuracy: 5_000_000)
        XCTAssertEqual(result.tier, .heavy)
    }

    func testHighBitrateFiveMinutesIsCapLimited() throws {
        let result = estimate(seconds: 300, mbps: 50)

        XCTAssertTrue(result.isCapLimited)
        // 85% of 1536 MiB for video at 6.25 MB/s, minus headroom: about 216s.
        XCTAssertEqual(result.coveredSeconds, 216, accuracy: 2)
        let target = try XCTUnwrap(result.minimumCapMBToFit)
        XCTAssertEqual(target.truncatingRemainder(dividingBy: ReplayMemoryEstimate.memoryCapStepMB), 0)
        XCTAssertFalse(estimate(seconds: 300, mbps: 50, capMB: target).isCapLimited)
        XCTAssertTrue(estimate(seconds: 300, mbps: 50, capMB: target - ReplayMemoryEstimate.memoryCapStepMB).isCapLimited)
    }

    func testDualModeSplitsCapAcrossBuffers() {
        let single = estimate(seconds: 300, mbps: 25)
        let dual = estimate(seconds: 300, mbps: 25, dual: true)

        XCTAssertLessThan(dual.coveredSeconds, single.coveredSeconds)
        XCTAssertTrue(dual.isCapLimited)
    }

    func testSeparateDualSaveDoublesVideoMemory() {
        let sideBySide = estimate(seconds: 60, mbps: 25, dual: true)
        let separate = estimate(seconds: 60, mbps: 25, dual: true, separate: true)

        XCTAssertGreaterThan(separate.requiredBytes, sideBySide.requiredBytes * 19 / 10)
    }

    func testMinimumCapIsNilWhenSliderMaximumIsNotEnough() {
        let result = estimate(seconds: 300, mbps: 50, dual: true, separate: true, capMB: 4096)

        XCTAssertTrue(result.isCapLimited)
        XCTAssertNil(result.minimumCapMBToFit)
    }

    func testTierBoundaries() {
        XCTAssertEqual(estimate(seconds: 60, mbps: 25).tier, .light)
        XCTAssertEqual(estimate(seconds: 61, mbps: 25).tier, .moderate)
        XCTAssertEqual(estimate(seconds: 239, mbps: 25).tier, .moderate)
        XCTAssertEqual(estimate(seconds: 240, mbps: 25).tier, .heavy)
    }

    func testDurationFormatting() {
        XCTAssertEqual(ReplayMemoryEstimate.formatDuration(45), "45 s")
        XCTAssertEqual(ReplayMemoryEstimate.formatDuration(120), "2 min")
        XCTAssertEqual(ReplayMemoryEstimate.formatDuration(209), "3 min 29 s")
    }
}
