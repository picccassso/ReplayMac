import SwiftUI
import Defaults

/// Tinted zone drawn behind the Bitrate slider over the sweet spot range.
struct BitrateSweetSpotBand: View {
    let sweetSpot: ClosedRange<Double>
    var sliderRange: ClosedRange<Double> = BitrateGuide.sliderRange
    /// Distance from each end of the slider to the knob centre at its limits.
    var knobInset: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let span = sliderRange.upperBound - sliderRange.lowerBound
            let usable = max(geometry.size.width - knobInset * 2, 0)
            let start = knobInset + usable * (sweetSpot.lowerBound - sliderRange.lowerBound) / span
            let end = knobInset + usable * (sweetSpot.upperBound - sliderRange.lowerBound) / span
            // A one-value sweet spot still gets a visible marker.
            let width = max(end - start, 10)
            let centre = min(max((start + end) / 2, width / 2), geometry.size.width - width / 2)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppTheme.success.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AppTheme.success.opacity(0.35), lineWidth: 1)
                )
                .frame(width: width, height: 16)
                .position(x: centre, y: geometry.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One line saying whether a bitrate is below, in, or above the sweet spot.
struct BitrateZoneLabel: View {
    let guide: BitrateGuide
    let bitrateMbps: Double

    var body: some View {
        let zone = guide.zone(for: bitrateMbps)
        Label(guide.message(for: bitrateMbps), systemImage: icon(zone))
            .foregroundStyle(zone == .low ? Color.orange : AppTheme.textSecondary)
            .font(.system(size: 12, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func icon(_ zone: BitrateGuide.Zone) -> String {
        switch zone {
        case .low:
            return "exclamationmark.triangle"
        case .sweetSpot:
            return "checkmark.circle"
        case .high:
            return "arrow.up.circle"
        }
    }
}

/// What a bitrate costs: disk per minute of video, and RAM for the replay
/// buffer as it is set up now. Takes the live slider value so it updates
/// while dragging.
struct BitrateCostHint: View {
    let bitrateMbps: Double

    @Default(.bufferDurationSeconds) private var bufferDurationSeconds
    @Default(.captureMode) private var captureMode
    @Default(.dualCaptureSaveMode) private var dualCaptureSaveMode
    @Default(.captureSystemAudio) private var captureSystemAudio
    @Default(.captureMicrophone) private var captureMicrophone
    @Default(.memoryCapMB) private var memoryCapMB

    var body: some View {
        Label(text, systemImage: "internaldrive")
            .foregroundStyle(AppTheme.textSecondary)
            .font(.system(size: 12, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        let perMinute = ReplayMemoryEstimate.formatBytes(BitrateGuide.bytesPerMinute(bitrateMbps))
        let estimate = ReplayMemoryEstimate.make(
            bufferSeconds: bufferDurationSeconds,
            bitrateMbps: bitrateMbps,
            isDualMode: captureMode == CaptureMode.dualSideBySide.rawValue,
            isSeparateDualSave: dualCaptureSaveMode == DualCaptureSaveMode.separateFiles.rawValue,
            captureSystemAudio: captureSystemAudio,
            captureMicrophone: captureMicrophone,
            memoryCapMB: memoryCapMB
        )
        let buffer = ReplayMemoryEstimate.formatDuration(bufferDurationSeconds)
        return "About \(perMinute) per minute of video. Your \(buffer) buffer keeps about \(estimate.formattedRequired) in memory."
    }
}
