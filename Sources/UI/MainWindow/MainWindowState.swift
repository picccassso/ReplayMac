import AppKit
import Combine
import Save
import SwiftUI

public extension Notification.Name {
    static let replayCapLibraryShouldReload = Notification.Name("replayCapLibraryShouldReload")
}

public enum MainWindowPage: String, CaseIterable, Identifiable {
    case home, library, general, appearance, video, audio, profiles, hotkeys, companion, advanced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .home: "Home"
        case .library: "Clip Library"
        case .general: "General"
        case .appearance: "Appearance"
        case .video: "Video"
        case .audio: "Audio"
        case .profiles: "Profiles"
        case .hotkeys: "Hotkeys"
        case .companion: "Companion"
        case .advanced: "Advanced"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .library: "film.stack"
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .video: "video"
        case .audio: "speaker.wave.2"
        case .profiles: "rectangle.stack.badge.play"
        case .hotkeys: "keyboard"
        case .companion: "iphone"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// Whether launching the app automatically opens the main window or keeps
/// the app running quietly in the menu bar. Set in Settings > General.
public enum MainWindowLaunchBehavior: String, CaseIterable, Identifiable {
    case mainWindow, hidden
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mainWindow: "Open Main Window"
        case .hidden: "Hidden (Menu Bar Only)"
        }
    }
    /// False when the app should launch quietly in the menu bar without opening the main window.
    public var opensWindowOnLaunch: Bool {
        self == .mainWindow
    }
}

/// The page the main window shows when it opens without a specific
/// destination, such as at launch, from the Dock, or via Open in the menu bar.
/// Set in Settings > General.
public enum MainWindowStartPage: String, CaseIterable, Identifiable {
    case home, library, settings, lastViewed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .home: "Home"
        case .library: "Clip Library"
        case .settings: "Settings"
        case .lastViewed: "Last Viewed Page"
        }
    }
    /// Nil restores whichever page was open last.
    var page: MainWindowPage? {
        switch self {
        case .home: .home
        case .library: .library
        case .settings: .general
        case .lastViewed: nil
        }
    }
}

@MainActor
public final class MainWindowState: ObservableObject {
    nonisolated public static let startPageKey = "mainWindowStartPage"
    nonisolated public static let launchBehaviorKey = "mainWindowLaunchBehavior"
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
    @Published public private(set) var recentClips: [RecentClip] = []
    public var onRecentClipsUpdated: (@MainActor () -> Void)?
    static let recentClipLimit = 20
    let library: ClipLibraryState
    /// Brings a session's editor window forward. Tests leave it nil so no windows are created.
    var presentEditor: ((ClipEditorSession) -> Void)?
    private let defaults: UserDefaults
    private var subscriptions = Set<AnyCancellable>()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.string(forKey: Self.startPageKey) == MainWindowLaunchBehavior.hidden.rawValue {
            if defaults.string(forKey: Self.launchBehaviorKey) == nil {
                defaults.set(MainWindowLaunchBehavior.hidden.rawValue, forKey: Self.launchBehaviorKey)
            }
            defaults.set(MainWindowStartPage.home.rawValue, forKey: Self.startPageKey)
        }
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

    /// Whether launching the app should automatically open the main window.
    public var opensWindowOnLaunch: Bool {
        (MainWindowLaunchBehavior(rawValue: defaults.string(forKey: Self.launchBehaviorKey) ?? "") ?? .mainWindow).opensWindowOnLaunch
    }

    /// Whether the main window should open automatically during app launch.
    /// Login-item launches always stay quiet in the menu bar; manual launches
    /// follow the user's "On launch" preference once onboarding is complete.
    public func shouldOpenWindowOnLaunch(
        hasCompletedOnboarding: Bool,
        isLaunchedAsLoginItem: Bool
    ) -> Bool {
        hasCompletedOnboarding && !isLaunchedAsLoginItem && opensWindowOnLaunch
    }

    /// Detects whether an `oapp` Apple Event was sent by macOS Login Items / `SMAppService`.
    /// Must be evaluated synchronously inside `applicationDidFinishLaunching` while
    /// `NSAppleEventManager.shared().currentAppleEvent` is still populated.
    nonisolated public static func isLoginItemLaunchEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == kAEOpenApplication,
              let propData = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue else {
            return false
        }
        return propData == keyAELaunchedAsLogInItem || propData == keyAELaunchedAsServiceItem
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

    public func openEditor(_ url: URL) {
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
        onRecentClipsUpdated?()
        for clip in clips {
            Task { await loadDetails(for: clip) }
        }
    }

    public func removeRecentClip(id: UUID) {
        recentClips.removeAll { $0.id == id }
        onRecentClipsUpdated?()
    }

    public func thumbnailData(for id: UUID) async -> Data? {
        if let clip = recentClips.first(where: { $0.id == id }), let data = clip.thumbnail {
            return data
        }
        guard let clip = recentClips.first(where: { $0.id == id }) else { return nil }
        let thumb = await ClipLibraryViewModel.thumbnailData(for: clip.url)
        if let thumb, let index = recentClips.firstIndex(where: { $0.id == id }) {
            recentClips[index].thumbnail = thumb
        }
        return thumb
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
        onRecentClipsUpdated?()
    }

    public func isProtected(_ url: URL) -> Bool {
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
