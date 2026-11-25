import Foundation
import AppKit
import os
import Save
import UI
import Feedback
import CompanionServer

private let clipSaveLogger = Logger(subsystem: "com.replaycap", category: "ClipSave")

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
            saveInProgress: menuBarState.isSaveInProgress,
            replayBufferEnabled: replayBufferGate.isEnabled
        ) {
            let message = SavePreflight.notificationMessage(for: failure)
            if failure != .saveInProgress {
                NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
                if failure == .notRecording || failure == .replayBufferUnavailable {
                    menuBarState.showBufferNotRunningBriefly()
                } else {
                    menuBarState.showSaveFailedBriefly()
                }
            }
            companionServer.broadcastActionFeedback(
                kind: failure == .saveInProgress ? .info : .error,
                title: message.title,
                message: message.body
            )
            return
        }

        guard let outputDirectory = selectedOutputDirectoryOrNotify() else {
            menuBarState.showSaveFailedBriefly()
            return
        }

        if let diskFailure = diskSpaceFailure(
            lastSeconds: lastSeconds,
            streamCount: isSeparateDualSaveMode ? 2 : 1
        ) {
            let message = SavePreflight.notificationMessage(for: diskFailure)
            NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            companionServer.broadcastActionFeedback(kind: .error, title: message.title, message: message.body)
            menuBarState.showSaveFailedBriefly()
            return
        }

        guard menuBarState.beginSaving() else {
            return
        }
        statusItemController.refreshPresentation()
        broadcastCompanionSnapshot()

        do {
            clipSaveLogger.info("Saving clip to output directory: \(outputDirectory.path(percentEncoded: false))")

            let baseName = resolvedClipBaseName()
            let finalURLs: [URL]
            if isSeparateDualSaveMode {
                finalURLs = try await clipSaver.saveDualDisplayClips(
                    lastSeconds: lastSeconds,
                    outputDirectory: outputDirectory,
                    mergeAudioTracks: AppSettings.mergeAudioTracks,
                    baseName: baseName
                )
            } else {
                let savedURL = try await clipSaver.saveClip(
                    lastSeconds: lastSeconds,
                    outputDirectory: outputDirectory,
                    mergeAudioTracks: AppSettings.mergeAudioTracks,
                    baseName: baseName
                )
                finalURLs = [savedURL]
            }

            menuBarState.finishSaving(success: true)
            statusItemController.setLastClip(finalURLs.first)
            mainWindowState.recordSavedClips(finalURLs, kind: .replay)
            statusItemController.refreshPresentation()
            if AppSettings.showClipThumbnailAfterSave {
                clipThumbnailController.show(url: finalURLs[0])
            }

            if AppSettings.playAudioCueOnSave {
                AudioCue.playSaveSuccess()
            }

            if AppSettings.showNotificationOnSave {
                NotificationManager.shared.showClipSavedNotification(fileURL: finalURLs[0], clipDuration: lastSeconds)
            }
            clipSaveLogger.info("Clip saved: \(finalURLs.map(\.path).joined(separator: ", "))")
        } catch {
            menuBarState.finishSaving(success: false)
            statusItemController.refreshPresentation()
            NotificationManager.shared.showSaveFailedNotification(error: error.localizedDescription)
            companionServer.broadcastActionFeedback(
                kind: .error,
                title: "Save Failed",
                message: error.localizedDescription
            )
            clipSaveLogger.error("Failed to save clip: \(String(describing: error), privacy: .public)")
        }
    }

    func saveConfiguredLongBufferClip(lastSeconds: TimeInterval) async {
        guard AppSettings.longBufferEnabled else {
            let title = "Long Buffer Disabled"
            let body = "Enable Extended replay buffer in Settings > Video before saving a long clip."
            NotificationManager.shared.showOperationalNotification(title: title, body: body)
            companionServer.broadcastActionFeedback(kind: .error, title: title, message: body)
            return
        }

        guard isCaptureRunning else {
            let message = SavePreflight.notificationMessage(for: .notRecording)
            NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            companionServer.broadcastActionFeedback(kind: .error, title: message.title, message: message.body)
            menuBarState.showBufferNotRunningBriefly()
            return
        }

        guard replayBufferGate.isEnabled else {
            let message = SavePreflight.notificationMessage(for: .replayBufferUnavailable)
            NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            companionServer.broadcastActionFeedback(kind: .error, title: message.title, message: message.body)
            menuBarState.showBufferNotRunningBriefly()
            return
        }

        guard let outputDirectory = selectedOutputDirectoryOrNotify() else {
            menuBarState.showSaveFailedBriefly()
            return
        }

        // Extended saves temporarily stage one copy of the selected segments
        // alongside the final exported clip, so reserve space for both.
        if let diskFailure = diskSpaceFailure(lastSeconds: lastSeconds, streamCount: 2) {
            let message = SavePreflight.notificationMessage(for: diskFailure)
            NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            companionServer.broadcastActionFeedback(kind: .error, title: message.title, message: message.body)
            menuBarState.showSaveFailedBriefly()
            return
        }

        guard menuBarState.beginSaving() else {
            return
        }
        statusItemController.refreshPresentation()
        broadcastCompanionSnapshot()

        do {
            let savedURL = try await longBufferRecorder.saveClip(
                lastSeconds: lastSeconds,
                outputDirectory: outputDirectory,
                mergeAudioTracks: AppSettings.mergeAudioTracks,
                baseName: resolvedClipBaseName()
            )

            menuBarState.finishSaving(success: true)
            statusItemController.setLastClip(savedURL)
            mainWindowState.recordSavedClips([savedURL], kind: .extendedReplay)
            statusItemController.refreshPresentation()

            if AppSettings.playAudioCueOnSave {
                AudioCue.playSaveSuccess()
            }

            if AppSettings.showNotificationOnSave {
                NotificationManager.shared.showClipSavedNotification(fileURL: savedURL, clipDuration: lastSeconds)
            }
            clipSaveLogger.info("Long-buffer clip saved: \(savedURL.path)")
        } catch LongBufferRecorderError.longBufferExportAlreadyInProgress {
            menuBarState.finishSaving(success: false)
            statusItemController.refreshPresentation()
            let title = "Long Replay Already Saving"
            let body = "A long replay is already saving. Wait for it to finish before saving another."
            NotificationManager.shared.showOperationalNotification(title: title, body: body)
            companionServer.broadcastActionFeedback(kind: .info, title: title, message: body)
        } catch {
            menuBarState.finishSaving(success: false)
            statusItemController.refreshPresentation()
            NotificationManager.shared.showSaveFailedNotification(error: error.localizedDescription)
            companionServer.broadcastActionFeedback(
                kind: .error,
                title: "Extended Save Failed",
                message: error.localizedDescription
            )
            clipSaveLogger.error("Failed to save long-buffer clip: \(String(describing: error), privacy: .public)")
        }
    }

    /// Estimates the clip size from the configured bitrate and checks it against
    /// free space on the output volume. Returns `nil` (allow the save) when
    /// capacity can't be determined, so this never blocks on a query failure.
    func diskSpaceFailure(lastSeconds: TimeInterval, streamCount: Int) -> SavePreflightFailure? {
        guard let available = availableDiskCapacityBytes() else {
            return nil
        }
        let estimate = SavePreflight.estimatedClipBytes(
            bitrateMbps: AppSettings.bitrateMbps,
            durationSeconds: lastSeconds,
            streamCount: streamCount
        )
        return SavePreflight.diskFailure(
            estimatedClipBytes: estimate,
            availableCapacityBytes: available
        )
    }

    /// Resolves the configured file-name template using the app that was
    /// frontmost when the save was triggered (typically the game being clipped).
    func resolvedClipBaseName() -> String {
        FilenameTemplate.resolve(
            template: AppSettings.clipFilenameTemplate,
            appName: currentForegroundAppName(),
            dateFormat: AppSettings.clipDateFormat,
            timeFormat: AppSettings.clipTimeFormat
        )
    }

    private func currentForegroundAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        // Don't name clips after ReplayCap itself when it happens to be frontmost.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return nil
        }
        return app.localizedName
    }

    private func availableDiskCapacityBytes() -> Int64? {
        guard let outputURL = AppSettings.outputDirectoryURL else {
            return nil
        }
        return SavePreflight.availableCapacityBytes(for: outputURL)
    }

    func selectedOutputDirectoryOrNotify() -> URL? {
        OutputDirectoryAccess.ensureAccessIfNeeded()
        guard let outputDirectory = AppSettings.outputDirectoryURL else {
            let title = "Choose an Output Folder"
            let body = "Open Settings and choose the folder where clips should be saved."
            NotificationManager.shared.showOperationalNotification(title: title, body: body)
            companionServer.broadcastActionFeedback(kind: .error, title: title, message: body)
            return nil
        }
        if let volumeName = SavePreflight.unmountedExternalVolumeName(for: outputDirectory) {
            let title = "Output Drive Disconnected"
            let body = "Connect “\(volumeName)” or choose a different output folder in Settings."
            NotificationManager.shared.showOperationalNotification(title: title, body: body)
            companionServer.broadcastActionFeedback(kind: .error, title: title, message: body)
            return nil
        }
        return outputDirectory
    }

}
