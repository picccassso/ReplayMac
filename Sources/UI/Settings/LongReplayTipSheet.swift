import SwiftUI
import Defaults

extension View {
    /// Offers extended replay when the replay buffer stepper reaches its
    /// 5 minute maximum, since that much footage in RAM is heavy.
    func longReplayTip() -> some View {
        modifier(LongReplayTipModifier())
    }
}

private struct LongReplayTipModifier: ViewModifier {
    static let triggerSeconds = 300

    @Default(.bufferDurationSeconds) private var bufferDurationSeconds
    @Default(.longBufferEnabled) private var longBufferEnabled
    @Default(.longReplayTipDismissed) private var longReplayTipDismissed
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: bufferDurationSeconds) { oldValue, newValue in
                guard oldValue < Self.triggerSeconds,
                      newValue >= Self.triggerSeconds,
                      !longBufferEnabled,
                      !longReplayTipDismissed else { return }
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                LongReplayTipSheet()
            }
    }
}

struct LongReplayTipSheet: View {
    static let reducedBufferSeconds = 60

    @Default(.bufferDurationSeconds) private var bufferDurationSeconds
    @Default(.longBufferEnabled) private var longBufferEnabled
    @Default(.longBufferWarningAccepted) private var longBufferWarningAccepted
    @Default(.longBufferDurationMinutes) private var longBufferDurationMinutes
    @Default(.longReplayTipDismissed) private var longReplayTipDismissed
    @Environment(\.dismiss) private var dismiss

    @State private var dontShowAgain = false
    @State private var didSwitch = false
    /// Captured when the sheet opens, before the buffer is changed.
    @State private var estimate = ReplayMemoryEstimate.current

    private var extendedDuration: String {
        (LongBufferDuration(rawValue: longBufferDurationMinutes) ?? .fiveMinutes).title
    }

    private var saveExtendedTitle: String {
        let seconds = (LongBufferDuration(rawValue: longBufferDurationMinutes) ?? .fiveMinutes).seconds
        return ReplayControlLabels.saveExtendedReplay(seconds: seconds).title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if didSwitch {
                confirmation
            } else {
                suggestion
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var suggestion: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: "memorychip", tint: .orange, title: "5 minutes is a lot to keep in RAM")

            Text("A 5 minute replay buffer holds about \(estimate.formattedRequired) in memory the whole time it runs, at \(Int(estimate.bitrateMbps)) Mbps.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Extended replay keeps 5, 10, or 30 minutes on disk instead. Turning it on also sets the replay buffer back to \(Self.reducedBufferSeconds) seconds, so quick clips stay light on memory.")
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Don't show this again", isOn: $dontShowAgain)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Keep 5 Minutes") {
                    longReplayTipDismissed = dontShowAgain
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                // A plain push button: the main window's accent tint carries
                // into sheets and would colour a glass button like the default.

                Button("Use Extended Replay") {
                    longReplayTipDismissed = dontShowAgain
                    longBufferWarningAccepted = true
                    longBufferEnabled = true
                    bufferDurationSeconds = Self.reducedBufferSeconds
                    withAnimation(.easeInOut(duration: 0.2)) { didSwitch = true }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(AccentButtonStyle())
            }
            .controlSize(.large)
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: "checkmark.circle.fill", tint: AppTheme.success, title: "Extended replay is on")

            Text("Your replay buffer has now been changed to \(Self.reducedBufferSeconds) seconds.")
                .fixedSize(horizontal: false, vertical: true)

            Text("To save the last \(extendedDuration), use the Save extended replay hotkey (set it in Settings → Hotkeys) or the \(saveExtendedTitle) item in the menu bar. You can change the length in Settings → Video.")
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AccentButtonStyle())
            }
            .controlSize(.large)
        }
    }

    private func header(icon: String, tint: Color, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
    }
}
