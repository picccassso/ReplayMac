import Branding
import SwiftUI
import AppKit
import Defaults
import Hotkeys
import KeyboardShortcuts
import Save
import ServiceManagement

/// First-run setup assistant. Walks through the settings a new user should
/// see before the first recording — where clips are saved, buffer length,
/// audio sources, and hotkeys — writing straight to the shared Defaults keys
/// so Settings reflects every choice afterwards.
public struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case welcome
        case storage
        case capture
        case hotkeys
        case finish
    }

    @Default(.bufferDurationSeconds) var bufferDurationSeconds
    @Default(.outputDirectoryPath) var outputDirectoryPath
    @Default(.captureSystemAudio) var captureSystemAudio
    @Default(.captureMicrophone) var captureMicrophone
    @Default(.launchAtLogin) var launchAtLogin
    @Default(.autoStartRecordingOnLaunch) var autoStartRecordingOnLaunch
    @Default(.showNotificationOnSave) var showNotificationOnSave

    @State private var step: Step = .welcome
    @State private var launchAtLoginError: String?
    @State private var hasSelectedOutputDirectory = false

    private let onFinish: () -> Void

    public init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 40)
                .padding(.top, 36)

            footer
        }
        .frame(width: 580, height: 560)
        .background(AppTheme.backgroundPrimary)
        .onChange(of: launchAtLogin) { _, newValue in
            applyLaunchAtLogin(newValue)
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .storage:
            storageStep
        case .capture:
            captureStep
        case .hotkeys:
            hotkeysStep
        case .finish:
            finishStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Welcome to \(AppBranding.name)")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Never miss a moment. \(AppBranding.name) keeps a rolling recording of your screen so the highlight is always ready to save — after it happens.")
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                featureRow(
                    icon: "record.circle",
                    title: "Always-on replay buffer",
                    detail: "The last few minutes of your screen are held in memory, never written to disk until you ask."
                )
                featureRow(
                    icon: "keyboard",
                    title: "Save with a hotkey",
                    detail: "Press your hotkey and the moment is saved as an MP4 clip."
                )
                featureRow(
                    icon: "film.stack",
                    title: "Clip library",
                    detail: "Browse, preview, and export everything you've saved."
                )
            }
            .padding(.top, 8)
        }
    }

    private var storageStep: some View {
        stepLayout(
            icon: "folder",
            title: "Where clips are saved",
            subtitle: "Saved clips are regular MP4 files you can open in Finder any time."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(storageLocationTitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)

                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text(storageLocationDisplayPath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(outputDirectoryPath.isEmpty ? "No folder selected" : outputDirectoryPath)
                        Spacer()
                    }
                }
                .padding(12)
                .background(AppTheme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous))

                Button("Choose Folder…") {
                    if let path = OutputDirectoryAccess.promptUserToChoose() {
                        outputDirectoryPath = path
                        hasSelectedOutputDirectory = true
                    }
                }
                .buttonStyle(AccentButtonStyle())

                Text(
                    hasSelectedOutputDirectory
                        ? "\(AppBranding.name) will save clips in this folder. Nothing is uploaded anywhere."
                        : "No folder selected. Choose a user-accessible folder before continuing."
                )
                    .font(.caption)
                    .foregroundStyle(hasSelectedOutputDirectory ? AppTheme.textSecondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var storageLocationTitle: String {
        if hasSelectedOutputDirectory {
            return "Selected folder"
        }
        return AppBranding.requiresExplicitOutputDirectorySelection
            ? "No folder selected"
            : "Suggested location"
    }

    private var storageLocationDisplayPath: String {
        guard !outputDirectoryPath.isEmpty else {
            return "Choose a folder to continue"
        }
        return UserHome.abbreviateForDisplay(outputDirectoryPath)
    }

    private var captureStep: some View {
        stepLayout(
            icon: "video",
            title: "Recording",
            subtitle: "How much of the past to keep, and what to record alongside the screen."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Stepper(value: $bufferDurationSeconds, in: 15...300, step: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .foregroundStyle(AppTheme.accent)
                        Text("Replay buffer: last \(bufferDurationSeconds) seconds")
                    }
                }

                Divider()

                Toggle(isOn: $captureSystemAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record system audio")
                        Text("Game and app sound is included in clips.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }

                Toggle(isOn: $captureMicrophone) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record microphone")
                        Text("macOS will ask for microphone access when recording starts.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }

                Text("Video quality, frame rate, and dual-display capture live in Settings → Video.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var hotkeysStep: some View {
        stepLayout(
            icon: "keyboard",
            title: "Hotkeys",
            subtitle: "These work system-wide, even while you're in a full-screen game."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                KeyboardShortcuts.Recorder("Save clip", name: .saveClip)
                KeyboardShortcuts.Recorder("Start/stop recording", name: .toggleRecording)

                Text("Quick presets (save last 15 or 60 seconds, extended replay, session recording, open library) can be assigned in Settings → Hotkeys.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var finishStep: some View {
        stepLayout(
            icon: "checkmark.circle",
            title: "You're all set",
            subtitle: "A couple of startup preferences, then \(AppBranding.name) gets out of your way in the menu bar."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Launch \(AppBranding.name) at login", isOn: $launchAtLogin)
                Toggle("Start recording automatically on launch", isOn: $autoStartRecordingOnLaunch)
                Toggle("Show a notification when a clip is saved", isOn: $showNotificationOnSave)

                if let launchAtLoginError {
                    Label(launchAtLoginError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

                Label {
                    Text("macOS will ask for Screen Recording permission the first time recording starts. Everything here can be changed later in Settings.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(AppTheme.accent)
                }
            }
        }
    }

    // MARK: - Chrome

    private var footer: some View {
        HStack {
            Button("Back") {
                withAnimation(.easeOut(duration: 0.15)) {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                }
            }
            .opacity(step == .welcome ? 0 : 1)
            .disabled(step == .welcome)

            Spacer()

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { candidate in
                    Circle()
                        .fill(candidate == step ? AppTheme.accent : AppTheme.textSecondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            Button(step == .finish ? "Get Started" : "Continue") {
                if step == .finish {
                    onFinish()
                } else {
                    withAnimation(.easeOut(duration: 0.15)) {
                        step = Step(rawValue: step.rawValue + 1) ?? .finish
                    }
                }
            }
            .buttonStyle(AccentButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(step == .storage && !hasSelectedOutputDirectory)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(AppTheme.backgroundSecondary)
    }

    private func stepLayout(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(subtitle)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Launch at login update failed: \(error.localizedDescription)"
            launchAtLogin.toggle()
        }
    }
}
