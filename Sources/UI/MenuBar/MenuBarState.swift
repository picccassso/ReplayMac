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
    @Published public private(set) var recordingElapsedSeconds: TimeInterval = 0
    @Published public private(set) var extendedBufferElapsedSeconds: TimeInterval = 0
    @Published public private(set) var bufferedSeconds: TimeInterval = 0
    @Published public private(set) var bufferMemoryBytes: Int = 0
    @Published public private(set) var availableUpdate: AvailableUpdate?

    private var saveStatusResetTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var extendedBufferStartedAt: Date?

    public init() {}

    public var isSaveInProgress: Bool {
        saveStatus == .saving
    }

    public func setRecording(_ isRecording: Bool, at date: Date = Date()) {
        if isRecording && !self.isRecording {
            recordingStartedAt = date
            recordingElapsedSeconds = 0
        } else if !isRecording {
            recordingStartedAt = nil
            recordingElapsedSeconds = 0
        }
        self.isRecording = isRecording
    }

    public func updateRecordingElapsed(at date: Date = Date()) {
        guard isRecording, let recordingStartedAt else {
            return
        }
        recordingElapsedSeconds = max(0, date.timeIntervalSince(recordingStartedAt))
        if let extendedBufferStartedAt {
            extendedBufferElapsedSeconds = max(0, date.timeIntervalSince(extendedBufferStartedAt))
        }
    }

    public func setExtendedBufferRecording(_ isRecording: Bool, at date: Date = Date()) {
        if isRecording && extendedBufferStartedAt == nil {
            extendedBufferStartedAt = date
            extendedBufferElapsedSeconds = 0
        } else if !isRecording {
            extendedBufferStartedAt = nil
            extendedBufferElapsedSeconds = 0
        }
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
        Self.formattedDuration(bufferedSeconds)
    }

    public var formattedRecordingDuration: String {
        Self.formattedDuration(recordingElapsedSeconds)
    }

    public var formattedExtendedBufferDuration: String {
        Self.formattedDuration(extendedBufferElapsedSeconds)
    }

    public static func formattedDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
