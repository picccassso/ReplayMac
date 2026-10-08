import AppKit
import Branding
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
    /// Natural width of "Stop Buffer", so the button can grow from a circle to a pill.
    @State private var stopLabelWidth: CGFloat = 72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var controls: ReplayControls { windowState.controls }
    private var longBufferSeconds: Int {
        LongBufferDuration(rawValue: longBufferMinutes)?.seconds ?? LongBufferDuration.fiveMinutes.seconds
    }
    private var isSessionOnlyCapture: Bool {
        ReplayControlLabels.isSessionOnlyCapture(isRecording: menuBar.isRecording,
                                                 isSessionRecording: menuBar.isSessionRecording)
    }

    /// Only a start/stop toggle animates it (the `value:` below), so values that
    /// tick every second never pick up the spring.
    private var stateAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.4)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                // Three flexible columns stretch the tiles to fill any window width.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3),
                          alignment: .leading, spacing: 16) {
                    tiles
                }
                sessionHistory
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(stateAnimation, value: menuBar.isRecording)
            .animation(stateAnimation, value: menuBar.isSessionRecording)
        }
        .onAppear(perform: reloadShortcuts)
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                StatusDot(isLive: menuBar.isRecording || menuBar.isSessionRecording)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .contentTransition(.opacity)
                    Text(subheadline)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                bufferToggleButton
            }
            .frame(minHeight: 34)

            if menuBar.isRecording && !isSessionOnlyCapture {
                VStack(alignment: .leading, spacing: 16) {
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
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    /// The same toggle as the buffer tile below, within reach of the status it describes.
    /// One capsule morphs between the play circle and the "Stop Buffer" pill.
    private var bufferToggleButton: some View {
        let label = ReplayControlLabels.replayBuffer(isRecording: menuBar.isRecording)
        let isRunning = menuBar.isRecording
        return Button(action: controls.toggleBuffer) {
            HStack(spacing: 0) {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text("Stop Buffer")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { stopLabelWidth = $0 }
                    .opacity(isRunning ? 1 : 0)
                    .frame(width: isRunning ? stopLabelWidth : 0, alignment: .leading)
                    .clipped()
                    .padding(.leading, isRunning ? 6 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, isRunning ? 12 : 11)
            .frame(height: isRunning ? 28 : 34)
            .background(AppTheme.danger.opacity(0.15), in: Capsule())
        }
        .buttonStyle(HomeStatusButtonStyle())
        .help(label.title)
        .accessibilityLabel(label.title)
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

    // MARK: Session history

    /// Renamed, moved or deleted clips drop out rather than offering a dead Trim button.
    private var visibleRecentClips: [RecentClip] {
        windowState.recentClips.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private var sessionHistory: some View {
        let clips = visibleRecentClips
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("This Session")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !clips.isEmpty {
                    Button("Show All in Clip Library") { windowState.select(.library) }
                        .buttonStyle(.link)
                        .font(.system(size: 12, design: .rounded))
                }
            }
            if clips.isEmpty {
                Text("Clips you save appear here until you quit \(AppBranding.name).")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.backgroundSecondary,
                                in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(clips) { clip in
                        recentClipRow(clip)
                        if clip.id != clips.last?.id {
                            Divider().padding(.leading, 122)
                        }
                    }
                }
                .glassPanel(cornerRadius: AppTheme.cornerRadiusMedium)
            }
        }
        .padding(.top, 8)
    }

    private func recentClipRow(_ clip: RecentClip) -> some View {
        HStack(spacing: 12) {
            Group {
                if let data = clip.thumbnail, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.black.opacity(0.35)
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(clip.url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details(for: clip))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([clip.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(clip.url.lastPathComponent) in Finder")
            Button("Trim", systemImage: "scissors") { windowState.openEditor(clip.url) }
                .buttonStyle(AppButtonStyle())
                .help("Trim or crop this clip and export it")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func details(for clip: RecentClip) -> String {
        var parts = [clip.kind.title]
        if let duration = clip.duration { parts.append(MenuBarState.formattedDuration(duration)) }
        if let size = clip.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        parts.append("Saved \(clip.savedAt.formatted(date: .omitted, time: .shortened))")
        return parts.joined(separator: " · ")
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
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(prominent ? Color.white : (isActive ? AppTheme.danger : AppTheme.accent))
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text(label.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .contentTransition(.opacity)
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
                .animation(.easeInOut(duration: 0.2), value: isEnabled)
        }
    }
}

/// Red foreground for the status card's buffer button, whose label draws its own
/// soft fill. Dims when pressed or disabled like the tiles, and lightens on hover.
private struct HomeStatusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StatusBody(configuration: configuration)
    }

    private struct StatusBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(AppTheme.danger)
                .contentShape(Rectangle())
                .brightness(isHovering && isEnabled ? 0.06 : 0)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .onHover { isHovering = $0 }
        }
    }
}

/// The status light: red while capturing, with a soft ring that pulses outward
/// so a running buffer reads as live. The pulse is skipped under Reduce Motion.
private struct StatusDot: View {
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(isLive ? AppTheme.danger : Color.secondary.opacity(0.5))
            .frame(width: 10, height: 10)
            .overlay {
                if isLive && !reduceMotion {
                    PulseRing().transition(.opacity)
                }
            }
    }

    private struct PulseRing: View {
        @State private var expanded = false

        var body: some View {
            Circle()
                .stroke(AppTheme.danger.opacity(0.5), lineWidth: 1.5)
                .scaleEffect(expanded ? 2.4 : 1)
                .opacity(expanded ? 0 : 1)
                .onAppear {
                    withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { expanded = true }
                }
        }
    }
}
