import Cocoa
import Branding
import CompanionServer
import UI
import Defaults

@MainActor
extension AppDelegate {
    func configureCompanionServer() {
        companionServer.onSaveReplay = { [weak self] in
            self?.saveClipFromUI()
        }
        companionServer.onSaveExtendedReplay = { [weak self] in
            self?.saveLongBufferFromUI()
        }
        companionServer.onToggleBuffer = { [weak self] in
            self?.toggleCapturePipeline()
        }
        companionServer.onToggleSession = { [weak self] in
            self?.toggleSessionRecording()
        }
        companionServer.onToggleMicrophone = { [weak self] in
            self?.toggleMicrophoneMuteFromUI()
        }
        companionServer.onToggleSystemAudio = { [weak self] in
            self?.toggleSystemAudioMuteFromUI()
        }
        companionServer.onRevealClip = { [weak self] clipId in
            guard let self,
                  let clip = self.mainWindowState.recentClips.first(where: {
                      $0.id.uuidString.caseInsensitiveCompare(clipId) == .orderedSame || $0.id.uuidString == clipId
                  }) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([clip.url])
        }
        companionServer.onDeleteClip = { [weak self] clipId in
            guard let self,
                  let clip = self.mainWindowState.recentClips.first(where: {
                      $0.id.uuidString.caseInsensitiveCompare(clipId) == .orderedSame || $0.id.uuidString == clipId
                  }),
                  !self.mainWindowState.isProtected(clip.url) else { return }
            try? FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
            self.mainWindowState.removeRecentClip(id: clip.id)
            self.broadcastCompanionSnapshot()
        }
        companionServer.onGetThumbnail = { [weak self] clipId in
            guard let self else { return nil }
            if let uuid = UUID(uuidString: clipId) {
                return await self.mainWindowState.thumbnailData(for: uuid)
            }
            if let clip = self.mainWindowState.recentClips.first(where: {
                $0.id.uuidString.caseInsensitiveCompare(clipId) == .orderedSame
            }) {
                return await self.mainWindowState.thumbnailData(for: clip.id)
            }
            return nil
        }
        companionServer.snapshotProvider = { [weak self] in
            self?.buildCompanionStateSnapshot(type: "state_snapshot") ?? CompanionStateSnapshot.empty
        }

        mainWindowState.onRecentClipsUpdated = { [weak self] in
            self?.broadcastCompanionSnapshot()
        }

        menuBarState.onSaveStatusChanged = { [weak self] in
            self?.broadcastCompanionSnapshot()
        }

        // Broadcast once the desktop's own state has settled, so the phone
        // never sees capture running before the buffer and display are set.
        menuBarState.onDisplayedStateChanged = { [weak self] in
            self?.broadcastCompanionSnapshot()
        }

        if AppSettings.companionServerEnabled {
            do {
                try companionServer.start(port: UInt16(AppSettings.companionServerPort))
            } catch {
                print("Failed to start companion server: \(error)")
            }
        }
    }

    func buildCompanionStateSnapshot(type: String = "state_snapshot") -> CompanionStateSnapshot {
        let clips = mainWindowState.recentClips.map { clip in
            CompanionClipSummary(
                id: clip.id.uuidString,
                filename: clip.url.lastPathComponent,
                kind: clip.kind.title.lowercased(),
                savedAt: clip.savedAt.timeIntervalSince1970,
                duration: clip.duration,
                fileSize: clip.fileSize,
                hasThumbnail: clip.thumbnail != nil
            )
        }

        return CompanionStateSnapshot(
            type: type,
            // The replay buffer, as the desktop shows it. Capture also runs for a
            // session alone, and that must not read as the buffer running.
            isRecording: menuBarState.isRecording,
            isSessionRecording: menuBarState.isSessionRecording,
            saveStatus: menuBarState.saveStatusString,
            recordingElapsedSeconds: menuBarState.recordingElapsedSeconds,
            extendedBufferElapsedSeconds: menuBarState.extendedBufferElapsedSeconds,
            sessionElapsedSeconds: menuBarState.sessionElapsedSeconds,
            bufferedSeconds: menuBarState.bufferedSeconds,
            bufferDurationSeconds: AppSettings.bufferDurationSeconds,
            bufferMemoryBytes: menuBarState.bufferMemoryBytes,
            bufferMemoryFormatted: menuBarState.formattedBufferMemory,
            longBufferEnabled: AppSettings.longBufferEnabled,
            longBufferDurationSeconds: AppSettings.longBufferDurationSeconds,
            capturedDisplayName: menuBarState.capturedDisplayName,
            isUsingFallbackDisplay: menuBarState.isUsingFallbackDisplay,
            isMicrophoneEnabled: AppSettings.captureMicrophone,
            isMicrophoneMuted: menuBarState.isMicrophoneMuted,
            isSystemAudioEnabled: AppSettings.captureSystemAudio,
            isSystemAudioMuted: menuBarState.isSystemAudioMuted,
            recentClips: clips
        )
    }

    func broadcastCompanionSnapshot(isStateChange: Bool = true) {
        guard companionServer.isRunning else { return }
        let snapshot = buildCompanionStateSnapshot(type: isStateChange ? "state_changed" : "state_snapshot")
        if isStateChange {
            companionServer.broadcastStateChanged(snapshot)
        } else {
            companionServer.broadcastSnapshot(snapshot)
        }
    }
}
