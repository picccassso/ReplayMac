import Foundation
import Save
import UI
import Feedback

@MainActor
extension AppDelegate {
    /// Start→stop session recording: writes continuously until stopped, then
    /// saves one MP4 (screen + system audio + mic per current capture settings).
    func toggleSessionRecording() {
        Task {
            if isSessionRecording {
                await stopSessionRecording(userInitiated: true)
            } else {
                await startSessionRecording(userInitiated: true)
            }
        }
    }

    func startSessionRecording(userInitiated: Bool) async {
        guard !isSessionRecording, !isSessionFinalizeInProgress else {
            return
        }

        guard let outputDirectory = selectedOutputDirectoryOrNotify() else {
            return
        }

        if isSeparateDualSaveMode {
            NotificationManager.shared.showOperationalNotification(
                title: "Session Recording Unavailable",
                body: "Session recording is not available while dual display clips are saved as separate files. Switch to a side-by-side save, or use single-display capture."
            )
            return
        }

        // Reserve room for at least a few minutes so we don't start into a full disk.
        if let diskFailure = diskSpaceFailure(lastSeconds: 5 * 60, streamCount: 1) {
            let message = SavePreflight.notificationMessage(for: diskFailure)
            NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            return
        }

        if !isCaptureRunning {
            await startCapturePipelineAsync(userInitiated: userInitiated)
            guard isCaptureRunning else {
                return
            }
        }

        await sessionRecorder.configure(
            enabled: true,
            maxDurationSeconds: .infinity,
            outputDirectory: outputDirectory,
            storage: .session
        )

        isSessionRecording = true
        menuBarState.setSessionRecording(true)
        statusItemController.refreshPresentation()

        if userInitiated {
            NotificationManager.shared.showOperationalNotification(
                title: "Session Recording Started",
                body: "Recording until you stop it. Stop from the menu bar or your session hotkey to save the file."
            )
        }
    }

    @discardableResult
    func stopSessionRecording(userInitiated: Bool) async -> URL? {
        guard isSessionRecording || isSessionFinalizeInProgress else {
            return nil
        }
        guard !isSessionFinalizeInProgress else {
            return nil
        }

        isSessionFinalizeInProgress = true
        isSessionRecording = false
        menuBarState.setSessionRecording(false)
        statusItemController.refreshPresentation()

        let durationHint = max(menuBarState.sessionElapsedSeconds, 1)
        if let diskFailure = diskSpaceFailure(lastSeconds: durationHint, streamCount: 2) {
            let message = SavePreflight.notificationMessage(for: diskFailure)
            NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            await discardSessionRecording()
            isSessionFinalizeInProgress = false
            statusItemController.refreshPresentation()
            return nil
        }

        if !menuBarState.beginSaving() {
            // Another save is in flight — wait briefly then try again once.
            try? await Task.sleep(for: .milliseconds(400))
            if !menuBarState.beginSaving() {
                await discardSessionRecording()
                isSessionFinalizeInProgress = false
                NotificationManager.shared.showOperationalNotification(
                    title: "Couldn’t Save Session",
                    body: "Another save was already in progress. The session recording was discarded."
                )
                statusItemController.refreshPresentation()
                return nil
            }
        }
        statusItemController.refreshPresentation()

        do {
            guard let outputDirectory = AppSettings.outputDirectoryURL else {
                await discardSessionRecording()
                menuBarState.finishSaving(success: false)
                isSessionFinalizeInProgress = false
                statusItemController.refreshPresentation()
                _ = selectedOutputDirectoryOrNotify()
                return nil
            }

            let recordedSeconds = await sessionRecorder.recordedDurationSeconds()
            guard recordedSeconds >= SavePreflight.minimumBufferedSeconds else {
                await discardSessionRecording()
                menuBarState.finishSaving(success: false)
                isSessionFinalizeInProgress = false
                statusItemController.refreshPresentation()
                if userInitiated {
                    NotificationManager.shared.showOperationalNotification(
                        title: "Session Too Short",
                        body: "Wait a moment after starting before stopping so there is something to save."
                    )
                }
                return nil
            }

            let savedURL = try await sessionRecorder.saveEntireRecording(
                outputDirectory: outputDirectory,
                mergeAudioTracks: AppSettings.mergeAudioTracks,
                baseName: resolvedClipBaseName()
            )
            await sessionRecorder.configure(
                enabled: false,
                maxDurationSeconds: .infinity,
                outputDirectory: outputDirectory,
                storage: .session
            )

            menuBarState.finishSaving(success: true)
            statusItemController.setLastClip(savedURL)
            isSessionFinalizeInProgress = false
            statusItemController.refreshPresentation()

            if AppSettings.playAudioCueOnSave {
                AudioCue.playSaveSuccess()
            }
            if AppSettings.showNotificationOnSave || !userInitiated {
                NotificationManager.shared.showClipSavedNotification(
                    fileURL: savedURL,
                    clipDuration: recordedSeconds
                )
            }
            print("Session recording saved: \(savedURL.path)")
            return savedURL
        } catch LongBufferRecorderError.longBufferExportAlreadyInProgress {
            await discardSessionRecording()
            menuBarState.finishSaving(success: false)
            isSessionFinalizeInProgress = false
            statusItemController.refreshPresentation()
            NotificationManager.shared.showOperationalNotification(
                title: "Session Already Saving",
                body: "Wait for the current export to finish before stopping another session."
            )
            return nil
        } catch {
            await discardSessionRecording()
            menuBarState.finishSaving(success: false)
            isSessionFinalizeInProgress = false
            statusItemController.refreshPresentation()
            NotificationManager.shared.showSaveFailedNotification(error: error.localizedDescription)
            print("Failed to save session recording: \(error)")
            return nil
        }
    }

    func discardSessionRecording() async {
        isSessionRecording = false
        menuBarState.setSessionRecording(false)
        if let outputDirectory = AppSettings.outputDirectoryURL {
            await sessionRecorder.configure(
                enabled: false,
                maxDurationSeconds: .infinity,
                outputDirectory: outputDirectory,
                storage: .session
            )
        } else {
            await sessionRecorder.stop(deleteSegments: true)
        }
    }
}
