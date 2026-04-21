import Foundation
import KeyboardShortcuts

@MainActor
public final class HotkeyManager: @unchecked Sendable {
    public enum Action: Sendable {
        case saveConfigured
        case toggleRecording
        case saveLast15Seconds
        case saveLast60Seconds
    }

    public var onSaveClip: (() -> Void)?
    public var onToggleRecording: (() -> Void)?
    public var onSaveLast15Seconds: (() -> Void)?
    public var onSaveLast60Seconds: (() -> Void)?
    public var onAction: ((Action) -> Void)?

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
            self?.onAction?(.saveConfigured)
            self?.onSaveClip?()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.onAction?(.toggleRecording)
            self?.onToggleRecording?()
        }
        KeyboardShortcuts.onKeyUp(for: .saveLast15Seconds) { [weak self] in
            self?.onAction?(.saveLast15Seconds)
            self?.onSaveLast15Seconds?()
        }
        KeyboardShortcuts.onKeyUp(for: .saveLast60Seconds) { [weak self] in
            self?.onAction?(.saveLast60Seconds)
            self?.onSaveLast60Seconds?()
        }
    }

    public var hasAnySaveHotkeyConfigured: Bool {
        KeyboardShortcuts.getShortcut(for: .saveClip) != nil
            || KeyboardShortcuts.getShortcut(for: .saveLast15Seconds) != nil
            || KeyboardShortcuts.getShortcut(for: .saveLast60Seconds) != nil
    }
}
