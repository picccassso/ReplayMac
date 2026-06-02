import Foundation
import SwiftUI

public enum SaveStatus: Equatable {
    case idle
    case saving
    case saved
    case failed
}

@MainActor
public final class MenuBarState: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var saveStatus: SaveStatus = .idle
    @Published public private(set) var bufferedSeconds: TimeInterval = 0
    @Published public private(set) var bufferMemoryBytes: Int = 0
    @Published public private(set) var availableUpdate: AvailableUpdate?

    private var saveStatusResetTask: Task<Void, Never>?

    public init() {}

    public var isSaveInProgress: Bool {
        saveStatus == .saving
    }

    public func setRecording(_ isRecording: Bool) {
        self.isRecording = isRecording
    }

    public func setBufferedSeconds(_ bufferedSeconds: TimeInterval) {
        self.bufferedSeconds = max(0, bufferedSeconds)
    }

    public func setBufferMemoryBytes(_ bytes: Int) {
        bufferMemoryBytes = max(0, bytes)
    }

    public func setAvailableUpdate(_ update: AvailableUpdate?) {
        availableUpdate = update
    }

    @discardableResult
    public func beginSaving() -> Bool {
        guard saveStatus != .saving else {
            return false
        }

        saveStatusResetTask?.cancel()
        saveStatus = .saving
        return true
    }

    public func finishSaving(success: Bool) {
        saveStatusResetTask?.cancel()
        saveStatus = success ? .saved : .failed

        saveStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveStatus = .idle
        }
    }

    public func showSaveFailedBriefly() {
        saveStatusResetTask?.cancel()
        saveStatus = .failed

        saveStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveStatus = .idle
        }
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

    public static func formattedDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded(.down))
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}
