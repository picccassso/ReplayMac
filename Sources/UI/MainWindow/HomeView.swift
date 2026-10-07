import Defaults
import Hotkeys
import KeyboardShortcuts
import SwiftUI

/// A control centre for the window: the menu bar's capture actions, live
/// buffer status, and each action's hotkey.
struct HomeView: View {
    @ObservedObject var windowState: MainWindowState
    @ObservedObject var menuBar: MenuBarState
    @Default(.bufferDurationSeconds) private var replaySeconds
    @Default(.longBufferEnabled) private var longBufferEnabled
    @Default(.longBufferDurationMinutes) private var longBufferMinutes
    @Default(.captureMicrophone) private var captureMicrophone
    @Default(.captureSystemAudio) private var captureSystemAudio
    /// Read when the page appears; returning from Hotkeys rebuilds this view.
    @State private var shortcuts: [KeyboardShortcuts.Name: String] = [:]

    private var controls: ReplayControls { windowState.controls }
    private var longBufferSeconds: Int {
        LongBufferDuration(rawValue: longBufferMinutes)?.seconds ?? LongBufferDuration.fiveMinutes.seconds
    }
    private var isSessionOnlyCapture: Bool {
        ReplayControlLabels.isSessionOnlyCapture(isRecording: menuBar.isRecording,
                                                 isSessionRecording: menuBar.isSessionRecording)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    tiles
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: reloadShortcuts)
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Circle()
                    .fill(menuBar.isRecording || menuBar.isSessionRecording ? AppTheme.danger : Color.secondary.opacity(0.5))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(subheadline)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if menuBar.isRecording && !isSessionOnlyCapture {
                let quickAvailable = ReplayControlLabels.quickReplayAvailable(
                    bufferedSeconds: menuBar.bufferedSeconds, capSeconds: replaySeconds)
                meter("Quick replay", available: quickAvailable, capSeconds: replaySeconds,
                      detail: "\(menuBar.formattedBufferMemory) in memory")
                if longBufferEnabled {
                    meter("Extended replay",
                          available: min(menuBar.extendedBufferElapsedSeconds, TimeInterval(longBufferSeconds)),
                          capSeconds: longBufferSeconds, detail: "Kept on disk")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private var headline: String {
        if menuBar.isSessionRecording { return "Session recording" }
        return menuBar.isRecording ? "Replay buffer running" : "Not recording"
    }

    private var subheadline: String {
        guard menuBar.isRecording || menuBar.isSessionRecording else {
            return "Start the replay buffer to keep your last \(replaySeconds) seconds ready to save."
        }
        var parts = [menuBar.isSessionRecording ? menuBar.formattedSessionDuration : menuBar.formattedRecordingDuration]
        if let display = menuBar.capturedDisplayName {
            parts.append(menuBar.isUsingFallbackDisplay ? "\(display) (Fallback)" : display)
        }
        return parts.joined(separator: " · ")
    }

    private func meter(_ title: String, available: TimeInterval, capSeconds: Int, detail: String) -> some View {
        let suffix = ReplayControlLabels.fillSuffix(isRecording: true, available: available, capSeconds: capSeconds)
        let isReady = suffix == "ready"
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text("\(MenuBarState.formattedDuration(available)) / \(MenuBarState.formattedDuration(TimeInterval(capSeconds)))")
                    .monospacedDigit()
                if let suffix {
                    Text(suffix.capitalized)
                        .foregroundStyle(isReady ? AppTheme.success : .secondary)
                }
            }
            .font(.system(size: 12, design: .rounded))
            ProgressView(value: available, total: TimeInterval(max(capSeconds, 1)))
                .tint(isReady ? AppTheme.success : AppTheme.accent)
            Text(detail)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    @ViewBuilder
    private var tiles: some View {
        tile(ReplayControlLabels.saveReplay(seconds: replaySeconds), shortcut: .saveClip, prominent: true,
             isEnabled: SavePreflight.canSaveQuickReplay(isRecording: menuBar.isRecording,
                                                         bufferedSeconds: menuBar.bufferedSeconds,
                                                         saveInProgress: menuBar.isSaveInProgress),
             action: controls.saveReplay)
        if longBufferEnabled {
            tile(ReplayControlLabels.saveExtendedReplay(seconds: longBufferSeconds), shortcut: .saveLongBuffer,
                 isEnabled: SavePreflight.canSaveLongReplay(isRecording: menuBar.isRecording,
                                                            saveInProgress: menuBar.isSaveInProgress),
                 action: controls.saveExtendedReplay)
        }
        tile(ReplayControlLabels.replayBuffer(isRecording: menuBar.isRecording), shortcut: .toggleRecording,
             action: controls.toggleBuffer)
        tile(ReplayControlLabels.session(isRecording: menuBar.isSessionRecording), shortcut: .toggleSessionRecording,
             isActive: menuBar.isSessionRecording, isEnabled: !menuBar.isSaveInProgress,
             action: controls.toggleSession)
        tile(ReplayControlLabels.microphone(isEnabled: captureMicrophone, isMuted: menuBar.isMicrophoneMuted),
             shortcut: .toggleMicrophoneMute, action: controls.toggleMicrophone)
        tile(ReplayControlLabels.systemAudio(isEnabled: captureSystemAudio, isMuted: menuBar.isSystemAudioMuted),
             shortcut: .toggleSystemAudioMute, action: controls.toggleSystemAudio)
    }

    private func tile(_ label: ReplayControlLabel, shortcut: KeyboardShortcuts.Name,
                      prominent: Bool = false, isActive: Bool = false, isEnabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: label.symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(prominent ? Color.white : (isActive ? AppTheme.danger : AppTheme.accent))
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text(label.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(HomeTileButtonStyle(prominent: prominent))
            .disabled(!isEnabled)
            .help(label.title)

            shortcutHint(shortcut)
                .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private func shortcutHint(_ name: KeyboardShortcuts.Name) -> some View {
        if let shortcut = shortcuts[name] {
            Text(shortcut)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Shortcut \(shortcut)")
        } else {
            Button("Set shortcut") { windowState.select(.hotkeys) }
                .buttonStyle(.link)
                .font(.system(size: 11, design: .rounded))
        }
    }

    private func reloadShortcuts() {
        let names: [KeyboardShortcuts.Name] = [.saveClip, .saveLongBuffer, .toggleRecording,
                                               .toggleSessionRecording, .toggleMicrophoneMute,
                                               .toggleSystemAudioMute]
        shortcuts = Dictionary(uniqueKeysWithValues: names.compactMap { name in
            KeyboardShortcuts.getShortcut(for: name).map { (name, $0.description) }
        })
    }
}

/// A full-width action tile: accent-filled for the primary action, otherwise a
/// quiet fill that follows the system appearance.
private struct HomeTileButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, prominent: prominent)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(prominent ? Color.white : AppTheme.textPrimary)
                .background(prominent ? AppTheme.accent : AppTheme.backgroundSecondary,
                            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }
    }
}
