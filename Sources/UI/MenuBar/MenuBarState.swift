import Foundation
import SwiftUI

public enum SaveStatus: Equatable {
    case idle
    case saving
    case saved
    case bufferNotRunning
    case failed
}

@MainActor
public final class MenuBarState: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var isSessionRecording = false
    @Published public private(set) var saveStatus: SaveStatus = .idle
    @Published public private(set) var recordingElapsedSeconds: TimeInterval = 0
    @Published public private(set) var extendedBufferElapsedSeconds: TimeInterval = 0
    @Published public private(set) var sessionElapsedSeconds: TimeInterval = 0
    @Published public private(set) var bufferedSeconds: TimeInterval = 0
    @Published public private(set) var bufferMemoryBytes: Int = 0
    @Published public private(set) var availableUpdate: AvailableUpdate?
    @Published public private(set) var capturedDisplayName: String?
    @Published public private(set) var isUsingFallbackDisplay = false
    @Published public private(set) var isMicrophoneMuted = false
    @Published public private(set) var isSystemAudioMuted = false
    public var onSaveStatusChanged: (@MainActor () -> Void)?
    /// Fires when the buffer, session, captured display or mute state shown to the user changes.
    public var onDisplayedStateChanged: (@MainActor () -> Void)?

    private var saveStatusResetTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var extendedBufferStartedAt: Date?
    private var sessionStartedAt: Date?

    public init() {}

    public var isSaveInProgress: Bool {
        saveStatus == .saving
    }

    public var saveStatusString: String {
        switch saveStatus {
        case .idle: return "idle"
        case .saving: return "saving"
        case .saved: return "saved"
        case .bufferNotRunning, .failed: return "failed"
        }
    }

    public func setRecording(_ isRecording: Bool, at date: Date = Date()) {
        if isRecording && !self.isRecording {
            recordingStartedAt = date
            recordingElapsedSeconds = 0
        } else if !isRecording {
            recordingStartedAt = nil
            recordingElapsedSeconds = 0
        }
        if isRecording && saveStatus == .bufferNotRunning {
            saveStatusResetTask?.cancel()
            saveStatus = .idle
            onSaveStatusChanged?()
        }
        guard self.isRecording != isRecording else { return }
        self.isRecording = isRecording
        onDisplayedStateChanged?()
    }

    public func updateRecordingElapsed(at date: Date = Date()) {
        if isRecording, let recordingStartedAt {
            recordingElapsedSeconds = max(0, date.timeIntervalSince(recordingStartedAt))
        }
        if let extendedBufferStartedAt {
            extendedBufferElapsedSeconds = max(0, date.timeIntervalSince(extendedBufferStartedAt))
        }
        if isSessionRecording, let sessionStartedAt {
            sessionElapsedSeconds = max(0, date.timeIntervalSince(sessionStartedAt))
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

    public func setSessionRecording(_ isRecording: Bool, at date: Date = Date()) {
        if isRecording && !isSessionRecording {
            sessionStartedAt = date
            sessionElapsedSeconds = 0
        } else if !isRecording {
            sessionStartedAt = nil
            sessionElapsedSeconds = 0
        }
        guard isSessionRecording != isRecording else { return }
        isSessionRecording = isRecording
        onDisplayedStateChanged?()
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

    public func setCapturedDisplay(name: String?, isFallback: Bool = false) {
        guard capturedDisplayName != name || isUsingFallbackDisplay != isFallback else { return }
        capturedDisplayName = name
        isUsingFallbackDisplay = isFallback
        onDisplayedStateChanged?()
    }

    public func setAudioMuteState(isMicrophoneMuted: Bool, isSystemAudioMuted: Bool) {
        guard self.isMicrophoneMuted != isMicrophoneMuted || self.isSystemAudioMuted != isSystemAudioMuted else { return }
        self.isMicrophoneMuted = isMicrophoneMuted
        self.isSystemAudioMuted = isSystemAudioMuted
        onDisplayedStateChanged?()
    }

    @discardableResult
    public func beginSaving() -> Bool {
        guard saveStatus != .saving else {
            return false
        }

        saveStatusResetTask?.cancel()
        saveStatus = .saving
        onSaveStatusChanged?()
        return true
    }

    public func finishSaving(success: Bool) {
        saveStatusResetTask?.cancel()
        saveStatus = success ? .saved : .failed
        onSaveStatusChanged?()

        saveStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveStatus = .idle
            self?.onSaveStatusChanged?()
        }
    }

    public func showBufferNotRunningBriefly() {
        saveStatusResetTask?.cancel()
        saveStatus = .bufferNotRunning
        onSaveStatusChanged?()

        saveStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveStatus = .idle
            self?.onSaveStatusChanged?()
        }
    }

    public func showSaveFailedBriefly() {
        saveStatusResetTask?.cancel()
        saveStatus = .failed
        onSaveStatusChanged?()

        saveStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveStatus = .idle
            self?.onSaveStatusChanged?()
        }
    }

    public var formattedBufferMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(bufferMemoryBytes), countStyle: .file)
    }

    /// Recording time shown to the user, capped at the largest configured
    /// replay window — elapsed time beyond what can still be saved isn't
    /// actionable. Session recording shows uncapped elapsed time instead.
    public var displayedRecordingSeconds: TimeInterval {
        if isSessionRecording {
            return sessionElapsedSeconds
        }
        let quickCap = TimeInterval(AppSettings.bufferDurationSeconds)
        let cap = AppSettings.longBufferEnabled
            ? max(quickCap, TimeInterval(AppSettings.longBufferDurationSeconds))
            : quickCap
        return min(recordingElapsedSeconds, cap)
    }

    public var formattedRecordingDuration: String {
        Self.formattedDuration(displayedRecordingSeconds)
    }

    public var formattedExtendedBufferDuration: String {
        Self.formattedDuration(extendedBufferElapsedSeconds)
    }

    public var formattedSessionDuration: String {
        Self.formattedDuration(sessionElapsedSeconds)
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
