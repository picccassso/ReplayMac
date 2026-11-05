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
        // 25 Mbps video plus two raw PCM audio sources (768 kB/s) over 303s
        // is about 1180 MB.
        XCTAssertEqual(Double(result.requiredBytes), 1_179_600_000, accuracy: 5_000_000)
        XCTAssertEqual(result.tier, .heavy)
    }

    func testHighBitrateFiveMinutesIsCapLimited() throws {
        let result = estimate(seconds: 300, mbps: 50)

        XCTAssertTrue(result.isCapLimited)
        // 1536 MiB shared by 6.25 MB/s of video and 0.768 MB/s of audio, minus
        // headroom: about 226s for every buffer.
        XCTAssertEqual(result.coveredSeconds, 226, accuracy: 2)
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

        // The second display adds one more video stream; audio is shared.
        let oneVideoStream = 25_000_000 / 8 * (60 + Int(AppSettings.ringBufferHeadroomSeconds))
        XCTAssertEqual(separate.requiredBytes - sideBySide.requiredBytes, oneVideoStream, accuracy: 1_000)
    }

    func testMinimumCapIsNilWhenSliderMaximumIsNotEnough() {
        let result = estimate(seconds: 300, mbps: 50, dual: true, separate: true, capMB: 4096)

        XCTAssertTrue(result.isCapLimited)
        XCTAssertNil(result.minimumCapMBToFit)
    }

    /// The estimate used to budget audio at the 0.2 Mbps AAC rate, about a
    /// fifteenth of the raw PCM the buffers actually hold.
    func testAudioIsBudgetedAtTheRawPCMRate() {
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
                    captureSystemAudio: true,
                    captureMicrophone: true,
                    bitrateMbps: mbps,
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
