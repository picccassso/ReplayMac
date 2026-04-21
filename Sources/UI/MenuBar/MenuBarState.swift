import Foundation
import SwiftUI

@MainActor
public final class MenuBarState: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var bufferedSeconds: TimeInterval = 0
    @Published public private(set) var bufferMemoryBytes: Int = 0
    @Published public private(set) var transientNotice: String?
    @Published public private(set) var lastSavedDate: Date?

    public init() {}

    public func setRecording(_ isRecording: Bool) {
        self.isRecording = isRecording
    }

    public func setBufferedSeconds(_ bufferedSeconds: TimeInterval) {
        self.bufferedSeconds = max(0, bufferedSeconds)
    }

    public func flashSavedState() {
        lastSavedDate = Date()
        isSaving = true
        transientNotice = nil

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.isSaving = false
        }
    }

    public func setBufferMemoryBytes(_ bytes: Int) {
        bufferMemoryBytes = max(0, bytes)
    }

    public func showNotice(_ message: String) {
        transientNotice = message
    }

    public var formattedBufferMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(bufferMemoryBytes), countStyle: .file)
    }

    public var formattedBufferDuration: String {
        let totalSeconds = Int(bufferedSeconds.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var statusText: String {
        if isSaving {
            return "Saved"
        }

        if isRecording {
            return "Buffering \(formattedBufferDuration)"
        }

        if let transientNotice {
            return transientNotice
        }

        return "Idle"
    }
}
