import Foundation
import KeyboardShortcuts

@MainActor
public final class HotkeyManager: @unchecked Sendable {
    public var onSaveClip: (() -> Void)?
    public var onToggleRecording: (() -> Void)?
    public var onSaveLast15Seconds: (() -> Void)?
    public var onSaveLast60Seconds: (() -> Void)?

    private var isStarted = false

    public init() {}

    deinit {
        KeyboardShortcuts.removeHandler(for: .saveClip)
        KeyboardShortcuts.removeHandler(for: .toggleRecording)
        KeyboardShortcuts.removeHandler(for: .saveLast15Seconds)
        KeyboardShortcuts.removeHandler(for: .saveLast60Seconds)
    }

    public func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        KeyboardShortcuts.onKeyUp(for: .saveClip) { [weak self] in
            self?.onSaveClip?()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.onToggleRecording?()
        }
        KeyboardShortcuts.onKeyUp(for: .saveLast15Seconds) { [weak self] in
            self?.onSaveLast15Seconds?()
        }
        KeyboardShortcuts.onKeyUp(for: .saveLast60Seconds) { [weak self] in
            self?.onSaveLast60Seconds?()
        }
    }
}
