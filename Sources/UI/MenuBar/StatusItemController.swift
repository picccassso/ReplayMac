import Branding
import Cocoa
import SwiftUI
import KeyboardShortcuts

@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<StatusBadgeView>?
    private var state = MenuBarState()
    private var saveItem: NSMenuItem?
    private var saveLongBufferItem: NSMenuItem?
    private var toggleSessionRecordingItem: NSMenuItem?
    private var toggleRecordingItem: NSMenuItem?
    private var toggleMicMuteItem: NSMenuItem?
    private var toggleSystemAudioMuteItem: NSMenuItem?
    private var muteAppsItem: NSMenuItem?
    private var muteAppsSubmenu: NSMenu?
    private var copyLastClipItem: NSMenuItem?
    private var revealLastClipItem: NSMenuItem?
    private var openLastClipItem: NSMenuItem?
    private var recordingDurationItem: NSMenuItem?
    private var sessionDurationItem: NSMenuItem?
    private var displayItem: NSMenuItem?
    private var bufferUsageItem: NSMenuItem?
    private var longBufferUsageItem: NSMenuItem?
    private var hotkeyHintItem: NSMenuItem?
    private var updateItem: NSMenuItem?

    private var lastClipURL: URL?

    public var onSaveClip: (() -> Void)?
    public var onSaveLongBuffer: (() -> Void)?
    public var onToggleSessionRecording: (() -> Void)?
    public var onToggleRecording: (() -> Void)?
    public var onToggleMicrophoneMute: (() -> Void)?
    public var onToggleSystemAudioMute: (() -> Void)?
    public var onCopyLastClip: (() -> Void)?
    public var onOpenMainWindow: (() -> Void)?
    public var onOpenClipLibrary: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenAudioSettings: (() -> Void)?
    public var onQuit: (() -> Void)?

    public override init() {
        super.init()
    }

    public func setup(state: MenuBarState) {
        self.state = state

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton(for: item)
        configureMenu(for: item)
        statusItem = item
        refreshPresentation()
    }

    public func refreshPresentation() {
        refreshMenuItems()
        updateTooltip()
    }

    /// Records the most recently saved clip so the menu can offer quick access
    /// to it. Pass `nil` to clear (e.g. when the file no longer exists).
    public func setLastClip(_ url: URL?) {
        lastClipURL = url
        refreshMenuItems()
    }

    /// Resolves the most recently saved clip (or the newest video file in the
    /// configured output directory) and writes it as a file object onto the
    /// general pasteboard so it can be pasted directly into apps like Discord or Messages.
    @discardableResult
    public func copyLastClipToPasteboard() -> URL? {
        guard let clipURL = resolveLastClipURL() else {
            return nil
        }
        Self.copyToPasteboard(clipURL)
        return clipURL
    }

    /// The most recently saved clip, falling back to the newest video file in
    /// the configured output directory when the recorded one no longer exists.
    public func resolveLastClipURL() -> URL? {
        if let url = lastClipURL, !FileManager.default.fileExists(atPath: url.path) {
            lastClipURL = nil
        }

        let resolvedURL = lastClipURL ?? Self.mostRecentSavedClipURL(in: AppSettings.outputDirectoryURL)
        guard let clipURL = resolvedURL else {
            return nil
        }

        if lastClipURL == nil {
            lastClipURL = clipURL
            refreshMenuItems()
        }
        return clipURL
    }

    /// Writes `url` as a file object so it pastes as the clip itself.
    public static func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    internal static func mostRecentSavedClipURL(in directoryURL: URL?) -> URL? {
        guard let directoryURL else { return nil }
        OutputDirectoryAccess.ensureAccessIfNeeded()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let supportedExtensions: Set<String> = ["mp4", "mov"]
        var newestURL: URL?
        var newestDate: Date = .distantPast

        for url in contents where supportedExtensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            let modified = values.contentModificationDate ?? .distantPast
            if modified >= newestDate {
                newestDate = modified
                newestURL = url
            }
        }
        return newestURL
    }

    private func configureButton(for item: NSStatusItem) {
        guard let button = item.button else {
            return
        }

        button.image = nil
        button.title = ""

        button.subviews.forEach { $0.removeFromSuperview() }

        let hostedView = NSHostingView(
            rootView: StatusBadgeView(state: state) { [weak self] width in
                self?.updateStatusItemWidth(width)
            }
        )
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hostedView)

        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: button.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])

        hostingView = hostedView
    }

    private func configureMenu(for item: NSStatusItem) {
        let menu = NSMenu()
        menu.delegate = self

        let saveItem = NSMenuItem(title: "", action: #selector(saveClip), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)

        let saveLongBufferItem = NSMenuItem(title: "", action: #selector(saveLongBuffer), keyEquivalent: "")
        saveLongBufferItem.target = self
        menu.addItem(saveLongBufferItem)

        let toggleSessionRecordingItem = NSMenuItem(title: "", action: #selector(toggleSessionRecording), keyEquivalent: "")
        toggleSessionRecordingItem.target = self
        menu.addItem(toggleSessionRecordingItem)

        let hotkeyHintItem = NSMenuItem(title: "No hotkey set — configure in Settings", action: nil, keyEquivalent: "")
        hotkeyHintItem.isEnabled = false
        menu.addItem(hotkeyHintItem)

        let toggleRecordingItem = NSMenuItem(title: "", action: #selector(toggleRecording), keyEquivalent: "")
        toggleRecordingItem.target = self
        menu.addItem(toggleRecordingItem)

        let toggleMicMuteItem = NSMenuItem(title: "", action: #selector(toggleMicrophoneMute), keyEquivalent: "")
        toggleMicMuteItem.target = self
        menu.addItem(toggleMicMuteItem)

        let toggleSystemAudioMuteItem = NSMenuItem(title: "", action: #selector(toggleSystemAudioMute), keyEquivalent: "")
        toggleSystemAudioMuteItem.target = self
        menu.addItem(toggleSystemAudioMuteItem)

        let muteAppsSubmenu = NSMenu()
        let muteAppsItem = NSMenuItem(title: "Mute App Audio", action: nil, keyEquivalent: "")
        muteAppsItem.submenu = muteAppsSubmenu
        menu.addItem(muteAppsItem)

        menu.addItem(NSMenuItem.separator())

        let openMainWindowItem = NSMenuItem(title: "Open \(AppBranding.name)", action: #selector(openMainWindow), keyEquivalent: "")
        openMainWindowItem.target = self
        openMainWindowItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Open \(AppBranding.name)")
        menu.addItem(openMainWindowItem)

        let libraryItem = NSMenuItem(title: "Clip Library", action: #selector(openClipLibrary), keyEquivalent: "")
        libraryItem.target = self
        libraryItem.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: "Clip Library")
        menu.addItem(libraryItem)

        let copyLastClipItem = NSMenuItem(title: "Copy Last Clip", action: #selector(copyLastClip), keyEquivalent: "")
        copyLastClipItem.target = self
        menu.addItem(copyLastClipItem)

        let openLastClipItem = NSMenuItem(title: "Open Last Clip", action: #selector(openLastClip), keyEquivalent: "")
        openLastClipItem.target = self
        menu.addItem(openLastClipItem)

        let revealLastClipItem = NSMenuItem(title: "Reveal Last Clip in Finder", action: #selector(revealLastClip), keyEquivalent: "")
        revealLastClipItem.target = self
        menu.addItem(revealLastClipItem)

        menu.addItem(NSMenuItem.separator())

        let recordingDurationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recordingDurationItem.isEnabled = false
        menu.addItem(recordingDurationItem)

        let sessionDurationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sessionDurationItem.isEnabled = false
        menu.addItem(sessionDurationItem)

        let displayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        displayItem.isEnabled = false
        menu.addItem(displayItem)

        let bufferUsageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        bufferUsageItem.isEnabled = false
        menu.addItem(bufferUsageItem)

        let longBufferUsageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        longBufferUsageItem.isEnabled = false
        menu.addItem(longBufferUsageItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: "", action: #selector(openAvailableUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Update available")
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit \(AppBranding.name)", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        self.saveItem = saveItem
        self.saveLongBufferItem = saveLongBufferItem
        self.toggleSessionRecordingItem = toggleSessionRecordingItem
        self.toggleRecordingItem = toggleRecordingItem
        self.toggleMicMuteItem = toggleMicMuteItem
        self.toggleSystemAudioMuteItem = toggleSystemAudioMuteItem
        self.muteAppsItem = muteAppsItem
        self.muteAppsSubmenu = muteAppsSubmenu
        self.copyLastClipItem = copyLastClipItem
        self.openLastClipItem = openLastClipItem
        self.revealLastClipItem = revealLastClipItem
        self.recordingDurationItem = recordingDurationItem
        self.sessionDurationItem = sessionDurationItem
        self.displayItem = displayItem
        self.bufferUsageItem = bufferUsageItem
        self.longBufferUsageItem = longBufferUsageItem
        self.hotkeyHintItem = hotkeyHintItem
        self.updateItem = updateItem
        refreshMenuItems()
        item.menu = menu
    }

    public func menuWillOpen(_ menu: NSMenu) {
        refreshPresentation()
    }

    private func refreshMenuItems() {
        let replaySeconds = AppSettings.bufferDurationSeconds
        saveItem?.title = ReplayControlLabels.saveReplay(seconds: replaySeconds).title
        saveItem?.isEnabled = SavePreflight.canSaveQuickReplay(
            isRecording: state.isRecording,
            bufferedSeconds: state.bufferedSeconds,
            saveInProgress: state.isSaveInProgress
        )

        let longBufferSeconds = AppSettings.longBufferDurationSeconds
        saveLongBufferItem?.title = ReplayControlLabels.saveExtendedReplay(seconds: longBufferSeconds).title
        saveLongBufferItem?.isHidden = !AppSettings.longBufferEnabled
        saveLongBufferItem?.isEnabled = SavePreflight.canSaveLongReplay(
            isRecording: state.isRecording,
            saveInProgress: state.isSaveInProgress
        )

        toggleSessionRecordingItem?.title = ReplayControlLabels.session(isRecording: state.isSessionRecording).title
        toggleSessionRecordingItem?.isEnabled = !state.isSaveInProgress
        toggleSessionRecordingItem?.isHidden = !AppSettings.isFeatureEnabled(.sessionRecording) && !state.isSessionRecording

        toggleRecordingItem?.title = ReplayControlLabels.replayBuffer(isRecording: state.isRecording).title

        let microphone = ReplayControlLabels.microphone(isEnabled: AppSettings.captureMicrophone,
                                                         isMuted: state.isMicrophoneMuted)
        toggleMicMuteItem?.title = microphone.title
        toggleMicMuteItem?.image = NSImage(systemSymbolName: microphone.symbol,
                                           accessibilityDescription: microphone.accessibilityDescription)

        let systemAudio = ReplayControlLabels.systemAudio(isEnabled: AppSettings.captureSystemAudio,
                                                           isMuted: state.isSystemAudioMuted)
        toggleSystemAudioMuteItem?.title = systemAudio.title
        toggleSystemAudioMuteItem?.image = NSImage(systemSymbolName: systemAudio.symbol,
                                                   accessibilityDescription: systemAudio.accessibilityDescription)

        muteAppsItem?.isHidden = !AppSettings.isFeatureEnabled(.audioMixing)
        if AppSettings.isFeatureEnabled(.audioMixing) {
            refreshMuteAppsSubmenu()
        }

        // Drop the reference if the clip has since been moved, renamed, or deleted.
        if let url = lastClipURL, !FileManager.default.fileExists(atPath: url.path) {
            lastClipURL = nil
        }
        let hasLastClip = lastClipURL != nil
        copyLastClipItem?.isHidden = !hasLastClip
        openLastClipItem?.isHidden = !hasLastClip
        revealLastClipItem?.isHidden = !hasLastClip

        recordingDurationItem?.title = "Recording: \(state.formattedRecordingDuration)"
        recordingDurationItem?.isHidden = !state.isRecording

        sessionDurationItem?.title = "Session: \(state.formattedSessionDuration)"
        sessionDurationItem?.isHidden = !state.isSessionRecording

        if let displayName = state.capturedDisplayName, (state.isRecording || state.isSessionRecording) {
            let fallbackSuffix = state.isUsingFallbackDisplay ? " (Fallback)" : ""
            displayItem?.title = "Display: \(displayName)\(fallbackSuffix)"
            displayItem?.isHidden = false
        } else {
            displayItem?.isHidden = true
        }

        bufferUsageItem?.title = ReplayControlLabels.quickReplayLine(
            bufferedSeconds: state.bufferedSeconds, capSeconds: replaySeconds,
            memory: state.formattedBufferMemory, isRecording: state.isRecording
        )
        let isSessionOnlyCapture = ReplayControlLabels.isSessionOnlyCapture(
            isRecording: state.isRecording, isSessionRecording: state.isSessionRecording
        )
        bufferUsageItem?.isHidden = isSessionOnlyCapture

        longBufferUsageItem?.title = ReplayControlLabels.extendedReplayLine(
            elapsedSeconds: state.extendedBufferElapsedSeconds, capSeconds: longBufferSeconds,
            isRecording: state.isRecording
        )
        longBufferUsageItem?.isHidden = !AppSettings.longBufferEnabled || isSessionOnlyCapture

        hotkeyHintItem?.isHidden = hasSaveHotkeyConfigured

        if let availableUpdate = state.availableUpdate {
            updateItem?.title = "Update Available: \(availableUpdate.version)"
            updateItem?.isHidden = false
        } else {
            updateItem?.isHidden = true
        }
    }

    private func refreshMuteAppsSubmenu() {
        guard let muteAppsItem, let submenu = muteAppsSubmenu else { return }
        submenu.removeAllItems()

        let canMuteApps = AppSettings.captureSystemAudio && !AppSettings.perAppAudioEnabled
        let mutedIDs = AppSettings.mutedAudioAppBundleIDs
        let effectiveMutedCount = canMuteApps ? mutedIDs.count : 0

        muteAppsItem.title = ReplayControlLabels.mutedAppsMenuTitle(mutedCount: effectiveMutedCount)
        let symbolName = effectiveMutedCount > 0 ? "speaker.slash.circle.fill" : "speaker.wave.2.bubble.fill"
        muteAppsItem.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Mute application audio")
            ?? NSImage(systemSymbolName: effectiveMutedCount > 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       accessibilityDescription: "Mute application audio")

        if !AppSettings.captureSystemAudio {
            let infoItem = NSMenuItem(title: "System audio capture is off", action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            submenu.addItem(infoItem)
        } else if AppSettings.perAppAudioEnabled {
            let infoItem = NSMenuItem(title: "Using Selected App Only mode", action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            submenu.addItem(infoItem)
        } else {
            let runningApps = AppSettings.capturableRunningApplications()
            if runningApps.isEmpty {
                let emptyItem = NSMenuItem(title: "No running applications", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                submenu.addItem(emptyItem)
            } else {
                let headerItem = NSMenuItem(title: "Checked apps are muted in recordings", action: nil, keyEquivalent: "")
                headerItem.isEnabled = false
                submenu.addItem(headerItem)

                for app in runningApps {
                    let isMuted = AppSettings.isAppAudioMuted(app.bundleID)
                    let item = NSMenuItem(
                        title: app.name,
                        action: #selector(toggleMutedAppFromMenu(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = app.bundleID
                    item.state = isMuted ? .on : .off
                    if let icon = AppSettings.appIcon(for: app.bundleID) {
                        let copy = (icon.copy() as? NSImage) ?? icon
                        copy.size = NSSize(width: 16, height: 16)
                        item.image = copy
                    }
                    submenu.addItem(item)
                }
            }

            let nonRunningMuted = mutedIDs.filter { !AppSettings.isApplicationRunning($0) }
            if !nonRunningMuted.isEmpty {
                submenu.addItem(NSMenuItem.separator())
                let header = NSMenuItem(title: "Muted (Not Running)", action: nil, keyEquivalent: "")
                header.isEnabled = false
                submenu.addItem(header)

                for bundleID in nonRunningMuted {
                    let item = NSMenuItem(
                        title: AppSettings.appDisplayName(for: bundleID),
                        action: #selector(toggleMutedAppFromMenu(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = bundleID
                    item.state = .on
                    submenu.addItem(item)
                }
            }

            if !mutedIDs.isEmpty {
                submenu.addItem(NSMenuItem.separator())
                let unmuteAllItem = NSMenuItem(
                    title: "Unmute All Applications",
                    action: #selector(unmuteAllAppsFromMenu),
                    keyEquivalent: ""
                )
                unmuteAllItem.target = self
                submenu.addItem(unmuteAllItem)
            }
        }

        submenu.addItem(NSMenuItem.separator())
        let audioSettingsItem = NSMenuItem(
            title: "Audio Settings…",
            action: #selector(openAudioSettings),
            keyEquivalent: ""
        )
        audioSettingsItem.target = self
        submenu.addItem(audioSettingsItem)
    }

    private func updateTooltip() {
        guard let button = statusItem?.button else { return }

        let displayDetail = state.capturedDisplayName.map { " (\($0))" } ?? ""
        var muteDetails: [String] = []
        if state.isMicrophoneMuted {
            muteDetails.append("Mic Muted")
        }
        if state.isSystemAudioMuted {
            muteDetails.append("System Audio Muted")
        } else if AppSettings.captureSystemAudio && !AppSettings.perAppAudioEnabled && !AppSettings.mutedAudioAppBundleIDs.isEmpty {
            let count = AppSettings.mutedAudioAppBundleIDs.count
            muteDetails.append(count == 1 ? "1 App Muted" : "\(count) Apps Muted")
        }
        let muteSuffix = muteDetails.isEmpty ? "" : " · \(muteDetails.joined(separator: ", "))"

        if state.isSessionRecording {
            button.toolTip = "\(AppBranding.name) — Session\(displayDetail) \(state.formattedSessionDuration) (stop to save)\(muteSuffix)"
        } else if state.isRecording {
            if AppSettings.longBufferEnabled {
                let longReplayCap = TimeInterval(AppSettings.longBufferDurationSeconds)
                let available = min(state.extendedBufferElapsedSeconds, longReplayCap)
                button.toolTip = "\(AppBranding.name) — Recording\(displayDetail) \(state.formattedRecordingDuration) · Extended replay \(MenuBarState.formattedDuration(available))/\(MenuBarState.formattedDuration(longReplayCap))\(muteSuffix)"
            } else {
                let cap = TimeInterval(AppSettings.bufferDurationSeconds)
                let buffered = MenuBarState.formattedDuration(min(state.bufferedSeconds, cap))
                button.toolTip = "\(AppBranding.name) — Recording\(displayDetail) \(state.formattedRecordingDuration) · Quick replay \(buffered)/\(MenuBarState.formattedDuration(cap))\(muteSuffix)"
            }
        } else {
            button.toolTip = "\(AppBranding.name) — Not recording\(muteSuffix)"
        }
    }

    private func updateStatusItemWidth(_ contentWidth: CGFloat) {
        let minimumWidth: CGFloat = 22
        statusItem?.length = max(minimumWidth, contentWidth + 8)
    }

    @objc private func saveClip() {
        onSaveClip?()
    }

    @objc private func saveLongBuffer() {
        onSaveLongBuffer?()
    }

    @objc private func toggleSessionRecording() {
        onToggleSessionRecording?()
    }

    @objc private func toggleRecording() {
        onToggleRecording?()
    }

    @objc private func toggleMicrophoneMute() {
        onToggleMicrophoneMute?()
    }

    @objc private func toggleSystemAudioMute() {
        onToggleSystemAudioMute?()
    }

    @objc private func toggleMutedAppFromMenu(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        AppSettings.toggleAudioAppMute(bundleID)
        refreshPresentation()
    }

    @objc private func unmuteAllAppsFromMenu() {
        AppSettings.unmuteAllAudioApps()
        refreshPresentation()
    }

    @objc private func openAudioSettings() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let onOpenAudioSettings = self.onOpenAudioSettings {
                onOpenAudioSettings()
                return
            }
            self.openSettings()
        }
    }

    @objc private func openSettings() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            if let onOpenSettings = self.onOpenSettings {
                onOpenSettings()
                return
            }

            self.onOpenMainWindow?()
        }
    }

    @objc private func openMainWindow() {
        onOpenMainWindow?()
    }

    @objc private func openClipLibrary() {
        if let onOpenClipLibrary {
            onOpenClipLibrary()
        } else {
            onOpenMainWindow?()
        }
    }

    @objc private func copyLastClip() {
        if let onCopyLastClip {
            onCopyLastClip()
        } else {
            copyLastClipToPasteboard()
        }
    }

    @objc private func openLastClip() {
        guard let lastClipURL, FileManager.default.fileExists(atPath: lastClipURL.path) else {
            setLastClip(nil)
            return
        }
        NSWorkspace.shared.open(lastClipURL)
    }

    @objc private func revealLastClip() {
        guard let lastClipURL, FileManager.default.fileExists(atPath: lastClipURL.path) else {
            setLastClip(nil)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastClipURL])
    }

    @objc private func openAvailableUpdate() {
        guard let releaseURL = state.availableUpdate?.releaseURL else {
            return
        }
        NSWorkspace.shared.open(releaseURL)
    }

    @objc private func quitApp() {
        if let onQuit {
            onQuit()
        } else {
            NSApp.terminate(nil)
        }
    }

    private var hasSaveHotkeyConfigured: Bool {
        KeyboardShortcuts.getShortcut(for: .saveClip) != nil
            || KeyboardShortcuts.getShortcut(for: .saveLast15Seconds) != nil
            || KeyboardShortcuts.getShortcut(for: .saveLast60Seconds) != nil
            || KeyboardShortcuts.getShortcut(for: .saveLongBuffer) != nil
            || KeyboardShortcuts.getShortcut(for: .toggleSessionRecording) != nil
    }
}

private struct StatusBadgeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: MenuBarState
    let onWidthChange: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 5) {
            switch state.saveStatus {
            case .saving:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
                Text("Saving…")
                    .foregroundStyle(AppTheme.accent)
            case .saved:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.success)
                Text("Saved")
                    .foregroundStyle(AppTheme.success)
            case .bufferNotRunning:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(AppTheme.danger)
                Text("Buffer Not Running")
                    .foregroundStyle(AppTheme.danger)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(AppTheme.danger)
                Text("Failed")
                    .foregroundStyle(AppTheme.danger)
            case .idle:
                if state.isSessionRecording {
                    Circle()
                        .fill(AppTheme.danger)
                        .frame(width: 8, height: 8)
                        .frame(width: 12, height: 12)
                    Text("S \(state.formattedSessionDuration)")
                        .foregroundStyle(AppTheme.textPrimary)
                } else if state.isRecording {
                    Circle()
                        .fill(AppTheme.danger)
                        .frame(width: 8, height: 8)
                        .frame(width: 12, height: 12)
                    Text(state.formattedRecordingDuration)
                        .foregroundStyle(AppTheme.textPrimary)
                } else {
                    Image(systemName: "record.circle")
                        .foregroundStyle(AppTheme.accent)
                }

                if state.isMicrophoneMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.danger)
                }

                if state.isSystemAudioMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.danger)
                }
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .fixedSize()
        .background(
            Capsule()
                .fill(backgroundColor)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: StatusWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(StatusWidthPreferenceKey.self, perform: onWidthChange)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.saveStatus)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.isRecording)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.isSessionRecording)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.bufferedSeconds)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.isMicrophoneMuted)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.isSystemAudioMuted)
    }

    private var backgroundColor: Color {
        switch state.saveStatus {
        case .saved:
            return AppTheme.success.opacity(0.12)
        case .bufferNotRunning, .failed:
            return AppTheme.danger.opacity(0.12)
        case .saving:
            return AppTheme.accent.opacity(0.12)
        case .idle:
            if state.isSessionRecording || state.isRecording {
                return AppTheme.danger.opacity(0.12)
            }
            return AppTheme.accent.opacity(0.10)
        }
    }
}

private struct StatusWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 22

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
