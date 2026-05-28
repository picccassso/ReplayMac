import SwiftUI
import Defaults

extension SettingsView {
    var advancedTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Memory cap")
                        Spacer()
                        Text(memoryCapLabel)
                            .foregroundStyle(AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                    Slider(value: $memoryCapMB, in: 256...4096, step: 64)
                        .tint(AppTheme.accent)
                }

                Label("Total memory shared across all replay buffers. Lower values evict oldest footage sooner.", systemImage: "info.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))

                Stepper(value: $queueDepth, in: 3...10) {
                    Text("SCK queue depth: \(queueDepth)")
                }

                Label("Number of frames ScreenCaptureKit can queue before ReplayMac processes them. Higher values may smooth capture but use more memory and add latency.", systemImage: "info.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
            } header: {
                sectionHeader(icon: "cpu", title: "Performance")
            }

            Section {
                Toggle("Play audio cue on save", isOn: $playAudioCueOnSave)
                Toggle("Show notification on save", isOn: $showNotificationOnSave)
            } header: {
                sectionHeader(icon: "speaker.wave.2.bubble.left", title: "Feedback")
            }
        }
        .formStyle(.grouped)
    }

    var memoryCapLabel: String {
        if memoryCapMB >= 1024 {
            return String(format: "%.1f GB", memoryCapMB / 1024)
        }
        return "\(Int(memoryCapMB)) MB"
    }
}
