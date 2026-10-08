import SwiftUI
import Defaults

extension ReplayMemoryEstimate {
    /// The estimate for whatever is currently saved in Defaults.
    static var current: ReplayMemoryEstimate {
        make(
            bufferSeconds: Defaults[.bufferDurationSeconds],
            bitrateMbps: Defaults[.bitrateMbps],
            isDualMode: Defaults[.captureMode] == CaptureMode.dualSideBySide.rawValue,
            isSeparateDualSave: Defaults[.dualCaptureSaveMode] == DualCaptureSaveMode.separateFiles.rawValue,
            captureSystemAudio: Defaults[.captureSystemAudio],
            captureMicrophone: Defaults[.captureMicrophone],
            memoryCapMB: Defaults[.memoryCapMB]
        )
    }
}

/// Live note under the replay buffer stepper saying how much RAM the buffer
/// uses, nudging long buffers toward extended replay, and warning when the
/// memory cap can't hold the whole window.
struct ReplayBufferMemoryHint: View {
    @Default(.bufferDurationSeconds) private var bufferDurationSeconds
    @Default(.bitrateMbps) private var bitrateMbps
    @Default(.captureMode) private var captureMode
    @Default(.dualCaptureSaveMode) private var dualCaptureSaveMode
    @Default(.captureSystemAudio) private var captureSystemAudio
    @Default(.captureMicrophone) private var captureMicrophone
    @Default(.memoryCapMB) private var memoryCapMB
    @Default(.longBufferEnabled) private var longBufferEnabled

    /// Shown as a button on long buffers when extended replay is off. Nil
    /// leaves just the text, for places that can't navigate to Settings.
    var openExtendedReplaySettings: (() -> Void)?

    private var estimate: ReplayMemoryEstimate {
        ReplayMemoryEstimate.make(
            bufferSeconds: bufferDurationSeconds,
            bitrateMbps: bitrateMbps,
            isDualMode: captureMode == CaptureMode.dualSideBySide.rawValue,
            isSeparateDualSave: dualCaptureSaveMode == DualCaptureSaveMode.separateFiles.rawValue,
            captureSystemAudio: captureSystemAudio,
            captureMicrophone: captureMicrophone,
            memoryCapMB: memoryCapMB
        )
    }

    var body: some View {
        let estimate = estimate
        VStack(alignment: .leading, spacing: 8) {
            usageLabel(estimate)

            if estimate.tier == .heavy && !longBufferEnabled, let openExtendedReplaySettings {
                Button("Set Up Extended Replay…", action: openExtendedReplaySettings)
                    .buttonStyle(.link)
                    .font(.system(size: 12, design: .rounded))
            }

            if estimate.isCapLimited {
                ReplayMemoryCapWarning(estimate: estimate) { memoryCapMB = $0 }
            }
        }
        .font(.system(size: 12, design: .rounded))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func usageLabel(_ estimate: ReplayMemoryEstimate) -> some View {
        switch estimate.tier {
        case .light:
            Label("Kept in memory: about \(estimate.formattedRequired).", systemImage: "memorychip")
                .foregroundStyle(AppTheme.textSecondary)
        case .moderate:
            Label("Kept in memory: about \(estimate.formattedRequired). Longer buffers use more RAM.", systemImage: "memorychip")
                .foregroundStyle(AppTheme.textSecondary)
        case .heavy:
            Label(heavyText(estimate), systemImage: "memorychip")
                .foregroundStyle(longBufferEnabled ? AppTheme.textSecondary : .orange)
        }
    }

    private func heavyText(_ estimate: ReplayMemoryEstimate) -> String {
        let usage = "Uses about \(estimate.formattedRequired) of RAM the whole time the buffer runs."
        if longBufferEnabled {
            return "\(usage) Extended replay is on, so a shorter buffer here would free that memory."
        }
        return "\(usage) For long replays, Extended replay keeps footage on disk instead."
    }
}

/// Orange warning shown when the memory cap evicts footage before the replay
/// window is full, with a one-click fix when the slider can go high enough.
struct ReplayMemoryCapWarning: View {
    let estimate: ReplayMemoryEstimate
    let raiseCap: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if let target = estimate.minimumCapMBToFit {
                Button("Raise Memory Cap to \(ReplayMemoryEstimate.formatCapMB(target))") {
                    raiseCap(target)
                }
                .buttonStyle(.link)
            }
        }
        .font(.system(size: 12, design: .rounded))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var message: String {
        let cap = ReplayMemoryEstimate.formatCapMB(estimate.memoryCapMB)
        let covered = ReplayMemoryEstimate.formatDuration(estimate.coveredSeconds)
        let requested = ReplayMemoryEstimate.formatDuration(estimate.requestedSeconds)
        let base = "Your \(cap) memory cap only holds about \(covered) at \(Int(estimate.bitrateMbps)) Mbps, so clips will be shorter than \(requested)."
        if estimate.minimumCapMBToFit == nil {
            return "\(base) Lower the bitrate or the buffer length to fit."
        }
        return base
    }
}
