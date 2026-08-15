import Foundation

/// Decides whether a silent microphone has earned another engine rebuild.
///
/// Kept free of clocks and engine state so the rules can be tested directly.
enum MicrophoneStallPolicy {
    enum Decision: Equatable {
        /// Healthy, still inside its grace period, or not something a rebuild
        /// can fix.
        case wait
        /// Rebuild the engine.
        case rebuild
        /// Out of recovery budget — the device is not coming back on its own.
        case giveUp
    }

    /// - Parameters:
    ///   - referenceUptime: the freshest evidence the mic is alive — the last
    ///     delivered sample, or the moment the engine came up, whichever is
    ///     later. Zero means the engine has never been started.
    ///   - recoveriesUsed: rebuilds since the last delivered sample.
    static func decide(
        isRunning: Bool,
        isSessionActive: Bool,
        now: TimeInterval,
        referenceUptime: TimeInterval,
        timeout: TimeInterval,
        recoveriesUsed: Int,
        maximumRecoveries: Int
    ) -> Decision {
        guard isRunning, isSessionActive, timeout > 0, referenceUptime > 0 else {
            return .wait
        }
        guard now - referenceUptime >= timeout else {
            return .wait
        }
        guard recoveriesUsed < maximumRecoveries else {
            return .giveUp
        }
        return .rebuild
    }
}
