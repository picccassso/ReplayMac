import Cocoa
import SwiftUI
import KeyboardShortcuts

@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<StatusBadgeView>?
    private var state = MenuBarState()
    private var saveItem: NSMenuItem?
    private var libraryItem: NSMenuItem?
    private var bufferUsageItem: NSMenuItem?
    private var hotkeyHintItem: NSMenuItem?

    public var onSaveClip: (() -> Void)?
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
    }

    private func configureButton(for item: NSStatusItem) {
        guard let button = item.button else {
            return
        }

        button.image = nil
        button.title = ""
        button.toolTip = "ReplayMac"

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

        let hotkeyHintItem = NSMenuItem(title: "No hotkey set — configure in Settings", action: nil, keyEquivalent: "")
        hotkeyHintItem.isEnabled = false
        menu.addItem(hotkeyHintItem)

        let libraryItem = NSMenuItem(title: "Clip Library", action: #selector(openClipLibrary), keyEquivalent: "")
        libraryItem.target = self
        menu.addItem(libraryItem)

        let bufferUsageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        bufferUsageItem.isEnabled = false
        menu.addItem(bufferUsageItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit ReplayMac", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        self.saveItem = saveItem
        self.libraryItem = libraryItem
        self.bufferUsageItem = bufferUsageItem
        self.hotkeyHintItem = hotkeyHintItem
        refreshMenuItems()
        item.menu = menu
    }

    public func menuWillOpen(_ menu: NSMenu) {
        refreshMenuItems()
    }

    private func refreshMenuItems() {
        let replaySeconds = AppSettings.bufferDurationSeconds
        saveItem?.title = "Save Last \(replaySeconds) Seconds"
        libraryItem?.title = "Clip Library"
        bufferUsageItem?.title = "Buffer: \(state.formattedBufferDuration) / \(state.formattedBufferMemory)"
        hotkeyHintItem?.isHidden = hasSaveHotkeyConfigured
    }

    private func updateStatusItemWidth(_ contentWidth: CGFloat) {
        let minimumWidth: CGFloat = 22
        statusItem?.length = max(minimumWidth, contentWidth + 8)
    }

    @objc private func saveClip() {
        onSaveClip?()
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
    }
}

private struct StatusBadgeView: View {
    @ObservedObject var state: MenuBarState
    let onWidthChange: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if state.isSaving {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved")
            } else if state.isRecording {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                Text(state.formattedBufferDuration)
            } else {
                Image(systemName: "record.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: StatusWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(StatusWidthPreferenceKey.self, perform: onWidthChange)
    }
}

private struct StatusWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 22

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
