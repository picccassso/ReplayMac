import XCTest
@testable import Audio

final class MicrophoneStallPolicyTests: XCTestCase {
    private func decide(
        isRunning: Bool = true,
        isSessionActive: Bool = true,
        now: TimeInterval = 1_000,
        referenceUptime: TimeInterval = 980,
        timeout: TimeInterval = 10,
        recoveriesUsed: Int = 0,
        maximumRecoveries: Int = 3
    ) -> MicrophoneStallPolicy.Decision {
        MicrophoneStallPolicy.decide(
            isRunning: isRunning,
            isSessionActive: isSessionActive,
            now: now,
            referenceUptime: referenceUptime,
            timeout: timeout,
            recoveriesUsed: recoveriesUsed,
            maximumRecoveries: maximumRecoveries
        )
    }

    func testSilenceBeyondTimeoutTriggersRebuild() {
        XCTAssertEqual(decide(), .rebuild)
    }

    func testRecentAudioWaits() {
        XCTAssertEqual(decide(referenceUptime: 995), .wait)
    }

    func testExactTimeoutBoundaryRebuilds() {
        XCTAssertEqual(decide(now: 1_000, referenceUptime: 990, timeout: 10), .rebuild)
    }

    func testStoppedMicrophoneIsNeverRebuilt() {
        XCTAssertEqual(decide(isRunning: false), .wait)
    }

    /// A locked screen or sleeping display is not evidence of a broken mic.
    func testInactiveSessionWaitsRatherThanChurning() {
        XCTAssertEqual(decide(isSessionActive: false), .wait)
    }

    func testEngineThatNeverStartedWaits() {
        XCTAssertEqual(decide(referenceUptime: 0), .wait)
    }

    func testRecoveryBudgetIsBounded() {
        XCTAssertEqual(decide(recoveriesUsed: 2), .rebuild)
        XCTAssertEqual(decide(recoveriesUsed: 3), .giveUp)
        XCTAssertEqual(decide(recoveriesUsed: 9), .giveUp)
    }

    /// The dead-device case the watchdog used to loop on forever: every rebuild
    /// re-arms the reference clock, so without a budget this would rebuild on
    /// every tick for the life of the capture session.
    func testRepeatedlyFailingDeviceStopsAfterItsBudget() {
        var recoveriesUsed = 0
        var now: TimeInterval = 1_000
        var rebuilds = 0

        for _ in 0..<20 {
            let decision = decide(now: now + 10, referenceUptime: now, recoveriesUsed: recoveriesUsed)
            if decision == .rebuild {
                rebuilds += 1
                recoveriesUsed += 1
            }
            now += 10
        }

        XCTAssertEqual(rebuilds, 3)
    }

    func testZeroTimeoutDisablesTheWatchdog() {
        XCTAssertEqual(decide(timeout: 0), .wait)
    }
}
