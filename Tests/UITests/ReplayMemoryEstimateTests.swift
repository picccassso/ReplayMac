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
        // 25 Mbps video plus two 16-bit PCM audio sources (384 kB/s) over
        // 303s is about 1063 MB.
        XCTAssertEqual(Double(result.requiredBytes), 1_063_200_000, accuracy: 5_000_000)
        XCTAssertEqual(result.tier, .heavy)
    }

    func testHighBitrateFiveMinutesIsCapLimited() throws {
        let result = estimate(seconds: 300, mbps: 50)

        XCTAssertTrue(result.isCapLimited)
        // Both audio buffers take their full 306s first (about 112 MiB); the
        // remaining 1424 MiB holds about 239s of 6.25 MB/s video, minus headroom.
        XCTAssertEqual(result.coveredSeconds, 235, accuracy: 2)
        let target = try XCTUnwrap(result.minimumCapMBToFit)
        XCTAssertEqual(target.truncatingRemainder(dividingBy: ReplayMemoryEstimate.memoryCapStepMB), 0)
        XCTAssertFalse(estimate(seconds: 300, mbps: 50, capMB: target).isCapLimited)
        XCTAssertTrue(estimate(seconds: 300, mbps: 50, capMB: target - ReplayMemoryEstimate.memoryCapStepMB).isCapLimited)
    }

    /// Side-by-side records one composite stream, so it holds as much as a
    /// single display; only separate files split the cap across two buffers.
    func testOnlySeparateDualSaveSplitsTheCap() {
        let single = estimate(seconds: 300, mbps: 25)
        let sideBySide = estimate(seconds: 300, mbps: 25, dual: true)
        let separate = estimate(seconds: 300, mbps: 25, dual: true, separate: true)

        XCTAssertEqual(sideBySide.coveredSeconds, single.coveredSeconds)
        XCTAssertFalse(sideBySide.isCapLimited)
        XCTAssertLessThan(separate.coveredSeconds, single.coveredSeconds)
        XCTAssertTrue(separate.isCapLimited)
    }

    func testSeparateDualSaveDoublesVideoMemory() {
        let sideBySide = estimate(seconds: 60, mbps: 25, dual: true)
        let separate = estimate(seconds: 60, mbps: 25, dual: true, separate: true)

        // The second display adds one more video stream; audio is shared.
        let oneVideoStream = 25_000_000 / 8 * (60 + Int(AppSettings.ringBufferHeadroomSeconds))
        XCTAssertEqual(separate.requiredBytes - sideBySide.requiredBytes, oneVideoStream, accuracy: 1_000)
    }

    func testMinimumCapIsNilWhenSliderMaximumIsNotEnough() {
        // Two 80 Mbps streams for five minutes need about 6 GB, past the
        // slider's 4 GB. (The slider's own 50 Mbps maximum now fits: separate
        // files share the cap between two buffers, not three.)
        let result = estimate(seconds: 300, mbps: 80, dual: true, separate: true, capMB: 4096)

        XCTAssertTrue(result.isCapLimited)
        XCTAssertNil(result.minimumCapMBToFit)
    }

    /// The estimate used to budget audio at the 0.2 Mbps AAC rate, a fraction
    /// of the PCM the buffers actually hold.
    func testAudioIsBudgetedAtTheBufferedPCMRate() {
        let withAudio = estimate(seconds: 60, mbps: 25)
        let videoOnly = ReplayMemoryEstimate.make(
            bufferSeconds: 60,
            bitrateMbps: 25,
            isDualMode: false,
            isSeparateDualSave: false,
            captureSystemAudio: false,
            captureMicrophone: false,
            memoryCapMB: 1536
        )
        let retained = 60 + AppSettings.ringBufferHeadroomSeconds
        XCTAssertEqual(
            Double(withAudio.requiredBytes - videoOnly.requiredBytes),
            2 * AppSettings.audioRingBufferBytesPerSecond * retained,
            accuracy: 1_000
        )
    }

    /// Coverage must never promise more than the audio buffers can hold.
    func testCoveredSecondsNeverExceedWhatAudioHolds() {
        for capMB in [256.0, 768, 1536, 4096] {
            for mbps in [5.0, 25, 80] {
                let result = estimate(seconds: 300, mbps: mbps, capMB: capMB)
                let caps = AppSettings.ringBufferMemoryCaps(
                    isDualMode: false,
                    isSeparateDualSave: false,
                    captureSystemAudio: true,
                    captureMicrophone: true,
                    retainedSeconds: 300 + AppSettings.ringBufferHeadroomSeconds,
                    totalCapMB: capMB
                )
                let audioSeconds = Double(caps.audioPerBuffer) / AppSettings.audioRingBufferBytesPerSecond
                XCTAssertLessThanOrEqual(
                    Double(result.coveredSeconds),
                    audioSeconds - AppSettings.ringBufferHeadroomSeconds + 1,
                    "cap=\(capMB) mbps=\(mbps)"
                )
            }
        }
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
