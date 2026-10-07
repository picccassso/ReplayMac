import XCTest
@testable import UI

final class ReplayControlLabelsTests: XCTestCase {
    @MainActor
    func testAudioLabelsCoverDisabledMutedAndActive() {
        XCTAssertEqual(ReplayControlLabels.microphone(isEnabled: false, isMuted: false).title, "Enable & Unmute Microphone")
        XCTAssertEqual(ReplayControlLabels.microphone(isEnabled: true, isMuted: true).symbol, "mic.slash.fill")
        XCTAssertEqual(ReplayControlLabels.microphone(isEnabled: true, isMuted: false).title, "Mute Microphone")
        XCTAssertEqual(ReplayControlLabels.systemAudio(isEnabled: false, isMuted: true).title, "Enable & Unmute System Audio")
        XCTAssertEqual(ReplayControlLabels.systemAudio(isEnabled: true, isMuted: true).title, "Unmute System Audio")
        XCTAssertEqual(ReplayControlLabels.systemAudio(isEnabled: true, isMuted: false).symbol, "speaker.wave.2.fill")
    }

    @MainActor
    func testToggleAndSaveTitles() {
        XCTAssertEqual(ReplayControlLabels.replayBuffer(isRecording: false).title, "Start Replay Buffer")
        XCTAssertEqual(ReplayControlLabels.replayBuffer(isRecording: true).title, "Stop Replay Buffer")
        XCTAssertEqual(ReplayControlLabels.session(isRecording: true).title, "Stop & Save Session")
        XCTAssertEqual(ReplayControlLabels.saveReplay(seconds: 300).title, "Save Last 300 Seconds")
        XCTAssertEqual(ReplayControlLabels.saveExtendedReplay(seconds: 600).title, "Save Last 10:00")
    }

    @MainActor
    func testBufferLinesReportFillingReadyAndStopped() {
        XCTAssertEqual(
            ReplayControlLabels.quickReplayLine(bufferedSeconds: 12.8, capSeconds: 30, memory: "1 MB", isRecording: true),
            "Quick replay: 00:12 / 00:30 · 1 MB (filling…)")
        // Headroom beyond the replay window is never reported.
        XCTAssertEqual(
            ReplayControlLabels.quickReplayLine(bufferedSeconds: 34, capSeconds: 30, memory: "1 MB", isRecording: true),
            "Quick replay: 00:30 / 00:30 · 1 MB (ready)")
        XCTAssertEqual(
            ReplayControlLabels.quickReplayLine(bufferedSeconds: 0, capSeconds: 30, memory: "Zero KB", isRecording: false),
            "Quick replay: 00:00 / 00:30 · Zero KB")
        XCTAssertEqual(
            ReplayControlLabels.extendedReplayLine(elapsedSeconds: 900, capSeconds: 600, isRecording: true),
            "Extended replay: 10:00 / 10:00 (ready)")
        XCTAssertTrue(ReplayControlLabels.isSessionOnlyCapture(isRecording: false, isSessionRecording: true))
        XCTAssertFalse(ReplayControlLabels.isSessionOnlyCapture(isRecording: true, isSessionRecording: true))
    }
}
