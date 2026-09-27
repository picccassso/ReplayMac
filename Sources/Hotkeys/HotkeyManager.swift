import Foundation
import KeyboardShortcuts

@MainActor
public final class HotkeyManager: @unchecked Sendable {
    public var onSaveClip: (() -> Void)?
    public var onToggleRecording: (() -> Void)?
    public var onSaveLast15Seconds: (() -> Void)?
    public var onSaveLast60Seconds: (() -> Void)?
    public var onSaveLongBuffer: (() -> Void)?
    public var onToggleSessionRecording: (() -> Void)?
    public var onOpenClipLibrary: (() -> Void)?

    private var isStarted = false

    public init() {}

    // KeyboardShortcuts 3 is main-actor isolated. The manager is owned by
    // AppDelegate, so its last release always happens on the main thread.
    deinit {
        MainActor.assumeIsolated {
            KeyboardShortcuts.removeHandler(for: .saveClip)
            KeyboardShortcuts.removeHandler(for: .toggleRecording)
            KeyboardShortcuts.removeHandler(for: .saveLast15Seconds)
            KeyboardShortcuts.removeHandler(for: .saveLast60Seconds)
            KeyboardShortcuts.removeHandler(for: .saveLongBuffer)
            KeyboardShortcuts.removeHandler(for: .toggleSessionRecording)
            KeyboardShortcuts.removeHandler(for: .openClipLibrary)
        }
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
        KeyboardShortcuts.onKeyUp(for: .saveLongBuffer) { [weak self] in
            self?.onSaveLongBuffer?()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleSessionRecording) { [weak self] in
            self?.onToggleSessionRecording?()
        }
        KeyboardShortcuts.onKeyUp(for: .openClipLibrary) { [weak self] in
            self?.onOpenClipLibrary?()
        }
    }
}
