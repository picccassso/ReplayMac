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
    var editableTimes = false

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

            HStack(alignment: .top) {
                if editableTimes {
                    TrimTimeField(title: "Start", value: $start, clamped: {
                        TrimRangeMath.clampedStart($0, end: end, bounds: bounds,
                                                   minimumSelection: minimumSelection)
                    }, onSeek: onSeek, onEditingChanged: onEditingChanged)
                } else {
                    endpointLabel("Start", time: start, alignment: .leading)
                }

                Spacer(minLength: 12)

                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Selected")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.textSecondary)
                            .accessibilityHidden(true)
                        if editableTimes {
                            TrimHelpButton(text: "Drag either handle or type the Start and End times. Enter seconds, minutes:seconds, or hours:minutes:seconds, with optional tenths. Use the arrows to adjust by 0.1 second. The player loops your selection when you finish editing.")
                        }
                    }
                    Text(Self.timeLabel(max(0, end - start)))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityLabel("Selected duration")
                        .accessibilityValue(Self.timeLabel(max(0, end - start)))
                }
                .accessibilityElement(children: .contain)

                Spacer(minLength: 12)

                if editableTimes {
                    TrimTimeField(title: "End", value: $end, alignment: .trailing, clamped: {
                        TrimRangeMath.clampedEnd($0, start: start, bounds: bounds,
                                                 minimumSelection: minimumSelection)
                    }, onSeek: onSeek, onEditingChanged: onEditingChanged)
                } else {
                    endpointLabel("End", time: end, alignment: .trailing)
                }
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
        TrimTime.label(seconds)
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

private struct TrimTimeField: View {
    let title: String
    @Binding var value: Double
    var alignment: HorizontalAlignment = .leading
    let clamped: (Double) -> Double
    let onSeek: (Double) -> Void
    let onEditingChanged: (Bool) -> Void
    @State private var draft = ""
    @State private var invalid = false
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 94, alignment: alignment == .trailing ? .trailing : .leading)
            HStack(spacing: 4) {
                TrimEndpointInput(title: "Trim \(title.lowercased()) time", text: $draft,
                                  alignment: alignment == .trailing ? .right : .left,
                                  onEditingChanged: { editing in
                                      focused = editing
                                      if editing {
                                          invalid = false
                                          onEditingChanged(true)
                                      } else {
                                          commit()
                                          onEditingChanged(false)
                                      }
                                  }, onEscape: {
                                      draft = TrimTime.label(value)
                                      invalid = false
                                  }, onAdjust: adjust)
                    .frame(width: 94, height: 22)
                    .help("Seconds or colon-separated time; up and down adjust by 0.1 second")
                Stepper(title, onIncrement: { adjust(0.1) }, onDecrement: { adjust(-0.1) })
                    .labelsHidden()
                    .controlSize(.mini)
                    .accessibilityLabel("Adjust trim \(title.lowercased()) by 0.1 second")
            }
            if invalid {
                Text("Enter a valid time")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Invalid \(title.lowercased()) time. Enter seconds or colon-separated time.")
            }
        }
        .onAppear { draft = TrimTime.label(value) }
        .onChange(of: value) { _, newValue in
            if !focused { draft = TrimTime.label(newValue) }
        }
    }

    private func commit() {
        guard let parsed = TrimTime.parse(draft) else {
            draft = TrimTime.label(value)
            invalid = true
            return
        }
        value = clamped(parsed)
        draft = TrimTime.label(value)
        onSeek(value)
    }

    private func adjust(_ delta: Double) {
        if !focused { onEditingChanged(true) }
        let base = TrimTime.parse(draft) ?? value
        value = clamped(((base + delta) * 10).rounded() / 10)
        draft = TrimTime.label(value)
        invalid = false
        onSeek(value)
        if !focused { onEditingChanged(false) }
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

/// NSTextField's field editor consumes arrow keys before SwiftUI move commands.
/// Handle them through its delegate so keyboard and stepper edits use the same rules.
private struct TrimEndpointInput: NSViewRepresentable {
    let title: String
    @Binding var text: String
    var alignment: NSTextAlignment = .left
    let onEditingChanged: (Bool) -> Void
    let onEscape: () -> Void
    let onAdjust: (Double) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.setAccessibilityLabel(title)
        field.setAccessibilityHelp("Seconds or colon-separated time; up and down adjust by 0.1 second")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.alignment = alignment
        field.isEnabled = isEnabled
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TrimEndpointInput
        init(_ parent: TrimEndpointInput) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onEditingChanged(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onEditingChanged(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch NSStringFromSelector(command) {
            case "moveUp:":
                parent.onAdjust(0.1)
            case "moveDown:":
                parent.onAdjust(-0.1)
            case "insertNewline:":
                control.window?.makeFirstResponder(nil)
            case "cancelOperation:":
                parent.onEscape()
                textView.string = parent.text
                control.window?.makeFirstResponder(nil)
            default:
                return false
            }
            return true
        }
    }
}
