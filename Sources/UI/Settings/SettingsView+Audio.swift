import SwiftUI
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
                }

                Toggle("Capture microphone", isOn: $captureMicrophone)
                Toggle("Exclude ReplayMac audio", isOn: $excludeOwnAppAudio)
                    .disabled(systemAudioModeBinding.wrappedValue == .off)
            } header: {
                sectionHeader(icon: "waveform", title: "Sources")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("System audio volume")
                        Spacer()
                        Text("\(Int(systemAudioVolume * 100))%")
                            .foregroundStyle(AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(value: $systemAudioVolume, in: 0...1, step: 0.05)
                        .tint(AppTheme.accent)
                }
                .disabled(!captureSystemAudio)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Microphone volume")
                        Spacer()
                        Text("\(Int(microphoneVolume * 100))%")
                            .foregroundStyle(AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(value: $microphoneVolume, in: 0...1, step: 0.05)
                        .tint(AppTheme.accent)
                }
                .disabled(!captureMicrophone)
            } header: {
                sectionHeader(icon: "speaker.wave.2", title: "Levels")
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
                sectionHeader(icon: "mic", title: "Microphone")
            }

            Section {
                Label("Audio source changes apply automatically.", systemImage: "bolt.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
            }
        }
        .formStyle(.grouped)
    }

    var selectedAppAudioHelpText: String {
        let appName = audioApplications.first { $0.bundleID == perAppAudioBundleID }?.name ?? "the selected app"
        return "Only \(appName) audio will be recorded. If \(appName) is unavailable, no system audio is captured."
    }
}
