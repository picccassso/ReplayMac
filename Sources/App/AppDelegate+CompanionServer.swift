import Cocoa
import Combine
import Audio
import Branding
import Capture
import CompanionServer
import Save
import UI
import Defaults
import os

private let companionLogger = Logger(subsystem: "com.replaycap", category: "CompanionServer")

@MainActor
extension AppDelegate {
    func configureCompanionServer() {
        companionServer.onSaveReplay = { [weak self] in
            self?.saveClipFromUI()
        }
        companionServer.onSaveExtendedReplay = { [weak self] in
            self?.saveLongBufferFromUI()
        }
        companionServer.onSaveReplayDuration = { [weak self] seconds in
            guard seconds > 0 else { return }
            self?.saveClip(lastSeconds: TimeInterval(seconds))
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
        companionServer.onToggleCamera = { [weak self] in
            guard AppSettings.isFeatureEnabled(.cameraOverlay) else { return }
            self?.toggleCameraOverlayFromUI()
        }
        companionServer.onToggleCursor = { [weak self] in
            Defaults[.showCursorInRecording].toggle()
            self?.broadcastCompanionSnapshot()
        }
        companionServer.onToggleAutoRecordGames = { [weak self] in
            guard AppSettings.isFeatureEnabled(.autoRecordGames) else { return }
            Defaults[.autoRecordGamesEnabled].toggle()
            self?.broadcastCompanionSnapshot()
        }
        companionServer.onRevealClip = { [weak self] clipId in
            guard let self,
                  let clip = self.mainWindowState.recentClip(matchingId: clipId) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([clip.url])
        }
        companionServer.onDeleteClip = { [weak self] clipId in
            guard let self else { return }
            guard let clip = self.mainWindowState.recentClip(matchingId: clipId) else {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Delete Failed",
                    message: "That clip is no longer in the recent clips list."
                )
                return
            }
            guard !self.mainWindowState.isProtected(clip.url) else {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Clip In Use",
                    message: "Close the clip editor or wait for the export to finish before deleting."
                )
                return
            }
            do {
                try FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
            } catch {
                // Leave the clip listed; dropping it would claim a delete that didn't happen.
                companionLogger.error("Failed to trash clip from companion: \(String(describing: error), privacy: .public)")
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Delete Failed",
                    message: error.localizedDescription
                )
                return
            }
            self.mainWindowState.removeRecentClip(id: clip.id)
            self.broadcastCompanionSnapshot()
        }
        companionServer.onTrimClip = { [weak self] clipId in
            guard let self else { return }
            guard let clip = self.mainWindowState.recentClip(matchingId: clipId),
                  FileManager.default.fileExists(atPath: clip.url.path) else {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Clip Unavailable",
                    message: "The clip file could not be found on disk."
                )
                return
            }
            self.openClipEditor(clip.url)
        }
        companionServer.onCopyClip = { [weak self] clipId in
            guard let self else { return }
            guard let clip = self.mainWindowState.recentClip(matchingId: clipId),
                  FileManager.default.fileExists(atPath: clip.url.path) else {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Copy Failed",
                    message: "The clip file could not be found on disk."
                )
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !pasteboard.writeObjects([clip.url as NSURL]) {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Copy Failed",
                    message: "macOS couldn't place the clip on the clipboard."
                )
            }
        }
        companionServer.onToggleClipFavorite = { [weak self] clipId in
            guard let self else { return }
            guard let clip = self.mainWindowState.recentClip(matchingId: clipId) else {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Update Failed",
                    message: "That clip is no longer in the recent clips list."
                )
                return
            }
            if case .failure(let error) = self.mainWindowState.toggleRecentClipFavorite(id: clip.id) {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Update Failed",
                    message: error.localizedDescription
                )
            }
        }
        companionServer.onUpdateClipMetadata = { [weak self] clipId, isFavorite, tags, note in
            guard let self else { return }
            guard let clip = self.mainWindowState.recentClip(matchingId: clipId) else {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Update Failed",
                    message: "That clip is no longer in the recent clips list."
                )
                return
            }
            if case .failure(let error) = self.mainWindowState.updateRecentClipMetadata(
                id: clip.id,
                isFavorite: isFavorite,
                tags: tags,
                note: note
            ) {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Update Failed",
                    message: error.localizedDescription
                )
            }
        }
        companionServer.onRenameClip = { [weak self] clipId, newName in
            guard let self else { return }
            guard let clip = self.mainWindowState.recentClip(matchingId: clipId) else {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Rename Failed",
                    message: "That clip is no longer in the recent clips list."
                )
                return
            }
            if case .failure(let error) = self.mainWindowState.renameRecentClip(id: clip.id, newName: newName) {
                self.companionServer.broadcastActionFeedback(
                    kind: .error,
                    title: "Rename Failed",
                    message: error.localizedDescription
                )
            }
        }
        companionServer.onSetCameraLayout = { [weak self] position, size in
            guard let self else { return }
            if let position, let parsed = Self.cameraPosition(fromWire: position) {
                Defaults[.cameraPosition] = parsed.rawValue
            }
            if let size, let parsed = CameraOverlaySize(rawValue: size) {
                Defaults[.cameraSize] = parsed.rawValue
            }
            if self.isCaptureRunning {
                self.frameCompositor.setCameraOverlay(AppSettings.cameraOverlayEnabled ? AppSettings.cameraOverlayLayout : nil)
            }
            self.broadcastCompanionSnapshot()
        }
        companionServer.onPushToMute = { [weak self] active in
            self?.setPushToMuteMicrophone(active)
        }
        companionServer.onResolveClipMediaURL = { [weak self] clipId in
            self?.mainWindowState.recentClip(matchingId: clipId)?.url
        }
        companionServer.onSetVolume = { [weak self] target, volume in
            switch target {
            case "microphone", "mic":
                AppSettings.setMicrophoneVolume(volume)
            case "systemAudio", "system_audio", "system":
                AppSettings.setSystemAudioVolume(volume)
            default:
                break
            }
            self?.applyEffectiveAudioVolumes()
            self?.scheduleCompanionVolumeSnapshotBroadcast()
        }
        companionServer.onToggleAppMute = { [weak self] bundleId in
            AppSettings.toggleAudioAppMute(bundleId)
            self?.broadcastCompanionSnapshot()
        }
        companionServer.onUnmuteAllApps = { [weak self] in
            AppSettings.unmuteAllAudioApps()
            self?.broadcastCompanionSnapshot()
        }
        companionServer.onSelectDisplay = { [weak self] displayId in
            AppSettings.selectPrimaryDisplay(displayId)
            self?.broadcastCompanionSnapshot()
        }
        companionServer.onApplyProfile = { [weak self] profileId in
            if AppSettings.applyCaptureProfile(id: profileId) {
                self?.broadcastCompanionSnapshot()
            }
        }
        companionServer.onGetThumbnail = { [weak self] clipId in
            guard let self else { return nil }
            if let uuid = UUID(uuidString: clipId) {
                return await self.mainWindowState.thumbnailData(for: uuid)
            }
            if let clip = self.mainWindowState.recentClip(matchingId: clipId) {
                return await self.mainWindowState.thumbnailData(for: clip.id)
            }
            return nil
        }
        companionServer.audioLevelProvider = {
            let snapshot = AudioLevelMonitor.shared.snapshot()
            return (microphone: snapshot.microphone, systemAudio: snapshot.systemAudio)
        }
        companionServer.onAudioLevelSubscriptionChanged = { [weak self] subscribed in
            self?.refreshCompanionAudioLevelPreview(subscribed: subscribed)
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

        observeThemeForCompanion()

        if AppSettings.companionServerEnabled {
            do {
                try companionServer.start(port: UInt16(AppSettings.companionServerPort))
            } catch {
                companionLogger.error("Failed to start companion server: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func refreshCompanionAudioLevelPreview(subscribed: Bool? = nil) {
        let isSubscribed = subscribed ?? companionServer.hasAudioLevelSubscribers
        guard isSubscribed else {
            AudioLevelPreview.shared.setCompanionConfiguration(nil)
            return
        }
        let perAppBundleID = AppSettings.perAppAudioEnabled ? Defaults[.perAppAudioBundleID] : ""
        AudioLevelPreview.shared.setCompanionConfiguration(
            AudioLevelPreview.Configuration(
                monitorSystemAudio: AppSettings.captureSystemAudio,
                monitorMicrophone: AppSettings.captureMicrophone,
                microphoneDeviceID: Defaults[.microphoneID],
                perAppAudioBundleID: !perAppBundleID.isEmpty ? perAppBundleID : nil,
                excludedAudioBundleIDs: !AppSettings.perAppAudioEnabled ? AppSettings.mutedAudioAppBundleIDs : [],
                excludeOwnAppAudio: Defaults[.excludeOwnAppAudio],
                systemAudioVolume: AppSettings.effectiveSystemAudioVolume(),
                microphoneVolume: AppSettings.effectiveMicrophoneVolume(isPushToMuteActive: isPushToMuteActive)
            )
        )
    }

    func scheduleCompanionVolumeSnapshotBroadcast() {
        companionVolumeBroadcastTask?.cancel()
        companionVolumeBroadcastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.companionVolumeBroadcastTask = nil
            self?.broadcastCompanionSnapshot()
        }
    }

    func buildCompanionStateSnapshot(type: String = "state_snapshot") -> CompanionStateSnapshot {
        let recent = mainWindowState.recentClips
        let metadataMap = mainWindowState.clipMetadataMap(for: recent)
        let clips = recent.map { clip in
            let meta = metadataMap[ClipLibraryMetadataStore.key(for: clip.url)] ?? .empty
            return CompanionClipSummary(
                id: clip.id.uuidString,
                filename: clip.url.lastPathComponent,
                kind: clip.kind.title.lowercased(),
                savedAt: clip.savedAt.timeIntervalSince1970,
                duration: clip.duration,
                fileSize: clip.fileSize,
                hasThumbnail: clip.thumbnail != nil,
                isFavorite: meta.isFavorite,
                tags: meta.tags,
                note: meta.notes
            )
        }

        let runningApps = AppSettings.capturableRunningApplications()
        var audioApps = runningApps.map { app in
            CompanionAudioApp(
                bundleId: app.bundleID,
                name: app.name,
                isMuted: AppSettings.isAppAudioMuted(app.bundleID),
                isRunning: true,
                iconBase64: AppSettings.appIconBase64(for: app.bundleID)
            )
        }
        let runningLower = Set(runningApps.map { $0.bundleID.lowercased() })
        for mutedBundleId in AppSettings.mutedAudioAppBundleIDs where !runningLower.contains(mutedBundleId.lowercased()) {
            audioApps.append(
                CompanionAudioApp(
                    bundleId: mutedBundleId,
                    name: AppSettings.appDisplayName(for: mutedBundleId),
                    isMuted: true,
                    isRunning: false,
                    iconBase64: AppSettings.appIconBase64(for: mutedBundleId)
                )
            )
        }

        let onlineIDs = DisplayIdentity.onlineDisplayIDs()
        let priorities = AppSettings.captureDisplayPriorities
        let resolvedDisplayID = DisplayIdentity.resolveFirst(in: priorities, among: onlineIDs) ?? onlineIDs.first
        let displays = onlineIDs.map { displayID in
            CompanionDisplayInfo(
                id: DisplayIdentity.stableKey(for: displayID),
                name: DisplayIdentity.localizedDisplayName(for: displayID),
                isActive: displayID == resolvedDisplayID,
                isConnected: true
            )
        }

        let profiles = AppSettings.loadCaptureProfiles().map { profile in
            CompanionProfileSummary(
                id: profile.id.uuidString,
                name: profile.name,
                summary: profile.summary,
                isActive: AppSettings.isCaptureProfileActive(profile)
            )
        }

        let activeGameName: String? = AppSettings.autoRecordGamesEnabled
            ? (recordingAutoStartedByGame ? gameActivityMonitor.activeGameName : nil)
            : nil

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
            // Phones that predate the boost draw a 0-100% slider, so they
            // get the level capped there and newer ones read the gain.
            microphoneVolume: min(AppSettings.microphoneVolume, 1.0),
            systemAudioVolume: AppSettings.systemAudioVolume,
            microphoneGain: AppSettings.microphoneVolume,
            microphoneGainMax: AppSettings.maximumMicrophoneVolume,
            perAppAudioEnabled: AppSettings.perAppAudioEnabled,
            isCameraOverlayEnabled: AppSettings.cameraOverlayEnabled,
            isCameraOverlayAvailable: AppSettings.isFeatureEnabled(.cameraOverlay),
            isExtendedReplayAvailable: AppSettings.isFeatureEnabled(.extendedReplay) && AppSettings.longBufferEnabled,
            isSessionRecordingAvailable: AppSettings.isFeatureEnabled(.sessionRecording) || menuBarState.isSessionRecording,
            isAudioMixingAvailable: AppSettings.isFeatureEnabled(.audioMixing),
            isQuickSavePresetsAvailable: AppSettings.isFeatureEnabled(.quickSaveAndThumbnail),
            isCaptureProfilesAvailable: AppSettings.isFeatureEnabled(.captureProfiles),
            isAutoRecordGamesAvailable: AppSettings.isFeatureEnabled(.autoRecordGames),
            autoRecordGamesEnabled: AppSettings.autoRecordGamesEnabled,
            activeGameName: activeGameName,
            showCursorInRecordings: AppSettings.showCursorInRecording,
            cameraOverlayPosition: Self.wirePosition(from: AppSettings.cameraPositionEnum),
            cameraOverlaySize: AppSettings.cameraSizeEnum.rawValue,
            warnings: activeCompanionWarnings(),
            audioApps: audioApps,
            displays: displays,
            profiles: profiles,
            recentClips: clips,
            theme: CompanionThemeBuilder.current()
        )
    }

    private func activeCompanionWarnings() -> [String] {
        var warnings: [String] = []
        if memoryPressureLevel == .critical {
            let configured = AppSettings.bufferDurationSeconds
            let effective = MemoryPressurePolicy.replaySeconds(configured: configured, level: .critical)
            if effective < configured {
                warnings.append("Critical memory pressure: buffer shortened to \(effective)s")
            } else {
                warnings.append("Critical memory pressure")
            }
        }
        if let outputURL = AppSettings.outputDirectoryURL,
           let volumeName = SavePreflight.unmountedExternalVolumeName(for: outputURL) {
            warnings.append("Output drive \"\(volumeName)\" is disconnected")
        }
        if isCaptureRunning && hasWarnedSystemAudioStalled {
            warnings.append("System audio stalled")
        }
        if isCaptureRunning && micAudioCapture.isStalled {
            warnings.append("Microphone stalled")
        }
        return warnings
    }

    private static func wirePosition(from position: CameraOverlayPosition) -> String {
        switch position {
        case .topLeft: return "topLeft"
        case .topRight: return "topRight"
        case .bottomLeft: return "bottomLeft"
        case .bottomRight: return "bottomRight"
        }
    }

    private static func cameraPosition(fromWire value: String) -> CameraOverlayPosition? {
        switch value {
        case "topLeft", "top_left": return .topLeft
        case "topRight", "top_right": return .topRight
        case "bottomLeft", "bottom_left": return .bottomLeft
        case "bottomRight", "bottom_right": return .bottomRight
        default: return nil
        }
    }

    /// Re-sends state when Appearance settings or the macOS accent change, so
    /// the phone recolours live. Debounced so dragging a colour picker doesn't
    /// flood phones with a snapshot per tick.
    private func observeThemeForCompanion() {
        let themeChanged = ThemeController.shared.$revision.dropFirst().map { _ in () }
        let systemAccentChanged = NotificationCenter.default
            .publisher(for: NSColor.systemColorsDidChangeNotification)
            .map { _ in () }
        companionThemeSubscription = themeChanged.merge(with: systemAccentChanged)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.broadcastCompanionSnapshot()
            }
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
