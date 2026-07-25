import XCTest
@testable import UI

/// The gate itself lives in the app target, which has no test target, so these
/// pin the menu-bar contract the gate drives: a session recording that started
/// capture on its own reports as a session and nothing else.
final class SessionOnlyCapturePresentationTests: XCTestCase {
    @MainActor
    func testSessionOnlyCaptureDoesNotReportBufferRecording() {
        let state = MenuBarState()
        // Capture started by a session: session on, buffer recording off.
        state.setSessionRecording(true)

        XCTAssertTrue(state.isSessionRecording)
        XCTAssertFalse(
            state.isRecording,
            "A session that owns the capture pipeline must not present as buffer recording"
        )
    }

    @MainActor
    func testBufferRecordingAndSessionCanBothBeActive() {
        let state = MenuBarState()
        // Buffer recording was already running when the session started, so the
        // user asked for both and both should be reported.
        state.setRecording(true)
        state.setSessionRecording(true)

        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.isSessionRecording)
    }

    @MainActor
    func testStoppingSessionOnlyCaptureClearsBothFlags() {
        let state = MenuBarState()
        state.setSessionRecording(true)

        state.setSessionRecording(false)
        state.setRecording(false)

        XCTAssertFalse(state.isSessionRecording)
        XCTAssertFalse(state.isRecording)
    }
}
