import SwiftUI

@MainActor
public final class RecordingDotModel: ObservableObject {
    @Published public var isRecording = false
    @Published public var showSavedToast = false

    public init() {}

    public func flashSavedToast() {
        showSavedToast = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.showSavedToast = false
        }
    }
}

public struct RecordingDotView: View {
    @ObservedObject private var model: RecordingDotModel

    public init(model: RecordingDotModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.showSavedToast {
                savedToast
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else if model.isRecording {
                recordingDot
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showSavedToast)
        .animation(.easeOut(duration: 0.2), value: model.isRecording)
    }

    private var savedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.accent)
                .font(.system(size: 14, weight: .semibold))
            Text("Clip saved")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.horizontal, 14)
        .frame(width: 200, height: 36, alignment: .leading)
        .background(
            .ultraThinMaterial,
            in: Capsule()
        )
        .overlay(
            Capsule()
                .stroke(AppTheme.accent.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: AppTheme.accent.opacity(0.2), radius: 6, x: 0, y: 3)
    }

    private var recordingDot: some View {
        ZStack {
            Circle()
                .fill(AppTheme.danger.opacity(0.25))
                .frame(width: 20, height: 20)
                .scaleEffect(model.isRecording ? 1.4 : 1.0)
                .opacity(model.isRecording ? 0.0 : 0.4)
                .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: model.isRecording)

            Circle()
                .fill(AppTheme.danger)
                .frame(width: 12, height: 12)
                .shadow(color: AppTheme.danger.opacity(0.5), radius: 4)
        }
    }
}
