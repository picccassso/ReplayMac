import SwiftUI
import Defaults

extension SettingsView {
    var dualDisplayOptions: [DisplayOption] {
        displays.filter { $0.id != captureDisplayID }
    }

    var videoTab: some View {
        Form {
            Section {
                Picker("Codec", selection: $videoCodecRawValue) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text(codec.title).tag(codec.rawValue)
                    }
                }

                Picker("Capture mode", selection: $captureModeRawValue) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }

                if displays.isEmpty {
                    HStack {
                        Text("Capture source")
                        Spacer()
                        Text(displayLoadError ?? "No displays available yet")
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    Picker("Display 1", selection: $captureDisplayID) {
                        ForEach(displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }

                    if captureModeRawValue == CaptureMode.dualSideBySide.rawValue {
                        Picker("Display 2", selection: $captureDisplayID2) {
                            ForEach(dualDisplayOptions) { display in
                                Text(display.name).tag(display.id)
                            }
                        }

                        Picker("Save dual recording as", selection: $dualCaptureSaveModeRawValue) {
                            ForEach(DualCaptureSaveMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                    }
                }
            } header: {
                sectionHeader(icon: "camera", title: "Capture")
            }

            Section {
                Picker("Resolution", selection: $captureResolutionRawValue) {
                    ForEach(CaptureResolution.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }

                if captureResolutionRawValue == CaptureResolution.custom.rawValue {
                    Stepper(value: $customCaptureWidth, in: 640...7680, step: 16) {
                        Text("Custom width: \(customCaptureWidth)")
                    }
                    Stepper(value: $customCaptureHeight, in: 360...4320, step: 16) {
                        Text("Custom height: \(customCaptureHeight)")
                    }
                }

                Picker("Frame rate", selection: $frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Text(bitrateValueLabel)
                            .foregroundStyle(AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(
                        value: $bitrateSliderValue,
                        in: 10...50,
                        step: 1,
                        onEditingChanged: handleBitrateSliderEditingChanged
                    )
                        .tint(AppTheme.accent)
                    HStack(spacing: 8) {
                        Label(bitrateScopeLabel, systemImage: "info.circle")
                        Spacer()
                        Text(recommendedBitrateLabel)
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
                }

                Picker("Quality preset", selection: $qualityPresetRawValue) {
                    ForEach(QualityPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
            } header: {
                sectionHeader(icon: "film.stack", title: "Encoding")
            }

            Section {
                Label("Encoding changes apply automatically and reset the video replay buffer.", systemImage: "bolt.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
            }

            Section {
                Toggle("Extended replay buffer", isOn: longBufferToggleBinding)

                Picker("Long buffer duration", selection: $longBufferDurationMinutes) {
                    ForEach(LongBufferDuration.allCases) { duration in
                        Text(duration.title).tag(duration.rawValue)
                    }
                }
                .disabled(!longBufferEnabled)

                Label(longBufferWarningText, systemImage: "externaldrive.badge.timemachine")
                    .foregroundStyle(longBufferEnabled ? .orange : AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
            } header: {
                sectionHeader(icon: "clock.badge.exclamationmark", title: "Long Buffer")
            }
        }
        .formStyle(.grouped)
    }

    func validateDisplay2Selection() {
        let remaining = displays.filter { $0.id != captureDisplayID }
        if !remaining.contains(where: { $0.id == captureDisplayID2 }) {
            captureDisplayID2 = remaining.first?.id ?? ""
        }
    }

    var longBufferToggleBinding: Binding<Bool> {
        Binding(
            get: { longBufferEnabled },
            set: { newValue in
                if newValue {
                    longBufferWarningAccepted = true
                }
                longBufferEnabled = newValue
            }
        )
    }

    var longBufferWarningText: String {
        let duration = LongBufferDuration(rawValue: longBufferDurationMinutes) ?? .fiveMinutes
        let estimatedGB = estimatedLongBufferDiskGB(minutes: duration.rawValue)
        return "Opt-in only. Uses temporary disk space while recording, writes continuously to the SSD, and may use about \(estimatedGB) GB at your current bitrate before old segments rotate."
    }

    func estimatedLongBufferDiskGB(minutes: Int) -> String {
        let videoMbps = bitrateMbps
        let audioMbps = (systemAudioModeBinding.wrappedValue == .off ? 0 : 0.2) + (captureMicrophone ? 0.2 : 0)
        let totalMbps = videoMbps + audioMbps
        let bytes = totalMbps * 1_000_000 / 8 * Double(minutes * 60)
        return String(format: "%.1f", bytes / 1_000_000_000)
    }
}
