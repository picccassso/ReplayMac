import AppKit
import Combine
import Defaults
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
    @Published public var isPresentingFeatureCustomiser = false
    public let exports: ClipExportCoordinator
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
    private var defaultsObservations: [Defaults.Observation] = []

    public init(defaults: UserDefaults = .standard,
                exports: ClipExportCoordinator = ClipExportCoordinator()) {
        self.defaults = defaults
        self.exports = exports
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
        // The clip library drops its thumbnails while the window is hidden.
        // Driven from here so it does not depend on the view being updated
        // while its window is off screen. The initial value counts too: an
        // app launched straight to the menu bar has a hidden window from the
        // start.
        $isWindowVisible
            .removeDuplicates()
            .sink { [library] visible in library.model.setWindowVisible(visible) }
            .store(in: &subscriptions)
        presentEditor = { [weak self] session in
            guard let self else { return }
            ClipEditorWindowController.show(session: session, state: self)
        }
        defaultsObservations.append(Defaults.observe(.enabledFeatureModules) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.objectWillChange.send()
                if self.isSettingsPage && !self.visibleSettingsPages.contains(self.page) {
                    self.select(.general)
                }
            }
        })
    }

    public var visibleSettingsPages: [MainWindowPage] {
        var pages: [MainWindowPage] = [.general]
        if AppSettings.isFeatureEnabled(.appearance) {
            pages.append(.appearance)
        }
        pages.append(contentsOf: [.video, .audio])
        if AppSettings.isFeatureEnabled(.captureProfiles) {
            pages.append(.profiles)
        }
        pages.append(.hotkeys)
        if AppSettings.isFeatureEnabled(.companion) {
            pages.append(.companion)
        }
        if AppSettings.isFeatureEnabled(.systemAndFileTuning) {
            pages.append(.advanced)
        }
        return pages
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
    /// Login-item launches and external "Open With" launches stay out of the
    /// main window's way; manual launches follow the user's "On launch"
    /// preference once onboarding is complete.
    public func shouldOpenWindowOnLaunch(
        hasCompletedOnboarding: Bool,
        isLaunchedAsLoginItem: Bool,
        isOpeningExternalFiles: Bool = false
    ) -> Bool {
        hasCompletedOnboarding && !isLaunchedAsLoginItem && !isOpeningExternalFiles && opensWindowOnLaunch
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

    /// Detects whether the app was launched to open files via Finder "Open With",
    /// Dock drag-and-drop, or `open -a` (`odoc` Apple Event).
    /// Must be evaluated synchronously inside `applicationDidFinishLaunching`.
    nonisolated public static func isOpenDocumentsLaunchEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event else { return false }
        return event.eventID == kAEOpenDocuments
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
        let source = ExternalVideoOpenPolicy.canonicalURL(for: url)
        let session = editors[source] ?? ClipEditorSession(url: source, exports: exports)
        editors[source] = session
        presentEditor?(session)
    }

    /// Whether the main window should display its export status toast.
    /// Results from an editor-initiated export are suppressed here while that
    /// clip's Trim window is still open (it already shows its own result banner),
    /// but surface in the main window if the Trim window was closed mid-export.
    public var showsMainWindowExportStatus: Bool {
        if exports.isBusy {
            return true
        }
        guard exports.completedURL != nil || exports.errorMessage != nil else {
            return false
        }
        if exports.resultOrigin == .editor,
           let source = exports.resultSourceURL,
           hasOpenEditor(for: source) {
            return false
        }
        return true
    }

    func hasOpenEditor(for url: URL) -> Bool {
        editors[ExternalVideoOpenPolicy.canonicalURL(for: url)] != nil
    }

    /// Ends the edit. A running export keeps going; the coordinator owns it.
    /// A finished result that belonged to this editor is cleared so closing
    /// the Trim window doesn't make a stale toast pop into the main window.
    func closeEditor(_ url: URL) {
        let source = ExternalVideoOpenPolicy.canonicalURL(for: url)
        editors.removeValue(forKey: source)?.dispose()
        exports.setAutoDismissPaused(false, source: ClipExportCoordinator.editorPauseSource(for: source))
        if !exports.isBusy,
           exports.resultOrigin == .editor,
           exports.resultSourceURL == source {
            exports.dismissResult()
        }
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

    public enum CompanionClipError: Error, LocalizedError {
        case notFound
        case protected
        case fileMissing
        case invalidName
        case operationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "That clip is no longer in the recent clips list."
            case .protected:
                return "Close the clip editor or wait for the active export to finish before modifying this clip."
            case .fileMissing:
                return "The clip file could not be found on disk."
            case .invalidName:
                return "Enter a valid clip name."
            case .operationFailed(let reason):
                return reason
            }
        }
    }

    public func recentClip(matchingId clipId: String) -> RecentClip? {
        recentClips.first {
            $0.id.uuidString.caseInsensitiveCompare(clipId) == .orderedSame || $0.id.uuidString == clipId
        }
    }

    public func clipMetadataMap(for clips: [RecentClip]) -> [String: ClipUserMetadata] {
        var directories = Set<URL>()
        for clip in clips {
            directories.insert(clip.url.deletingLastPathComponent().standardizedFileURL)
        }
        var combined: [String: ClipUserMetadata] = [:]
        for dir in directories {
            for (key, value) in ClipLibraryMetadataStore.load(in: dir) {
                combined[key] = value
            }
        }
        return combined
    }

    @discardableResult
    public func toggleRecentClipFavorite(id: UUID) -> Result<Void, CompanionClipError> {
        guard let clip = recentClips.first(where: { $0.id == id }) else {
            return .failure(.notFound)
        }
        let dir = clip.url.deletingLastPathComponent()
        var metadataByPath = ClipLibraryMetadataStore.load(in: dir)
        let key = ClipLibraryMetadataStore.key(for: clip.url)
        var metadata = metadataByPath[key] ?? .empty
        metadata.isFavorite.toggle()
        metadataByPath[key] = metadata
        ClipLibraryMetadataStore.save(metadataByPath, in: dir)
        NotificationCenter.default.post(name: .replayCapLibraryShouldReload, object: nil)
        onRecentClipsUpdated?()
        return .success(())
    }

    @discardableResult
    public func updateRecentClipMetadata(
        id: UUID,
        isFavorite: Bool?,
        tags: [String]?,
        note: String?
    ) -> Result<Void, CompanionClipError> {
        guard let clip = recentClips.first(where: { $0.id == id }) else {
            return .failure(.notFound)
        }
        let dir = clip.url.deletingLastPathComponent()
        var metadataByPath = ClipLibraryMetadataStore.load(in: dir)
        let key = ClipLibraryMetadataStore.key(for: clip.url)
        var metadata = metadataByPath[key] ?? .empty
        if let isFavorite {
            metadata.isFavorite = isFavorite
        }
        if let tags {
            var seen = Set<String>()
            var cleaned: [String] = []
            for rawTag in tags {
                let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty else { continue }
                if seen.insert(tag.lowercased()).inserted {
                    cleaned.append(tag)
                }
            }
            metadata.tags = cleaned
        }
        if let note {
            metadata.notes = note
        }
        metadataByPath[key] = metadata
        ClipLibraryMetadataStore.save(metadataByPath, in: dir)
        NotificationCenter.default.post(name: .replayCapLibraryShouldReload, object: nil)
        onRecentClipsUpdated?()
        return .success(())
    }

    public func renameRecentClip(id: UUID, newName: String) -> Result<URL, CompanionClipError> {
        guard let index = recentClips.firstIndex(where: { $0.id == id }) else {
            return .failure(.notFound)
        }
        let clip = recentClips[index]
        let oldURL = clip.url
        guard !isProtected(oldURL) else {
            return .failure(.protected)
        }
        guard FileManager.default.fileExists(atPath: oldURL.path) else {
            return .failure(.fileMissing)
        }

        let ext = oldURL.pathExtension.isEmpty ? "mp4" : oldURL.pathExtension
        var rawBase = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".\(ext)"
        if rawBase.lowercased().hasSuffix(suffix.lowercased()) {
            rawBase = String(rawBase.dropLast(suffix.count))
        }
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleanBase = rawBase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBase.isEmpty, cleanBase != ".", cleanBase != ".." else {
            return .failure(.invalidName)
        }

        let dir = oldURL.deletingLastPathComponent()
        if cleanBase == oldURL.deletingPathExtension().lastPathComponent {
            return .success(oldURL)
        }

        var candidate = dir.appendingPathComponent(cleanBase).appendingPathExtension(ext)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(cleanBase)_\(counter)").appendingPathExtension(ext)
            counter += 1
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: candidate)
        } catch {
            return .failure(.operationFailed(error.localizedDescription))
        }

        var metadataByPath = ClipLibraryMetadataStore.load(in: dir)
        let oldKey = ClipLibraryMetadataStore.key(for: oldURL)
        let newKey = ClipLibraryMetadataStore.key(for: candidate)
        if let existing = metadataByPath.removeValue(forKey: oldKey) {
            metadataByPath[newKey] = existing
            ClipLibraryMetadataStore.save(metadataByPath, in: dir)
        }

        recentClips[index].url = candidate.standardizedFileURL
        NotificationCenter.default.post(name: .replayCapLibraryShouldReload, object: nil)
        onRecentClipsUpdated?()
        return .success(candidate.standardizedFileURL)
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
        exports.setAutoDismissPaused(false, source: ClipExportCoordinator.mainWindowPauseSource)
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
