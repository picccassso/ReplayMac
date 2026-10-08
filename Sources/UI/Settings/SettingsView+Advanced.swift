import Branding
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

                memoryNeedLabel

                Stepper(value: $queueDepth, in: 3...10) {
                    Text("SCK queue depth: \(queueDepth)")
                }

                Label("Number of frames ScreenCaptureKit can queue before \(AppBranding.name) processes them. Higher values may smooth capture but use more memory and add latency.", systemImage: "info.circle")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
            } header: {
                Text("Performance")
            }

            Section {
                Toggle("Play audio cue on save", isOn: $playAudioCueOnSave)
                Toggle("Show notification on save", isOn: $showNotificationOnSave)
            } header: {
                Text("Feedback")
            }
        }
        .formStyle(.grouped)
    }

    var memoryCapLabel: String {
        ReplayMemoryEstimate.formatCapMB(memoryCapMB)
    }

    var replayMemoryEstimate: ReplayMemoryEstimate {
        ReplayMemoryEstimate.make(
            bufferSeconds: bufferDurationSeconds,
            bitrateMbps: bitrateMbps,
            isDualMode: captureModeRawValue == CaptureMode.dualSideBySide.rawValue,
            isSeparateDualSave: dualCaptureSaveModeRawValue == DualCaptureSaveMode.separateFiles.rawValue,
            captureSystemAudio: captureSystemAudio,
            captureMicrophone: captureMicrophone,
            memoryCapMB: memoryCapMB
        )
    }

    @ViewBuilder
    private var memoryNeedLabel: some View {
        let estimate = replayMemoryEstimate
        if estimate.isCapLimited {
            ReplayMemoryCapWarning(estimate: estimate) { memoryCapMB = $0 }
        } else {
            Label(
                "Your replay buffer needs about \(estimate.formattedRequired) (\(ReplayMemoryEstimate.formatDuration(estimate.requestedSeconds)) at \(Int(estimate.bitrateMbps)) Mbps), which fits within this cap.",
                systemImage: "memorychip"
            )
            .foregroundStyle(AppTheme.textSecondary)
            .font(.system(size: 12, design: .rounded))
        }
    }
}
