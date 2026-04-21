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
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    onSaveClip()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14))
                        Text("Save Replay (\(AppSettings.bufferDurationSeconds)s)")
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.return, modifiers: [])

                if !hasSaveHotkeyConfigured {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard.badge.ellipsis")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.accent)
                        Text("No hotkey set — configure in Settings")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.leading, 2)
                }

                actionRow(icon: "film.stack", title: "Clip Library") {
                    openWindow(id: "library")
                }

                actionRow(icon: "gearshape", title: "Settings…") {
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            .padding(14)

            Divider()
                .padding(.horizontal, 12)

            Button(role: .destructive) {
                onQuit()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                    Text("Quit ReplayMac")
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .keyboardShortcut("q", modifiers: [.command])
        }
        .frame(width: 280)
        .background(.ultraThinMaterial)
    }

    private var headerView: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.accent, AppTheme.accentSecondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)

                Image(systemName: "record.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("ReplayMac")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                HStack(spacing: 6) {
                    statusDot
                    Text(state.statusText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(statusColor)
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if state.isSaving {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.success)
                .font(.system(size: 10))
        } else if state.isRecording {
            Circle()
                .fill(AppTheme.danger)
                .frame(width: 8, height: 8)
                .pulsingDot()
        } else {
            Circle()
                .fill(AppTheme.textSecondary)
                .frame(width: 6, height: 6)
        }
    }

    private var statusColor: Color {
        if state.isSaving { return AppTheme.success }
        if state.isRecording { return AppTheme.danger }
        return AppTheme.textSecondary
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(AppTheme.backgroundSecondary.opacity(0.0))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous))
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.15)) {
                // Background change handled by overlay if needed; plain style keeps it minimal
            }
        }
    }

    private var hasSaveHotkeyConfigured: Bool {
        KeyboardShortcuts.getShortcut(for: .saveClip) != nil
            || KeyboardShortcuts.getShortcut(for: .saveLast15Seconds) != nil
            || KeyboardShortcuts.getShortcut(for: .saveLast60Seconds) != nil
    }
}
