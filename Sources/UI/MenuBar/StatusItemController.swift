import Branding
import Cocoa
import SwiftUI
import KeyboardShortcuts

@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<StatusBadgeView>?
    private var state = MenuBarState()
    private var saveItem: NSMenuItem?
    private var saveLongBufferItem: NSMenuItem?
    private var toggleSessionRecordingItem: NSMenuItem?
    private var toggleRecordingItem: NSMenuItem?
    private var toggleMicMuteItem: NSMenuItem?
    private var toggleSystemAudioMuteItem: NSMenuItem?
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

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([clipURL as NSURL])
        return clipURL
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

        menu.addItem(NSMenuItem.separator())

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
        saveItem?.title = "Save Last \(replaySeconds) Seconds"
        saveItem?.isEnabled = SavePreflight.canSaveQuickReplay(
            isRecording: state.isRecording,
            bufferedSeconds: state.bufferedSeconds,
            saveInProgress: state.isSaveInProgress
        )

        let longBufferSeconds = AppSettings.longBufferDurationSeconds
        saveLongBufferItem?.title = "Save Last \(MenuBarState.formattedDuration(TimeInterval(longBufferSeconds)))"
        saveLongBufferItem?.isHidden = !AppSettings.longBufferEnabled
        saveLongBufferItem?.isEnabled = SavePreflight.canSaveLongReplay(
            isRecording: state.isRecording,
            saveInProgress: state.isSaveInProgress
        )

        toggleSessionRecordingItem?.title = state.isSessionRecording
            ? "Stop & Save Session"
            : "Start Session Recording"
        toggleSessionRecordingItem?.isEnabled = !state.isSaveInProgress

        toggleRecordingItem?.title = state.isRecording ? "Stop Replay Buffer" : "Start Replay Buffer"

        if !AppSettings.captureMicrophone {
            toggleMicMuteItem?.title = "Enable & Unmute Microphone"
            toggleMicMuteItem?.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "Microphone disabled")
        } else if state.isMicrophoneMuted {
            toggleMicMuteItem?.title = "Unmute Microphone"
            toggleMicMuteItem?.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone muted")
        } else {
            toggleMicMuteItem?.title = "Mute Microphone"
            toggleMicMuteItem?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone active")
        }

        if !AppSettings.captureSystemAudio {
            toggleSystemAudioMuteItem?.title = "Enable & Unmute System Audio"
            toggleSystemAudioMuteItem?.image = NSImage(systemSymbolName: "speaker.slash", accessibilityDescription: "System audio disabled")
        } else if state.isSystemAudioMuted {
            toggleSystemAudioMuteItem?.title = "Unmute System Audio"
            toggleSystemAudioMuteItem?.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "System audio muted")
        } else {
            toggleSystemAudioMuteItem?.title = "Mute System Audio"
            toggleSystemAudioMuteItem?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "System audio active")
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

        let quickReplayCap = TimeInterval(replaySeconds)
        let capLabel = MenuBarState.formattedDuration(quickReplayCap)
        // The buffer retains headroom beyond the replay window; don't surface more
        // than the window the user can actually save.
        let bufferedLabel = MenuBarState.formattedDuration(min(state.bufferedSeconds, quickReplayCap))
        var bufferLine = "Quick replay: \(bufferedLabel) / \(capLabel) · \(state.formattedBufferMemory)"
        if state.isRecording && state.bufferedSeconds < TimeInterval(replaySeconds) {
            bufferLine += " (filling…)"
        } else if state.isRecording {
            bufferLine += " (ready)"
        }
        bufferUsageItem?.title = bufferLine
        // A session recording that started capture on its own deliberately
        // leaves the replay buffers empty, so reporting them would just look
        // like something had gone wrong.
        let isSessionOnlyCapture = state.isSessionRecording && !state.isRecording
        bufferUsageItem?.isHidden = isSessionOnlyCapture

        let longReplayCap = TimeInterval(longBufferSeconds)
        let longReplayAvailable = min(state.extendedBufferElapsedSeconds, longReplayCap)
        var longBufferLine = "Extended replay: \(MenuBarState.formattedDuration(longReplayAvailable)) / \(MenuBarState.formattedDuration(longReplayCap))"
        if state.isRecording && longReplayAvailable < longReplayCap {
            longBufferLine += " (filling…)"
        } else if state.isRecording {
            longBufferLine += " (ready)"
        }
        longBufferUsageItem?.title = longBufferLine
        longBufferUsageItem?.isHidden = !AppSettings.longBufferEnabled || isSessionOnlyCapture

        hotkeyHintItem?.isHidden = hasSaveHotkeyConfigured

        if let availableUpdate = state.availableUpdate {
            updateItem?.title = "Update Available: \(availableUpdate.version)"
            updateItem?.isHidden = false
        } else {
            updateItem?.isHidden = true
        }
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
        case .failed:
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
