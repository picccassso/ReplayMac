import SwiftUI

/// A compact, two-handle timeline for choosing a clip range.
///
/// SwiftUI does not provide a native range slider on macOS. Keeping the two
/// endpoints on one track makes the selected portion of the clip immediately
/// visible and avoids presenting Start and End as unrelated settings.
struct TrimRangeSelector: View {
    @Binding var start: Double
    @Binding var end: Double

    let bounds: ClosedRange<Double>
    var minimumSelection: Double = 0.1
    var step: Double = 0.1
    var onSeek: (Double) -> Void = { _ in }
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var activeHandle: Handle?

    private enum Handle {
        case start
        case end
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let metrics = TrackMetrics(width: proxy.size.width, bounds: bounds)

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.28))
                        .frame(height: 4)
                        .padding(.horizontal, metrics.thumbInset)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.accent, AppTheme.accentSecondary],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, metrics.x(for: end) - metrics.x(for: start)), height: 4)
                        .offset(x: metrics.x(for: start))

                    trimHandle(isActive: activeHandle == .start)
                        .position(x: metrics.x(for: start), y: proxy.size.height / 2)

                    trimHandle(isActive: activeHandle == .end)
                        .position(x: metrics.x(for: end), y: proxy.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(metrics: metrics))
            }
            .frame(height: 24)

            HStack(alignment: .firstTextBaseline) {
                endpointLabel("Start", time: start, alignment: .leading)

                Spacer(minLength: 12)

                VStack(spacing: 1) {
                    Text("Selected")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(Self.timeLabel(max(0, end - start)))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Selected duration")

                Spacer(minLength: 12)

                endpointLabel("End", time: end, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trim range")
    }

    private func trimHandle(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            // `primary` is deliberately adaptive: white/light grey in dark
            // mode and dark grey in light mode, keeping the handle opposite
            // the surrounding system background in either appearance.
            .fill(Color.primary.opacity(isActive ? 0.98 : 0.82))
            .frame(width: TrackMetrics.thumbWidth, height: isActive ? 22 : 19)
            .overlay {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(Color(nsColor: .controlBackgroundColor).opacity(0.7), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(isActive ? 0.25 : 0.14), radius: isActive ? 3 : 2, y: 1)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private func endpointLabel(
        _ title: String,
        time: Double,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
            Text(Self.timeLabel(time))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(width: 68, alignment: alignment == .leading ? .leading : .trailing)
        .accessibilityElement(children: .combine)
    }

    private func dragGesture(metrics: TrackMetrics) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeHandle == nil {
                    activeHandle = metrics.nearestHandle(
                        to: value.startLocation.x,
                        start: start,
                        end: end
                    )
                    onEditingChanged(true)
                }

                let proposed = metrics.value(at: value.location.x, step: step)
                switch activeHandle {
                case .start:
                    let newValue = TrimRangeMath.clampedStart(
                        proposed,
                        end: end,
                        bounds: bounds,
                        minimumSelection: minimumSelection
                    )
                    guard newValue != start else { return }
                    start = newValue
                    onSeek(newValue)
                case .end:
                    let newValue = TrimRangeMath.clampedEnd(
                        proposed,
                        start: start,
                        bounds: bounds,
                        minimumSelection: minimumSelection
                    )
                    guard newValue != end else { return }
                    end = newValue
                    onSeek(newValue)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                activeHandle = nil
                onEditingChanged(false)
            }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let totalTenths = Int((safeSeconds * 10).rounded())
        let minutes = totalTenths / 600
        let wholeSeconds = (totalTenths / 10) % 60
        let tenths = totalTenths % 10
        return String(format: "%02d:%02d.%d", minutes, wholeSeconds, tenths)
    }

    private struct TrackMetrics {
        static let thumbWidth: CGFloat = 10

        let width: CGFloat
        let bounds: ClosedRange<Double>

        var thumbInset: CGFloat { Self.thumbWidth / 2 }
        var usableWidth: CGFloat { max(1, width - Self.thumbWidth) }
        var span: Double { max(0, bounds.upperBound - bounds.lowerBound) }

        func x(for value: Double) -> CGFloat {
            guard span > 0 else { return thumbInset }
            let progress = (value - bounds.lowerBound) / span
            return thumbInset + CGFloat(min(max(progress, 0), 1)) * usableWidth
        }

        func value(at x: CGFloat, step: Double) -> Double {
            guard span > 0 else { return bounds.lowerBound }
            let progress = Double(min(max((x - thumbInset) / usableWidth, 0), 1))
            let rawValue = bounds.lowerBound + progress * span
            guard step > 0 else { return rawValue }
            return min(max((rawValue / step).rounded() * step, bounds.lowerBound), bounds.upperBound)
        }

        func nearestHandle(to x: CGFloat, start: Double, end: Double) -> Handle {
            abs(x - self.x(for: start)) <= abs(x - self.x(for: end)) ? .start : .end
        }
    }
}

enum TrimRangeMath {
    static func clampedStart(
        _ proposed: Double,
        end: Double,
        bounds: ClosedRange<Double>,
        minimumSelection: Double
    ) -> Double {
        let gap = min(max(0, minimumSelection), max(0, bounds.upperBound - bounds.lowerBound))
        return min(max(proposed, bounds.lowerBound), max(bounds.lowerBound, end - gap))
    }

    static func clampedEnd(
        _ proposed: Double,
        start: Double,
        bounds: ClosedRange<Double>,
        minimumSelection: Double
    ) -> Double {
        let gap = min(max(0, minimumSelection), max(0, bounds.upperBound - bounds.lowerBound))
        return max(min(proposed, bounds.upperBound), min(bounds.upperBound, start + gap))
    }
}
