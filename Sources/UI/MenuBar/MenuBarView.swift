import SwiftUI
import KeyboardShortcuts

public struct MenuBarView: View {
    @ObservedObject private var state: MenuBarState
    private let onSaveClip: () -> Void
    private let onQuit: () -> Void

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    public init(
        state: MenuBarState,
        onSaveClip: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.state = state
        self.onSaveClip = onSaveClip
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: state.isSaving ? "checkmark.circle.fill" : "record.circle.fill")
                    .foregroundStyle(state.isSaving ? .green : (state.isRecording ? .red : .secondary))
                Text(state.statusText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
            }

            Divider()

            Button("Save Replay (\(AppSettings.bufferDurationSeconds)s)") {
                onSaveClip()
            }
            .keyboardShortcut(.return, modifiers: [])

            if !hasSaveHotkeyConfigured {
                Label("No hotkey set — configure in Settings", systemImage: "keyboard")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Button("Clip Library") {
                openWindow(id: "library")
            }

            Button("Settings…") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Button("Quit ReplayMac", role: .destructive) {
                onQuit()
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(12)
        .frame(width: 260)
    }

    private var hasSaveHotkeyConfigured: Bool {
        KeyboardShortcuts.getShortcut(for: .saveClip) != nil
            || KeyboardShortcuts.getShortcut(for: .saveLast15Seconds) != nil
            || KeyboardShortcuts.getShortcut(for: .saveLast60Seconds) != nil
    }
}
