import Defaults
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
    func testAppAudioMuteLabelsAndMenuTitles() {
        XCTAssertEqual(
            ReplayControlLabels.appAudioMute(isSystemAudioEnabled: false, isPerAppMode: false, mutedCount: 2).title,
            "Mute App Audio"
        )
        XCTAssertEqual(
            ReplayControlLabels.appAudioMute(isSystemAudioEnabled: true, isPerAppMode: true, mutedCount: 2).title,
            "Selected App Audio"
        )
        XCTAssertEqual(
            ReplayControlLabels.appAudioMute(isSystemAudioEnabled: true, isPerAppMode: false, mutedCount: 0).title,
            "Mute App Audio"
        )
        XCTAssertEqual(
            ReplayControlLabels.appAudioMute(isSystemAudioEnabled: true, isPerAppMode: false, mutedCount: 1).title,
            "1 App Muted"
        )
        XCTAssertEqual(
            ReplayControlLabels.appAudioMute(isSystemAudioEnabled: true, isPerAppMode: false, mutedCount: 3).title,
            "3 Apps Muted"
        )

        XCTAssertEqual(ReplayControlLabels.mutedAppsMenuTitle(mutedCount: 0), "Mute App Audio")
        XCTAssertEqual(ReplayControlLabels.mutedAppsMenuTitle(mutedCount: 1), "Mute App Audio (1 Muted)")
        XCTAssertEqual(ReplayControlLabels.mutedAppsMenuTitle(mutedCount: 4), "Mute App Audio (4 Muted)")
    }

    func testAppSettingsMuteAndUnmuteAudioApps() {
        let original = Defaults[.mutedAudioAppBundleIDs]
        defer { Defaults[.mutedAudioAppBundleIDs] = original }

        Defaults[.mutedAudioAppBundleIDs] = []
        XCTAssertFalse(AppSettings.isAppAudioMuted("com.spotify.client"))

        AppSettings.muteAudioApp("com.spotify.client")
        XCTAssertTrue(AppSettings.isAppAudioMuted("com.spotify.client"))
        XCTAssertTrue(AppSettings.isAppAudioMuted("COM.SPOTIFY.CLIENT"))
        XCTAssertEqual(AppSettings.mutedAudioAppBundleIDs, ["com.spotify.client"])

        // Duplicate mutes should be ignored.
        AppSettings.muteAudioApp("com.spotify.client")
        XCTAssertEqual(AppSettings.mutedAudioAppBundleIDs.count, 1)

        AppSettings.toggleAudioAppMute("com.hnc.Discord")
        XCTAssertEqual(AppSettings.mutedAudioAppBundleIDs, ["com.spotify.client", "com.hnc.Discord"])

        AppSettings.toggleAudioAppMute("com.spotify.client")
        XCTAssertFalse(AppSettings.isAppAudioMuted("com.spotify.client"))
        XCTAssertEqual(AppSettings.mutedAudioAppBundleIDs, ["com.hnc.Discord"])

        AppSettings.unmuteAllAudioApps()
        XCTAssertTrue(AppSettings.mutedAudioAppBundleIDs.isEmpty)
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
