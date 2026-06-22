import Foundation
import Save
import UI
import Feedback

@MainActor
extension AppDelegate {
    func saveClipFromUI() {
        saveClip(lastSeconds: TimeInterval(AppSettings.bufferDurationSeconds))
    }

    func saveLongBufferFromUI() {
        saveLongBuffer(lastSeconds: TimeInterval(AppSettings.longBufferDurationSeconds))
    }

    func saveClip(lastSeconds: TimeInterval) {
        Task {
            await saveConfiguredClip(lastSeconds: lastSeconds)
        }
    }

    func currentBufferedVideoSeconds() -> TimeInterval {
        SavePreflight.bufferedSeconds(
            primaryVideo: videoRingBuffer.duration,
            dualDisplay1: dualDisplay1VideoRingBuffer.duration,
            dualDisplay2: dualDisplay2VideoRingBuffer.duration,
            isSeparateDualSave: isSeparateDualSaveMode
        )
    }

    var isSeparateDualSaveMode: Bool {
        AppSettings.captureMode == CaptureMode.dualSideBySide.rawValue
            && AppSettings.dualCaptureSaveMode == DualCaptureSaveMode.separateFiles.rawValue
    }

    func saveLongBuffer(lastSeconds: TimeInterval) {
        Task {
            await saveConfiguredLongBufferClip(lastSeconds: lastSeconds)
        }
    }

    func saveConfiguredClip(lastSeconds: TimeInterval) async {
        if let failure = SavePreflight.failure(
            isRecording: isCaptureRunning,
            bufferedSeconds: currentBufferedVideoSeconds(),
            saveInProgress: menuBarState.isSaveInProgress
        ) {
            if failure != .saveInProgress {
                let message = SavePreflight.notificationMessage(for: failure)
                NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
                menuBarState.showSaveFailedBriefly()
            }
            return
        }

        guard menuBarState.beginSaving() else {
            return
        }
        statusItemController.refreshPresentation()

        do {
            let outputDirectory = AppSettings.outputDirectoryURL
            print("Saving clip to output directory: \(outputDirectory.path(percentEncoded: false))")

            let finalURLs: [URL]
            if isSeparateDualSaveMode {
                finalURLs = try await clipSaver.saveDualDisplayClips(
                    lastSeconds: lastSeconds,
                    outputDirectory: outputDirectory,
                    mergeAudioTracks: AppSettings.mergeAudioTracks
                )
            } else {
                let savedURL = try await clipSaver.saveClip(
                    lastSeconds: lastSeconds,
                    outputDirectory: outputDirectory,
                    mergeAudioTracks: AppSettings.mergeAudioTracks
                )
                finalURLs = [savedURL]
            }

            menuBarState.finishSaving(success: true)
            statusItemController.setLastClip(finalURLs.first)
            statusItemController.refreshPresentation()

            if AppSettings.playAudioCueOnSave {
                AudioCue.playSaveSuccess()
            }

            if AppSettings.showNotificationOnSave {
                NotificationManager.shared.showClipSavedNotification(fileURL: finalURLs[0], clipDuration: lastSeconds)
            }
            print("Clip saved: \(finalURLs.map(\.path).joined(separator: ", "))")
        } catch {
            menuBarState.finishSaving(success: false)
            statusItemController.refreshPresentation()
            NotificationManager.shared.showSaveFailedNotification(error: error.localizedDescription)
            print("Failed to save clip: \(error)")
        }
    }

    func saveConfiguredLongBufferClip(lastSeconds: TimeInterval) async {
        guard AppSettings.longBufferEnabled else {
            NotificationManager.shared.showOperationalNotification(
                title: "Long Buffer Disabled",
                body: "Enable Extended replay buffer in Settings > Video before saving a long clip."
            )
            return
        }

        guard isCaptureRunning else {
            let message = SavePreflight.notificationMessage(for: .notRecording)
            NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            menuBarState.showSaveFailedBriefly()
            return
        }

        guard menuBarState.beginSaving() else {
            return
        }
        statusItemController.refreshPresentation()

        do {
            let savedURL = try await longBufferRecorder.saveClip(
                lastSeconds: lastSeconds,
                outputDirectory: AppSettings.outputDirectoryURL,
                mergeAudioTracks: AppSettings.mergeAudioTracks
            )

            menuBarState.finishSaving(success: true)
            statusItemController.setLastClip(savedURL)
            statusItemController.refreshPresentation()

            if AppSettings.playAudioCueOnSave {
                AudioCue.playSaveSuccess()
            }

            if AppSettings.showNotificationOnSave {
                NotificationManager.shared.showClipSavedNotification(fileURL: savedURL, clipDuration: lastSeconds)
            }
            print("Long-buffer clip saved: \(savedURL.path)")
        } catch {
            menuBarState.finishSaving(success: false)
            statusItemController.refreshPresentation()
            NotificationManager.shared.showSaveFailedNotification(error: error.localizedDescription)
            print("Failed to save long-buffer clip: \(error)")
        }
    }

}
