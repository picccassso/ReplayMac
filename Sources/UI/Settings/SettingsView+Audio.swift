import Branding
import SwiftUI
import Audio
import Defaults

extension SettingsView {
    var systemAudioModeBinding: Binding<SystemAudioMode> {
        Binding(
            get: {
                if !captureSystemAudio {
                    return .off
                }
                return perAppAudioEnabled ? .selectedApp : .allApps
            },
            set: { mode in
                switch mode {
                case .off:
                    captureSystemAudio = false
                    perAppAudioEnabled = false
                case .allApps:
                    captureSystemAudio = true
                    perAppAudioEnabled = false
                case .selectedApp:
                    captureSystemAudio = true
                    perAppAudioEnabled = true
                }
            }
        )
    }

    var audioTab: some View {
        Form {
            Section {
                Picker("System audio", selection: systemAudioModeBinding) {
                    ForEach(SystemAudioMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if systemAudioModeBinding.wrappedValue == .selectedApp {
                    if audioApplications.isEmpty {
                        HStack {
                            Text("Audio app")
                            Spacer()
                            Text("No capturable apps detected")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    } else {
                        Picker("Audio app", selection: $perAppAudioBundleID) {
                            ForEach(audioApplications) { app in
                                Text(app.name).tag(app.bundleID)
                            }
                        }
                    }

                    Label(selectedAppAudioHelpText, systemImage: "info.circle")
                        .foregroundStyle(AppTheme.textSecondary)
                        .font(.system(size: 12, design: .rounded))
                } else if systemAudioModeBinding.wrappedValue == .allApps {
                    mutedApplicationsSubSection
                }

                Toggle("Capture microphone", isOn: $captureMicrophone)
                Toggle("Merge audio tracks", isOn: $mergeAudioTracks)
                Label("Combines system audio and microphone into one track for sharing. Turn off for separate tracks in editors.", systemImage: "info.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
                Toggle("Exclude \(AppBranding.name) audio", isOn: $excludeOwnAppAudio)
                    .disabled(systemAudioModeBinding.wrappedValue == .off)
            } header: {
                Text("Sources")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("System audio volume")
                        Spacer()
                        Button {
                            isSystemAudioMuted.toggle()
                        } label: {
                            Label(
                                isSystemAudioMuted ? "Muted" : "Mute",
                                systemImage: isSystemAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                            )
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(isSystemAudioMuted ? AppTheme.danger : AppTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(isSystemAudioMuted ? "Unmute system audio" : "Mute system audio")

                        Text(isSystemAudioMuted ? "Muted (\(Int(systemAudioVolume * 100))%)" : "\(Int(systemAudioVolume * 100))%")
                            .foregroundStyle(isSystemAudioMuted ? AppTheme.danger : AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(value: $systemAudioVolume, in: 0...1, step: 0.05)
                        .tint(isSystemAudioMuted ? AppTheme.danger : AppTheme.accent)
                    LiveAudioLevelMeter(source: .systemAudio, isEnabled: captureSystemAudio && !isSystemAudioMuted)
                }
                .disabled(!captureSystemAudio)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Microphone volume")
                        Spacer()
                        Button {
                            isMicrophoneMuted.toggle()
                        } label: {
                            Label(
                                isMicrophoneMuted ? "Muted" : "Mute",
                                systemImage: isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
                            )
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(isMicrophoneMuted ? AppTheme.danger : AppTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")

                        Text(isMicrophoneMuted ? "Muted (\(Int(microphoneVolume * 100))%)" : "\(Int(microphoneVolume * 100))%")
                            .foregroundStyle(isMicrophoneMuted ? AppTheme.danger : AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(value: $microphoneVolume, in: 0...1, step: 0.05)
                        .tint(isMicrophoneMuted ? AppTheme.danger : AppTheme.accent)
                    LiveAudioLevelMeter(source: .microphone, isEnabled: captureMicrophone && !isMicrophoneMuted)
                }
                .disabled(!captureMicrophone)
            } header: {
                Text("Levels")
            }

            Section {
                if microphones.isEmpty {
                    HStack {
                        Text("Mic device")
                        Spacer()
                        Text("No microphones detected")
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    Picker("Mic device", selection: $microphoneID) {
                        ForEach(microphones) { microphone in
                            Text(microphone.name).tag(microphone.id)
                        }
                    }

                    Label("Changing mic restarts the mic track; recording continues.", systemImage: "info.circle")
                        .foregroundStyle(AppTheme.textSecondary)
                        .font(.system(size: 12, design: .rounded))
                }
            } header: {
                Text("Microphone")
            }

            Section {
                Label("Audio source changes apply automatically.", systemImage: "bolt.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
            }
        }
        .formStyle(.grouped)
        // The meters are fed by the capture pipeline while recording, and by
        // AudioLevelPreview the rest of the time, so they stay live whenever
        // the source is enabled.
        .onAppear { refreshAudioLevelPreview() }
        .onDisappear { AudioLevelPreview.shared.setConfiguration(nil) }
        .onChange(of: selectedTab) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: captureSystemAudio) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: captureMicrophone) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: perAppAudioEnabled) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: perAppAudioBundleID) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: mutedAudioAppBundleIDs) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: excludeOwnAppAudio) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: microphoneID) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: systemAudioVolume) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: microphoneVolume) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: isSystemAudioMuted) { _, _ in refreshAudioLevelPreview() }
        .onChange(of: isMicrophoneMuted) { _, _ in refreshAudioLevelPreview() }
    }

    private var mutedApplicationsSubSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Muted Applications")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if !mutedAudioAppBundleIDs.isEmpty {
                    Button("Unmute All") {
                        AppSettings.unmuteAllAudioApps()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Menu {
                    let running = addableMutedAudioApps()
                    if !running.isEmpty {
                        Section("Running Applications") {
                            ForEach(running) { app in
                                Button(app.name) {
                                    AppSettings.muteAudioApp(app.bundleID)
                                }
                            }
                        }
                    }
                    Section {
                        Button("Choose Application from Disk…") {
                            promptToChooseApp { bundleID in
                                AppSettings.muteAudioApp(bundleID)
                            }
                        }
                    }
                } label: {
                    Label("Mute App…", systemImage: "plus")
                }
            }

            if mutedAudioAppBundleIDs.isEmpty {
                Text("No applications muted. Muted apps stay visible on screen, but their audio is left out of replays and session recordings.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                ForEach(mutedAudioAppBundleIDs, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        if let icon = AppSettings.appIcon(for: bundleID) {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 16, height: 16)
                        }
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.danger)
                        Text(AppSettings.appDisplayName(for: bundleID))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !AppSettings.isApplicationRunning(bundleID) {
                            Text("Not running")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(AppTheme.textSecondary.opacity(0.14))
                                )
                        }
                        Spacer()
                        Button {
                            AppSettings.unmuteAudioApp(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Unmute \(AppSettings.appDisplayName(for: bundleID))")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func addableMutedAudioApps() -> [AudioApplicationOption] {
        var combined = AppSettings.capturableRunningApplications(excluding: mutedAudioAppBundleIDs)
        var seen = Set(combined.map { $0.bundleID.lowercased() })
        let mutedSet = Set(mutedAudioAppBundleIDs.map { $0.lowercased() })
        let ownID = Bundle.main.bundleIdentifier?.lowercased()

        for app in audioApplications {
            let lower = app.bundleID.lowercased()
            if lower != ownID, !mutedSet.contains(lower), seen.insert(lower).inserted {
                combined.append(app)
            }
        }
        return combined.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func refreshAudioLevelPreview() {
        guard isVisible, selectedTab == .audio else {
            AudioLevelPreview.shared.setConfiguration(nil)
            return
        }

        AudioLevelPreview.shared.setConfiguration(
            AudioLevelPreview.Configuration(
                monitorSystemAudio: captureSystemAudio,
                monitorMicrophone: captureMicrophone,
                microphoneDeviceID: microphoneID,
                perAppAudioBundleID: perAppAudioEnabled && !perAppAudioBundleID.isEmpty ? perAppAudioBundleID : nil,
                excludedAudioBundleIDs: !perAppAudioEnabled ? mutedAudioAppBundleIDs : [],
                excludeOwnAppAudio: excludeOwnAppAudio,
                systemAudioVolume: AppSettings.effectiveSystemAudioVolume(
                    volume: systemAudioVolume,
                    isMuted: isSystemAudioMuted
                ),
                microphoneVolume: AppSettings.effectiveMicrophoneVolume(
                    volume: microphoneVolume,
                    isMuted: isMicrophoneMuted
                )
            )
        )
    }

    var selectedAppAudioHelpText: String {
        let appName = audioApplications.first { $0.bundleID == perAppAudioBundleID }?.name ?? "the selected app"
        return "Only \(appName) audio will be recorded. If \(appName) is unavailable, no system audio is captured."
    }
}

private struct LiveAudioLevelMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: Source
    let isEnabled: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let snapshot = AudioLevelMonitor.shared.snapshot()
            let level = source == .systemAudio ? snapshot.systemAudio : snapshot.microphone

            HStack(spacing: 8) {
                Text("Live level")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 52, alignment: .leading)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AppTheme.textSecondary.opacity(0.16))
                        Capsule()
                            .fill(meterColor(for: level))
                            .frame(width: proxy.size.width * level)
                    }
                }
                .frame(height: 6)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .linear(duration: 0.1), value: level)
        }
    }

    private func meterColor(for level: Double) -> Color {
        if level >= 0.9 {
            return AppTheme.danger
        }
        if level >= 0.72 {
            return .orange
        }
        return AppTheme.success
    }

    enum Source {
        case systemAudio
        case microphone
    }
}
