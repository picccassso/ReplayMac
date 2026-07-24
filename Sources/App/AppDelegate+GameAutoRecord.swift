import Branding
import Cocoa
import Defaults
import Feedback
import UI

@MainActor
extension AppDelegate {
    /// Wires up automatic recording for games and starts the watcher if the
    /// feature is enabled. Called once during launch.
    func setupGameAutoRecord() {
        gameActivityMonitor.onGameActivityStarted = { [weak self] gameName in
            self?.handleGameActivityStarted(gameName: gameName)
        }
        gameActivityMonitor.onGameActivityStopped = { [weak self] in
            self?.handleGameActivityStopped()
        }

        settingsObservations.append(Defaults.observe(.autoRecordGamesEnabled) { [weak self] _ in
            self?.handleGameAutoRecordSettingToggled()
        })
        settingsObservations.append(Defaults.observe(.autoRecordGameBundleIDs) { [weak self] _ in
            self?.gameActivityMonitor.refreshManualGameList()
        })

        syncGameAutoRecordMonitoringState()
    }

    /// Responds to the user flipping the feature on or off at runtime.
    ///
    /// Distinct from `syncGameAutoRecordMonitoringState`, which also runs during
    /// launch: only a live toggle should resume always-on recording, otherwise
    /// it would race the normal auto-start path that already runs at launch.
    private func handleGameAutoRecordSettingToggled() {
        syncGameAutoRecordMonitoringState()

        // Turning the feature off hands control back to normal behaviour: if the
        // app would otherwise record on launch, start buffering again right away
        // rather than waiting for a relaunch.
        if !AppSettings.autoRecordGamesEnabled,
           AppSettings.autoStartRecordingOnLaunch,
           !isCaptureRunning {
            startCapturePipeline(userInitiated: false)
        }
    }

    /// Starts or stops the workspace watcher to match the current setting.
    func syncGameAutoRecordMonitoringState() {
        if AppSettings.autoRecordGamesEnabled {
            gameActivityMonitor.start()
        } else {
            gameActivityMonitor.stop()
            // Leaving the feature off should not tear down a recording the user
            // is relying on; only forget that we were the one who started it.
            recordingAutoStartedByGame = false
        }
    }

    private func handleGameActivityStarted(gameName: String) {
        guard Defaults[.hasCompletedOnboarding] else {
            return
        }

        // Never override a recording that is already in progress (manual or a
        // previous auto-start); just adopt it so we know not to stop it.
        guard !isCaptureRunning else {
            return
        }
        recordingAutoStartedByGame = true
        startCapturePipeline(userInitiated: false)
        NotificationManager.shared.showOperationalNotification(
            title: "Recording Started",
            body: "\(AppBranding.name) is recording because \(gameName) is running."
        )
    }

    private func handleGameActivityStopped() {
        guard AppSettings.autoRecordStopWhenGameCloses else { return }
        guard recordingAutoStartedByGame, isCaptureRunning else { return }
        recordingAutoStartedByGame = false
        Task { await stopCapturePipelineAsync() }
        NotificationManager.shared.showOperationalNotification(
            title: "Recording Stopped",
            body: "\(AppBranding.name) stopped recording because the game closed."
        )
    }
}
