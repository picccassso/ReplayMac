import Foundation

/// The primary capture actions, shared by the menu bar menu and the Home page.
/// Each action defaults to a no-op so previews and tests need no wiring.
public struct ReplayControls {
    public var saveReplay: () -> Void
    public var saveExtendedReplay: () -> Void
    public var toggleSession: () -> Void
    public var toggleBuffer: () -> Void
    public var toggleMicrophone: () -> Void
    public var toggleSystemAudio: () -> Void

    public init(saveReplay: @escaping () -> Void = {},
                saveExtendedReplay: @escaping () -> Void = {},
                toggleSession: @escaping () -> Void = {},
                toggleBuffer: @escaping () -> Void = {},
                toggleMicrophone: @escaping () -> Void = {},
                toggleSystemAudio: @escaping () -> Void = {}) {
        self.saveReplay = saveReplay
        self.saveExtendedReplay = saveExtendedReplay
        self.toggleSession = toggleSession
        self.toggleBuffer = toggleBuffer
        self.toggleMicrophone = toggleMicrophone
        self.toggleSystemAudio = toggleSystemAudio
    }
}

public struct ReplayControlLabel: Equatable {
    public let title: String
    public let symbol: String
    public let accessibilityDescription: String
}

/// Wording and symbols shared by the menu bar menu and the Home page, so both
/// always describe the same state the same way.
@MainActor
public enum ReplayControlLabels {
    public static func saveReplay(seconds: Int) -> ReplayControlLabel {
        ReplayControlLabel(title: "Save Last \(seconds) Seconds", symbol: "arrow.down.circle.fill",
                           accessibilityDescription: "Save replay")
    }

    public static func saveExtendedReplay(seconds: Int) -> ReplayControlLabel {
        ReplayControlLabel(title: "Save Last \(MenuBarState.formattedDuration(TimeInterval(seconds)))",
                           symbol: "clock.arrow.circlepath", accessibilityDescription: "Save extended replay")
    }

    public static func session(isRecording: Bool) -> ReplayControlLabel {
        isRecording
            ? ReplayControlLabel(title: "Stop & Save Session", symbol: "stop.circle.fill",
                                 accessibilityDescription: "Session recording active")
            : ReplayControlLabel(title: "Start Session Recording", symbol: "record.circle",
                                 accessibilityDescription: "Session recording stopped")
    }

    public static func replayBuffer(isRecording: Bool) -> ReplayControlLabel {
        isRecording
            ? ReplayControlLabel(title: "Stop Replay Buffer", symbol: "pause.circle.fill",
                                 accessibilityDescription: "Replay buffer running")
            : ReplayControlLabel(title: "Start Replay Buffer", symbol: "play.circle.fill",
                                 accessibilityDescription: "Replay buffer stopped")
    }

    public static func microphone(isEnabled: Bool, isMuted: Bool) -> ReplayControlLabel {
        if !isEnabled {
            return ReplayControlLabel(title: "Enable & Unmute Microphone", symbol: "mic.slash",
                                      accessibilityDescription: "Microphone disabled")
        }
        return isMuted
            ? ReplayControlLabel(title: "Unmute Microphone", symbol: "mic.slash.fill",
                                 accessibilityDescription: "Microphone muted")
            : ReplayControlLabel(title: "Mute Microphone", symbol: "mic.fill",
                                 accessibilityDescription: "Microphone active")
    }

    public static func systemAudio(isEnabled: Bool, isMuted: Bool) -> ReplayControlLabel {
        if !isEnabled {
            return ReplayControlLabel(title: "Enable & Unmute System Audio", symbol: "speaker.slash",
                                      accessibilityDescription: "System audio disabled")
        }
        return isMuted
            ? ReplayControlLabel(title: "Unmute System Audio", symbol: "speaker.slash.fill",
                                 accessibilityDescription: "System audio muted")
            : ReplayControlLabel(title: "Mute System Audio", symbol: "speaker.wave.2.fill",
                                 accessibilityDescription: "System audio active")
    }

    /// A session recording that started capture on its own deliberately leaves
    /// the replay buffers empty, so reporting them would look like a fault.
    public static func isSessionOnlyCapture(isRecording: Bool, isSessionRecording: Bool) -> Bool {
        isSessionRecording && !isRecording
    }

    /// The buffer retains headroom beyond the replay window; never report more
    /// than the window the user can actually save.
    public static func quickReplayAvailable(bufferedSeconds: TimeInterval, capSeconds: Int) -> TimeInterval {
        min(bufferedSeconds, TimeInterval(capSeconds))
    }

    public static func fillSuffix(isRecording: Bool, available: TimeInterval, capSeconds: Int) -> String? {
        guard isRecording else { return nil }
        return available < TimeInterval(capSeconds) ? "filling…" : "ready"
    }

    public static func quickReplayLine(bufferedSeconds: TimeInterval, capSeconds: Int,
                                       memory: String, isRecording: Bool) -> String {
        let available = quickReplayAvailable(bufferedSeconds: bufferedSeconds, capSeconds: capSeconds)
        var line = "Quick replay: \(MenuBarState.formattedDuration(available)) / "
            + "\(MenuBarState.formattedDuration(TimeInterval(capSeconds))) · \(memory)"
        if let suffix = fillSuffix(isRecording: isRecording, available: available, capSeconds: capSeconds) {
            line += " (\(suffix))"
        }
        return line
    }

    public static func extendedReplayLine(elapsedSeconds: TimeInterval, capSeconds: Int,
                                          isRecording: Bool) -> String {
        let available = min(elapsedSeconds, TimeInterval(capSeconds))
        var line = "Extended replay: \(MenuBarState.formattedDuration(available)) / "
            + "\(MenuBarState.formattedDuration(TimeInterval(capSeconds)))"
        if let suffix = fillSuffix(isRecording: isRecording, available: available, capSeconds: capSeconds) {
            line += " (\(suffix))"
        }
        return line
    }
}
