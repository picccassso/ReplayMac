import AppKit
import Combine
import Save
import SwiftUI

public extension Notification.Name {
    static let replayCapLibraryShouldReload = Notification.Name("replayCapLibraryShouldReload")
}

public enum MainWindowPage: String, CaseIterable, Identifiable {
    case home, library, general, video, audio, profiles, hotkeys, advanced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .home: "Home"
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
        case .home: "house"
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

/// The page the main window shows when it opens without a specific destination,
/// such as at launch or from the Dock. Set in Settings > General.
public enum MainWindowStartPage: String, CaseIterable, Identifiable {
    case home, library, lastViewed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .home: "Home"
        case .library: "Clip Library"
        case .lastViewed: "Last Viewed Page"
        }
    }
    /// Nil restores whichever page was open last.
    var page: MainWindowPage? {
        switch self {
        case .home: .home
        case .library: .library
        case .lastViewed: nil
        }
    }
}

@MainActor
public final class MainWindowState: ObservableObject {
    nonisolated public static let startPageKey = "mainWindowStartPage"
    @Published public private(set) var page: MainWindowPage
    /// Open Trim & Export sessions, one per clip, each shown in its own window.
    @Published private(set) var editors: [URL: ClipEditorSession] = [:]
    @Published public var isWindowVisible = false
    /// True until the window has opened for the first time, and whenever the
    /// window has been closed (ordered out), but false while minimized.
    @Published public var isWindowClosed = true
    /// The sidebar header drops its traffic-light inset in full screen.
    @Published public var isFullScreen = false
    @Published var hasVisitedSettings: Bool
    @Published var settingsTab: SettingsTab = .general
    public let exports = ClipExportCoordinator()
    /// Capture actions for the Home page, wired by the app delegate.
    public var controls = ReplayControls()
    /// Clips saved since launch, newest first. Deliberately never persisted,
    /// so Home's session history starts empty on every launch.
    @Published private(set) var recentClips: [RecentClip] = []
    static let recentClipLimit = 20
    let library: ClipLibraryState
    /// Brings a session's editor window forward. Tests leave it nil so no windows are created.
    var presentEditor: ((ClipEditorSession) -> Void)?
    private let defaults: UserDefaults
    private var subscriptions = Set<AnyCancellable>()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let startPage = MainWindowStartPage(rawValue: defaults.string(forKey: Self.startPageKey) ?? "") ?? .home
        let restoredPage = startPage.page
            ?? MainWindowPage(rawValue: defaults.string(forKey: "mainWindowPage") ?? "")
            ?? .home
        page = restoredPage
        hasVisitedSettings = SettingsTab(rawValue: restoredPage.rawValue) != nil
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

    /// The page to show when the window opens without a specific destination,
    /// or nil to keep the page that was open last.
    public var startPageDestination: MainWindowPage? {
        (MainWindowStartPage(rawValue: defaults.string(forKey: Self.startPageKey) ?? "") ?? .home).page
    }
    var isSettingsPage: Bool { SettingsTab(rawValue: page.rawValue) != nil }

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

    public func recordSavedClips(_ urls: [URL], kind: SavedClipKind, at date: Date = Date()) {
        let clips = urls.map { RecentClip(url: $0.standardizedFileURL, kind: kind, savedAt: date) }
        recentClips = Array((clips + recentClips).prefix(Self.recentClipLimit))
        for clip in clips {
            Task { await loadDetails(for: clip) }
        }
    }

    private func loadDetails(for clip: RecentClip) async {
        let size = (try? clip.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let info = await ClipMetadata.enrichClipInfo(
            ClipInfo(fileURL: clip.url, creationDate: clip.savedAt, duration: 0, fileSize: size ?? 0)
        )
        let thumbnail = await ClipLibraryViewModel.thumbnailData(for: clip.url)
        guard let index = recentClips.firstIndex(where: { $0.id == clip.id }) else { return }
        recentClips[index].duration = info.duration > 0 ? info.duration : nil
        recentClips[index].fileSize = size
        recentClips[index].thumbnail = thumbnail
    }

    func isProtected(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        return editors.keys.contains { $0.resolvingSymlinksInPath() == key }
            || exports.sourceURL?.resolvingSymlinksInPath() == key
    }

    public func windowDidHide() {
        isWindowVisible = false
    }

    /// Closing marks the window as closed and hidden. Destination routing is
    /// handled when reopening so the window does not flash while hiding and
    /// the last viewed page is preserved.
    public func windowDidClose() {
        windowDidHide()
        isWindowClosed = true
    }

    /// Prepares the active page when opening or reopening the window.
    /// An explicit destination is always selected. When no page is specified,
    /// a closed window resets to the startup destination (if configured),
    /// while an already-open or minimized window keeps its current page.
    public func willOpenWindow(page: MainWindowPage? = nil) {
        if let page {
            select(page)
        } else if isWindowClosed {
            if let start = startPageDestination {
                select(start)
            }
        }
        isWindowClosed = false
        isWindowVisible = true
    }
}
