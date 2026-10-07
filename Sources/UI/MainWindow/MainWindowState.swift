import AppKit
import Combine
import SwiftUI

public extension Notification.Name {
    static let replayCapLibraryShouldReload = Notification.Name("replayCapLibraryShouldReload")
}

public enum MainWindowPage: String, CaseIterable, Identifiable {
    case library, general, video, audio, profiles, hotkeys, advanced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .library: "Clip Library"
        case .general: "General"
        case .video: "Video"
        case .audio: "Audio"
        case .profiles: "Profiles"
        case .hotkeys: "Hotkeys"
        case .advanced: "Advanced"
        }
    }
    var icon: String {
        switch self {
        case .library: "film.stack"
        case .general: "gearshape"
        case .video: "video"
        case .audio: "speaker.wave.2"
        case .profiles: "rectangle.stack.badge.play"
        case .hotkeys: "keyboard"
        case .advanced: "slider.horizontal.3"
        }
    }
}

@MainActor
public final class MainWindowState: ObservableObject {
    @Published public private(set) var page: MainWindowPage
    /// Open Trim & Export sessions, one per clip, each shown in its own window.
    @Published private(set) var editors: [URL: ClipEditorSession] = [:]
    @Published public var isWindowVisible = false
    @Published var hasVisitedSettings: Bool
    @Published var settingsTab: SettingsTab = .general
    public let exports = ClipExportCoordinator()
    let library: ClipLibraryState
    /// Brings a session's editor window forward. Tests leave it nil so no windows are created.
    var presentEditor: ((ClipEditorSession) -> Void)?
    private let defaults: UserDefaults
    private var subscriptions = Set<AnyCancellable>()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let restoredPage = MainWindowPage(rawValue: defaults.string(forKey: "mainWindowPage") ?? "") ?? .library
        page = restoredPage
        hasVisitedSettings = restoredPage != .library
        library = ClipLibraryState()
        if let tab = SettingsTab(rawValue: page.rawValue) { settingsTab = tab }
        exports.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        library.model.isProtected = { [weak self] url in self?.isProtected(url) ?? false }
        presentEditor = { [weak self] session in
            guard let self else { return }
            ClipEditorWindowController.show(session: session, state: self)
        }
    }

    public var isLibraryFrontmost: Bool { page == .library }

    /// Returns whether the caller should hide the native window. Otherwise the
    /// shortcut selects the library before the caller brings the window forward.
    public func routeLibraryShortcut(windowIsFrontmost: Bool) -> Bool {
        if windowIsFrontmost && isLibraryFrontmost {
            windowDidHide()
            return true
        }
        select(.library)
        return false
    }

    public func select(_ page: MainWindowPage) {
        self.page = page
        defaults.set(page.rawValue, forKey: "mainWindowPage")
        if let tab = SettingsTab(rawValue: page.rawValue) {
            hasVisitedSettings = true
            settingsTab = tab
        }
    }

    func openEditor(_ url: URL) {
        let source = url.standardizedFileURL
        let session = editors[source] ?? ClipEditorSession(url: source, exports: exports)
        editors[source] = session
        presentEditor?(session)
    }

    /// Ends the edit. A running export keeps going; the coordinator owns it.
    func closeEditor(_ url: URL) {
        editors.removeValue(forKey: url.standardizedFileURL)?.dispose()
    }

    func isProtected(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        return editors.keys.contains { $0.resolvingSymlinksInPath() == key }
            || exports.sourceURL?.resolvingSymlinksInPath() == key
    }

    public func windowDidHide() {
        isWindowVisible = false
    }
}
