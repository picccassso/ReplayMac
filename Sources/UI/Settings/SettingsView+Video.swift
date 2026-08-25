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
                } else if captureModeRawValue == CaptureMode.dualSideBySide.rawValue {
                    Picker("Display 1", selection: $captureDisplayID) {
                        ForEach(displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }

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
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Capture display priority")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            if prioritizedDisplayOptions.count > 1 {
                                Text("Top connected display is recorded")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }

                        VStack(spacing: 6) {
                            ForEach(Array(prioritizedDisplayOptions.enumerated()), id: \.element.id) { index, display in
                                displayPriorityRow(index: index, display: display, count: prioritizedDisplayOptions.count)
                            }
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Label(
                            "When recording starts, the highest-priority connected display is captured. If disconnected, capture falls back to the next available screen automatically.",
                            systemImage: "arrow.triangle.branch"
                        )
                        .foregroundStyle(AppTheme.textSecondary)
                        .font(.system(size: 11, design: .rounded))
                    }
                }
            } header: {
                sectionHeader(icon: "camera", title: "Capture")
            }

            Section {
                Picker("Resolution", selection: $captureResolutionRawValue) {
                    ForEach(captureResolutionOptions) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(effectiveVideoDimensionsLabel)
                    if let dualResolutionDetailLabel {
                        Text(dualResolutionDetailLabel)
                    }
                    Text(resolutionHelpLabel)
                }
                .foregroundStyle(AppTheme.textSecondary)
                .font(.system(size: 12, design: .rounded))

                if captureResolutionRawValue == CaptureResolution.custom.rawValue {
                    Stepper(value: $customCaptureWidth, in: 640...7680, step: 16) {
                        Text("Custom width: \(customCaptureWidth)")
                    }
                    Stepper(value: $customCaptureHeight, in: 360...4320, step: 16) {
                        Text("Custom height: \(customCaptureHeight)")
                    }

                    if let customResolutionAspectLabel {
                        Label(customResolutionAspectLabel, systemImage: "aspectratio")
                            .foregroundStyle(AppTheme.textSecondary)
                            .font(.system(size: 12, design: .rounded))
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

            Section {
                Label(
                    "Session recording is always available from the menu bar (Start Session Recording) or a hotkey in Settings → Hotkeys. It records until you stop, then saves one MP4 with screen, system audio, and microphone — no rolling buffer cutoff.",
                    systemImage: "record.circle"
                )
                .foregroundStyle(AppTheme.textSecondary)
                .font(.system(size: 12, design: .rounded))
            } header: {
                sectionHeader(icon: "record.circle", title: "Session Recording")
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

    var prioritizedDisplayOptions: [DisplayOption] {
        var result: [DisplayOption] = []
        var seen = Set<String>()
        for id in captureDisplayPriorities where !id.isEmpty {
            if let match = displays.first(where: { $0.id == id }) {
                result.append(match)
                seen.insert(id)
            }
        }
        for display in displays where !seen.contains(display.id) {
            result.append(display)
            seen.insert(display.id)
        }
        return result
    }

    @ViewBuilder
    func displayPriorityRow(index: Int, display: DisplayOption, count: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 20, height: 20)
                .background(AppTheme.accent.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(display.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(display.isConnected ? AppTheme.textPrimary : AppTheme.textSecondary)
            }

            Spacer()

            if display.id == resolvedPriorityDisplay?.id {
                Text("Active")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.accent.opacity(0.18))
                    .foregroundStyle(AppTheme.accent)
                    .clipShape(Capsule())
            } else if display.isConnected {
                Text("Connected")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .clipShape(Capsule())
            } else {
                Text("Offline")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }

            HStack(spacing: 2) {
                Button {
                    moveDisplayPriority(from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)

                Button {
                    moveDisplayPriority(from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(index == count - 1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(display.id == resolvedPriorityDisplay?.id ? AppTheme.accent.opacity(0.06) : Color.clear)
        )
    }

    func moveDisplayPriority(from sourceIndex: Int, to destinationIndex: Int) {
        var list = prioritizedDisplayOptions.map(\.id)
        guard sourceIndex >= 0, sourceIndex < list.count,
              destinationIndex >= 0, destinationIndex < list.count,
              sourceIndex != destinationIndex else { return }

        let item = list.remove(at: sourceIndex)
        list.insert(item, at: destinationIndex)
        captureDisplayPriorities = list
        if let top = list.first {
            captureDisplayID = top
        }
    }
}
