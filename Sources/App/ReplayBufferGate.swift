import Foundation

/// Whether encoded samples should be retained for replay saves.
///
/// A session recording needs the capture pipeline running, but not the replay
/// buffers: it writes its own segments and saves on stop. Starting a session
/// from idle used to fill the quick-replay ring buffers and — when extended
/// replay was on — write a second copy of the same video to disk, neither of
/// which the user asked for.
///
/// Read from encoder callbacks on capture threads, written from the main
/// actor, so access is lock-guarded.
final class ReplayBufferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        enabled = newValue
    }
}
