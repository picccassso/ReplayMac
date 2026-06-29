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
    private var toggleRecordingItem: NSMenuItem?
    private var libraryItem: NSMenuItem?
    private var revealLastClipItem: NSMenuItem?
    private var openLastClipItem: NSMenuItem?
    private var recordingDurationItem: NSMenuItem?
    private var bufferUsageItem: NSMenuItem?
    private var longBufferUsageItem: NSMenuItem?
    private var hotkeyHintItem: NSMenuItem?
    private var updateItem: NSMenuItem?

    private var lastClipURL: URL?

    public var onSaveClip: (() -> Void)?
    public var onSaveLongBuffer: (() -> Void)?
    public var onToggleRecording: (() -> Void)?
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

        let hotkeyHintItem = NSMenuItem(title: "No hotkey set — configure in Settings", action: nil, keyEquivalent: "")
        hotkeyHintItem.isEnabled = false
        menu.addItem(hotkeyHintItem)

        let toggleRecordingItem = NSMenuItem(title: "", action: #selector(toggleRecording), keyEquivalent: "")
        toggleRecordingItem.target = self
        menu.addItem(toggleRecordingItem)

        let libraryItem = NSMenuItem(title: "Clip Library", action: #selector(openClipLibrary), keyEquivalent: "")
        libraryItem.target = self
        menu.addItem(libraryItem)

        let openLastClipItem = NSMenuItem(title: "Open Last Clip", action: #selector(openLastClip), keyEquivalent: "")
        openLastClipItem.target = self
        menu.addItem(openLastClipItem)

        let revealLastClipItem = NSMenuItem(title: "Reveal Last Clip in Finder", action: #selector(revealLastClip), keyEquivalent: "")
        revealLastClipItem.target = self
        menu.addItem(revealLastClipItem)

        let recordingDurationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recordingDurationItem.isEnabled = false
        menu.addItem(recordingDurationItem)

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

        let quitItem = NSMenuItem(title: "Quit ReplayMac", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        self.saveItem = saveItem
        self.saveLongBufferItem = saveLongBufferItem
        self.toggleRecordingItem = toggleRecordingItem
        self.libraryItem = libraryItem
        self.openLastClipItem = openLastClipItem
        self.revealLastClipItem = revealLastClipItem
        self.recordingDurationItem = recordingDurationItem
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
        saveItem?.isEnabled = state.isRecording && state.bufferedSeconds >= SavePreflight.minimumBufferedSeconds

        let longBufferSeconds = AppSettings.longBufferDurationSeconds
        saveLongBufferItem?.title = "Save Last \(MenuBarState.formattedDuration(TimeInterval(longBufferSeconds)))"
        saveLongBufferItem?.isHidden = !AppSettings.longBufferEnabled
        saveLongBufferItem?.isEnabled = state.isRecording && !state.isSaveInProgress

        toggleRecordingItem?.title = state.isRecording ? "Stop Recording" : "Start Recording"

        libraryItem?.title = "Clip Library"

        // Drop the reference if the clip has since been moved, renamed, or deleted.
        if let url = lastClipURL, !FileManager.default.fileExists(atPath: url.path) {
            lastClipURL = nil
        }
        let hasLastClip = lastClipURL != nil
        openLastClipItem?.isHidden = !hasLastClip
        revealLastClipItem?.isHidden = !hasLastClip

        recordingDurationItem?.title = "Recording: \(state.formattedRecordingDuration)"
        recordingDurationItem?.isHidden = !state.isRecording

        let quickReplayCap = TimeInterval(replaySeconds)
        let capLabel = MenuBarState.formattedDuration(quickReplayCap)
        var bufferLine = "Quick replay: \(state.formattedBufferDuration) / \(capLabel) · \(state.formattedBufferMemory)"
        if state.isRecording && state.bufferedSeconds < TimeInterval(replaySeconds) {
            bufferLine += " (filling…)"
        } else if state.isRecording {
            bufferLine += " (ready)"
        }
        bufferUsageItem?.title = bufferLine

        let longReplayCap = TimeInterval(longBufferSeconds)
        let longReplayAvailable = min(state.extendedBufferElapsedSeconds, longReplayCap)
        var longBufferLine = "Extended replay: \(MenuBarState.formattedDuration(longReplayAvailable)) / \(MenuBarState.formattedDuration(longReplayCap))"
        if state.isRecording && longReplayAvailable < longReplayCap {
            longBufferLine += " (filling…)"
        } else if state.isRecording {
            longBufferLine += " (ready)"
        }
        longBufferUsageItem?.title = longBufferLine
        longBufferUsageItem?.isHidden = !AppSettings.longBufferEnabled

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

        if state.isRecording {
            if AppSettings.longBufferEnabled {
                let longReplayCap = TimeInterval(AppSettings.longBufferDurationSeconds)
                let available = min(state.extendedBufferElapsedSeconds, longReplayCap)
                button.toolTip = "ReplayMac — Recording \(state.formattedRecordingDuration) · Extended replay \(MenuBarState.formattedDuration(available))/\(MenuBarState.formattedDuration(longReplayCap))"
            } else {
                let cap = TimeInterval(AppSettings.bufferDurationSeconds)
                button.toolTip = "ReplayMac — Recording \(state.formattedRecordingDuration) · Quick replay \(state.formattedBufferDuration)/\(MenuBarState.formattedDuration(cap))"
            }
        } else {
            button.toolTip = "ReplayMac — Not recording"
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

    @objc private func toggleRecording() {
        onToggleRecording?()
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

            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    @objc private func openClipLibrary() {
        if let onOpenClipLibrary {
            onOpenClipLibrary()
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
    }
}

private struct StatusBadgeView: View {
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
                if state.isRecording {
                    ZStack {
                        Circle()
                            .fill(AppTheme.danger)
                            .frame(width: 8, height: 8)
                            .pulsingDot()
                    }
                    .frame(width: 12, height: 12)
                    Text(state.formattedRecordingDuration)
                        .foregroundStyle(AppTheme.textPrimary)
                } else {
                    Image(systemName: "record.circle")
                        .foregroundStyle(AppTheme.accent)
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
        .animation(.easeOut(duration: 0.2), value: state.saveStatus)
        .animation(.easeOut(duration: 0.2), value: state.isRecording)
        .animation(.easeOut(duration: 0.2), value: state.bufferedSeconds)
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
            if state.isRecording {
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
