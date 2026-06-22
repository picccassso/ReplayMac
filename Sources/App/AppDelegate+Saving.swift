import Foundation
import AppKit
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

        if let diskFailure = diskSpaceFailure(
            lastSeconds: lastSeconds,
            streamCount: isSeparateDualSaveMode ? 2 : 1
        ) {
            let message = SavePreflight.notificationMessage(for: diskFailure)
            NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            menuBarState.showSaveFailedBriefly()
            return
        }

        guard menuBarState.beginSaving() else {
            return
        }
        statusItemController.refreshPresentation()

        do {
            let outputDirectory = AppSettings.outputDirectoryURL
            print("Saving clip to output directory: \(outputDirectory.path(percentEncoded: false))")

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

        if let diskFailure = diskSpaceFailure(lastSeconds: lastSeconds, streamCount: 1) {
            let message = SavePreflight.notificationMessage(for: diskFailure)
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
                mergeAudioTracks: AppSettings.mergeAudioTracks,
                baseName: resolvedClipBaseName()
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
            appName: currentForegroundAppName()
        )
    }

    private func currentForegroundAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        // Don't name clips after ReplayMac itself when it happens to be frontmost.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return nil
        }
        return app.localizedName
    }

    private func availableDiskCapacityBytes() -> Int64? {
        // Probe the output directory if it exists, otherwise the home directory
        // (same volume), since the output folder is created lazily on first save.
        let outputURL = AppSettings.outputDirectoryURL
        let probeURL = FileManager.default.fileExists(atPath: outputURL.path)
            ? outputURL
            : FileManager.default.homeDirectoryForCurrentUser

        let values = try? probeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

}
