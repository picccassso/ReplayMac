import Defaults
import XCTest
@testable import UI

@MainActor
final class MenuBarStateTests: XCTestCase {
    func testRecordingDurationDisplayCapsAtQuickReplayCapacity() {
        Defaults[.bufferDurationSeconds] = 30
        Defaults[.longBufferEnabled] = false
        let state = MenuBarState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        state.setRecording(true, at: start)
        state.updateRecordingElapsed(at: start.addingTimeInterval(95))

        XCTAssertEqual(state.recordingElapsedSeconds, 95)
        XCTAssertEqual(state.formattedRecordingDuration, "00:30")
    }

    func testRecordingDurationDisplayCapsAtExtendedReplayCapacityWhenEnabled() {
        Defaults[.bufferDurationSeconds] = 30
        Defaults[.longBufferEnabled] = true
        Defaults[.longBufferDurationMinutes] = 5
        defer { Defaults[.longBufferEnabled] = false }
        let state = MenuBarState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        state.setRecording(true, at: start)
        state.updateRecordingElapsed(at: start.addingTimeInterval(95))

        XCTAssertEqual(state.formattedRecordingDuration, "01:35")

        state.updateRecordingElapsed(at: start.addingTimeInterval(400))
        XCTAssertEqual(state.formattedRecordingDuration, "05:00")
    }

    func testRepeatedRecordingUpdateDoesNotResetElapsedTime() {
        let state = MenuBarState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        state.setRecording(true, at: start)
        state.updateRecordingElapsed(at: start.addingTimeInterval(45))
        state.setRecording(true, at: start.addingTimeInterval(45))
        state.updateRecordingElapsed(at: start.addingTimeInterval(75))

        XCTAssertEqual(state.recordingElapsedSeconds, 75)
    }

    func testStoppingRecordingResetsElapsedTime() {
        let state = MenuBarState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        state.setRecording(true, at: start)
        state.updateRecordingElapsed(at: start.addingTimeInterval(45))
        state.setRecording(false, at: start.addingTimeInterval(45))

        XCTAssertEqual(state.recordingElapsedSeconds, 0)
        XCTAssertEqual(state.formattedRecordingDuration, "00:00")
    }

    func testLongRecordingUsesHours() {
        XCTAssertEqual(MenuBarState.formattedDuration(3_723), "01:02:03")
    }

    func testExtendedBufferTimerStartsWhenFeatureIsEnabled() {
        let state = MenuBarState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        state.setRecording(true, at: start)
        state.updateRecordingElapsed(at: start.addingTimeInterval(120))
        state.setExtendedBufferRecording(true, at: start.addingTimeInterval(120))
        state.updateRecordingElapsed(at: start.addingTimeInterval(165))

        XCTAssertEqual(state.recordingElapsedSeconds, 165)
        XCTAssertEqual(state.extendedBufferElapsedSeconds, 45)
        XCTAssertEqual(state.formattedExtendedBufferDuration, "00:45")
    }

    func testSessionRecordingShowsUncappedElapsedTime() {
        Defaults[.bufferDurationSeconds] = 30
        Defaults[.longBufferEnabled] = false
        let state = MenuBarState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        state.setRecording(true, at: start)
        state.setSessionRecording(true, at: start)
        state.updateRecordingElapsed(at: start.addingTimeInterval(95))

        XCTAssertTrue(state.isSessionRecording)
        XCTAssertEqual(state.sessionElapsedSeconds, 95)
        XCTAssertEqual(state.formattedSessionDuration, "01:35")
        XCTAssertEqual(state.formattedRecordingDuration, "01:35")
    }

    func testStoppingSessionRecordingResetsElapsedTime() {
        let state = MenuBarState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        state.setSessionRecording(true, at: start)
        state.updateRecordingElapsed(at: start.addingTimeInterval(45))
        state.setSessionRecording(false)

        XCTAssertFalse(state.isSessionRecording)
        XCTAssertEqual(state.sessionElapsedSeconds, 0)
        XCTAssertEqual(state.formattedSessionDuration, "00:00")
    }

    func testEffectiveAudioVolumesRespectMuteAndPushToMute() {
        XCTAssertEqual(AppSettings.effectiveSystemAudioVolume(volume: 0.8, isMuted: false), 0.8, accuracy: 0.0001)
        XCTAssertEqual(AppSettings.effectiveSystemAudioVolume(volume: 0.8, isMuted: true), 0.0, accuracy: 0.0001)

        XCTAssertEqual(
            AppSettings.effectiveMicrophoneVolume(volume: 0.75, isMuted: false, isPushToMuteActive: false),
            0.75,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AppSettings.effectiveMicrophoneVolume(volume: 0.75, isMuted: true, isPushToMuteActive: false),
            0.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AppSettings.effectiveMicrophoneVolume(volume: 0.75, isMuted: false, isPushToMuteActive: true),
            0.0,
            accuracy: 0.0001
        )
    }

    func testAudioMuteStateUpdatesOnMenuBarState() {
        let state = MenuBarState()
        XCTAssertFalse(state.isMicrophoneMuted)
        XCTAssertFalse(state.isSystemAudioMuted)

        state.setAudioMuteState(isMicrophoneMuted: true, isSystemAudioMuted: false)
        XCTAssertTrue(state.isMicrophoneMuted)
        XCTAssertFalse(state.isSystemAudioMuted)

        state.setAudioMuteState(isMicrophoneMuted: false, isSystemAudioMuted: true)
        XCTAssertFalse(state.isMicrophoneMuted)
        XCTAssertTrue(state.isSystemAudioMuted)
    }

    func testCopyLastClipToPasteboardWritesLastSavedClipAndFallsBackToDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let olderClip = tempDir.appendingPathComponent("Older.mp4")
        let newerClip = tempDir.appendingPathComponent("Newer.mp4")
        try Data("old".utf8).write(to: olderClip)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: olderClip.path
        )
        try Data("new".utf8).write(to: newerClip)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: newerClip.path
        )

        XCTAssertEqual(
            StatusItemController.mostRecentSavedClipURL(in: tempDir)?.standardizedFileURL,
            newerClip.standardizedFileURL
        )

        let controller = StatusItemController()
        controller.setLastClip(olderClip)
        let copiedURL = controller.copyLastClipToPasteboard()
        XCTAssertEqual(copiedURL?.standardizedFileURL, olderClip.standardizedFileURL)

        let pastedURLs = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(pastedURLs?.first?.standardizedFileURL, olderClip.standardizedFileURL)
    }
}
