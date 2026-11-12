import SwiftUI
import Defaults

extension ReplayMemoryEstimate {
    /// The estimate for whatever is currently saved in Defaults.
    static var current: ReplayMemoryEstimate {
        current(bitrateMbps: Defaults[.bitrateMbps])
    }

    /// The saved settings, but at a bitrate that isn't saved yet.
    static func current(bitrateMbps: Double) -> ReplayMemoryEstimate {
        make(
            bufferSeconds: Defaults[.bufferDurationSeconds],
            bitrateMbps: bitrateMbps,
            isDualMode: Defaults[.captureMode] == CaptureMode.dualSideBySide.rawValue,
            isSeparateDualSave: Defaults[.dualCaptureSaveMode] == DualCaptureSaveMode.separateFiles.rawValue,
            captureSystemAudio: Defaults[.captureSystemAudio],
            captureMicrophone: Defaults[.captureMicrophone],
            memoryCapMB: AppSettings.memoryCapMB
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
    @Default(.enabledFeatureModules) private var enabledFeatureModules
    @Default(.longBufferEnabled) private var longBufferEnabled

    /// Shown as a button on long buffers when extended replay is off. Nil
    /// leaves just the text, for places that can't navigate to Settings.
    var openExtendedReplaySettings: (() -> Void)?

    /// The Memory cap slider lives in Advanced settings. With that feature
    /// switched off the cap in force is the default, whatever is stored, so
    /// that is what the estimate has to be made against.
    private var canChangeMemoryCap: Bool {
        enabledFeatureModules.contains(.systemAndFileTuning)
    }

    private var estimate: ReplayMemoryEstimate {
        ReplayMemoryEstimate.make(
            bufferSeconds: bufferDurationSeconds,
            bitrateMbps: bitrateMbps,
            isDualMode: captureMode == CaptureMode.dualSideBySide.rawValue,
            isSeparateDualSave: dualCaptureSaveMode == DualCaptureSaveMode.separateFiles.rawValue,
            captureSystemAudio: captureSystemAudio,
            captureMicrophone: captureMicrophone,
            memoryCapMB: canChangeMemoryCap ? memoryCapMB : Defaults.Keys.memoryCapMB.defaultValue
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
                ReplayMemoryCapWarning(
                    estimate: estimate,
                    raiseCap: canChangeMemoryCap ? { memoryCapMB = $0 } : nil
                )
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
    /// Nil where the cap cannot be changed (the Memory cap slider is hidden),
    /// so the warning points at bitrate and buffer length instead of offering
    /// a button that would store a value nothing reads.
    let raiseCap: ((Double) -> Void)?

    private var raiseTarget: Double? {
        raiseCap == nil ? nil : estimate.minimumCapMBToFit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if let target = raiseTarget, let raiseCap {
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
        if raiseTarget == nil {
            return "\(base) Lower the bitrate or the buffer length to fit."
        }
        return base
    }
}
