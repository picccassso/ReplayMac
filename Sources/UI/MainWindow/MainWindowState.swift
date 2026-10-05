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
    @Published var isEditing = false
    @Published var editor: ClipEditorSession?
    @Published var replacementCandidate: URL?
    @Published public var isWindowVisible = false
    @Published var hasVisitedSettings: Bool
    @Published var settingsTab: SettingsTab = .general
    @Published private var browsingSidebarVisible: Bool
    @Published private var editingSidebarVisible = false
    public let exports = ClipExportCoordinator()
    let library: ClipLibraryState
    private let defaults: UserDefaults
    private var subscriptions = Set<AnyCancellable>()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let restoredPage = MainWindowPage(rawValue: defaults.string(forKey: "mainWindowPage") ?? "") ?? .library
        page = restoredPage
        hasVisitedSettings = restoredPage != .library
        browsingSidebarVisible = defaults.object(forKey: "mainWindowSidebarVisible") as? Bool ?? true
        library = ClipLibraryState()
        if let tab = SettingsTab(rawValue: page.rawValue) { settingsTab = tab }
        exports.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        library.model.isProtected = { [weak self] url in self?.isProtected(url) ?? false }
    }

    var sidebarVisible: Bool { isEditing ? editingSidebarVisible : browsingSidebarVisible }
    public var isLibraryFrontmost: Bool { page == .library && !isEditing }

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
        editor?.pause()
        isEditing = false
        self.page = page
        defaults.set(page.rawValue, forKey: "mainWindowPage")
        if let tab = SettingsTab(rawValue: page.rawValue) {
            hasVisitedSettings = true
            settingsTab = tab
        }
    }

    func toggleSidebar() {
        if isEditing { editingSidebarVisible.toggle() }
        else {
            browsingSidebarVisible.toggle()
            defaults.set(browsingSidebarVisible, forKey: "mainWindowSidebarVisible")
        }
    }

    func openEditor(_ url: URL) {
        guard !exports.isBusy else { return }
        let source = url.standardizedFileURL
        if let editor, editor.url != source {
            replacementCandidate = source
            return
        }
        if editor == nil { editor = ClipEditorSession(url: source, exports: exports) }
        resumeEditor()
    }

    func replaceEditor() {
        guard !exports.isBusy, let url = replacementCandidate else { return }
        editor?.dispose()
        editor = nil
        replacementCandidate = nil
        openEditor(url)
    }

    func resumeEditor() {
        guard editor != nil else { return }
        page = .library
        defaults.set(MainWindowPage.library.rawValue, forKey: "mainWindowPage")
        editingSidebarVisible = false
        isEditing = true
    }

    func discardEditor() {
        guard !exports.isBusy else { return }
        editor?.dispose()
        editor = nil
        select(.library)
    }

    func isProtected(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        return editor?.url.resolvingSymlinksInPath() == key || exports.sourceURL?.resolvingSymlinksInPath() == key
    }

    public func windowDidHide() {
        isWindowVisible = false
        editor?.pause()
    }
}
