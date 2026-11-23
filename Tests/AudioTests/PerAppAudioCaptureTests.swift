import XCTest
@testable import Audio

final class PerAppAudioCaptureTests: XCTestCase {
    func testNeedsWorkspaceRefreshSemantics() {
        XCTAssertFalse(SystemAudioFilterMode.exclude(bundleIDs: []).needsWorkspaceRefresh)
        XCTAssertTrue(SystemAudioFilterMode.exclude(bundleIDs: ["com.spotify.client"]).needsWorkspaceRefresh)
        XCTAssertTrue(SystemAudioFilterMode.includeOnly(bundleID: "com.game.Title").needsWorkspaceRefresh)
    }

    func testUnexpectedStopHandlerFiresOnlyWhenStreamWasRunning() {
        let capture = PerAppAudioCapture()
        let expectation = expectation(description: "Unexpected stop handler invoked")
        expectation.expectedFulfillmentCount = 1

        capture.setUnexpectedStopHandler { _ in
            expectation.fulfill()
        }

        // Not running → must not fire
        capture.simulateStreamStopped(error: PerAppAudioCaptureError.noDisplay, wasRunning: false)
        // Was running → must fire
        capture.simulateStreamStopped(error: PerAppAudioCaptureError.noDisplay, wasRunning: true)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNil(capture.lastAudioSampleDate)
        XCTAssertNil(capture.lastStreamStartedAt)
    }

    func testInitialStateIsIdleAndHasNoStats() {
        let capture = PerAppAudioCapture()
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(capture.needsWorkspaceRefresh)
        XCTAssertNil(capture.lastAudioSampleDate)
        XCTAssertNil(capture.lastStreamStartedAt)
        XCTAssertNil(capture.capturedDisplayID)
    }
}
