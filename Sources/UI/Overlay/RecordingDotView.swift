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
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Clip saved")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .frame(width: 200, height: 32, alignment: .leading)
                .background(.black.opacity(0.7), in: Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if model.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                    .shadow(color: .red.opacity(0.5), radius: 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.showSavedToast)
        .animation(.easeOut(duration: 0.18), value: model.isRecording)
    }
}
