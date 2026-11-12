import Foundation

/// How hard macOS is squeezing memory across the whole system, as reported by
/// its memory-pressure notifications.
public enum MemoryPressureLevel: Equatable, Sendable {
    case normal
    case warning
    case critical
}

/// What the replay buffer gives up when the Mac runs short of memory.
///
/// The buffer holds its whole window in RAM, which on an 8 GB Mac running a
/// game is memory the system may badly need back. Only critical pressure
/// shrinks it: warnings are routine on a small Mac under load, and cutting
/// every clip short for them would cost more than it saves.
public enum MemoryPressurePolicy {
    /// Shortest window kept under critical pressure, so a save still has
    /// something worth keeping.
    public static let minimumReplaySeconds = 10

    /// Seconds of replay to keep at `level` when the user asked for `configured`.
    public static func replaySeconds(configured: Int, level: MemoryPressureLevel) -> Int {
        guard level == .critical else { return configured }
        return min(configured, max(minimumReplaySeconds, configured / 2))
    }
}
