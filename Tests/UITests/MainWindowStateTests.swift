import AppKit
import AVFoundation
import Defaults
import Save
import XCTest
@testable import UI

final class MainWindowStateTests: XCTestCase {
    @MainActor
    private func withState(_ run: (MainWindowState, UserDefaults) throws -> Void) rethrows {
        let name = "MainWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try run(makeState(defaults), defaults)
    }

    /// Editor windows are not created in tests.
    @MainActor
    private func makeState(_ defaults: UserDefaults) -> MainWindowState {
        let state = MainWindowState(defaults: defaults)
        state.presentEditor = nil
        return state
    }

    @MainActor
    func testFirstPageAndSettingsShortcutRestoration() {
        withState { state, defaults in
            XCTAssertEqual(state.page, .home)
            XCTAssertFalse(state.hasVisitedSettings)
            state.select(.library)
            XCTAssertFalse(state.hasVisitedSettings)
            XCTAssertFalse(MainWindowState(defaults: defaults).hasVisitedSettings)
            state.select(.home)
            XCTAssertFalse(state.isSettingsPage)
            state.select(.audio)
            XCTAssertTrue(state.isSettingsPage)
            XCTAssertTrue(state.hasVisitedSettings)
            defaults.set(MainWindowStartPage.lastViewed.rawValue, forKey: MainWindowState.startPageKey)
            XCTAssertEqual(MainWindowState(defaults: defaults).page, .audio)
            XCTAssertEqual(MainWindowState(defaults: defaults).settingsTab, .audio)
            state.select(.general)
            XCTAssertEqual(state.settingsTab, .general)
            defaults.set("removed-page", forKey: "mainWindowPage")
            XCTAssertEqual(MainWindowState(defaults: defaults).page, .home)
        }
    }

    @MainActor
    func testStartPageSettingChoosesTheOpeningPage() {
        withState { state, defaults in
            state.select(.general)
            // Home is the default, whatever page was open last.
            XCTAssertEqual(MainWindowState(defaults: defaults).page, .home)
            XCTAssertEqual(state.startPageDestination, .home)
            XCTAssertTrue(state.opensWindowOnLaunch)
            defaults.set(MainWindowStartPage.library.rawValue, forKey: MainWindowState.startPageKey)
            XCTAssertEqual(MainWindowState(defaults: defaults).page, .library)
            XCTAssertEqual(state.startPageDestination, .library)
            XCTAssertTrue(state.opensWindowOnLaunch)
            defaults.set(MainWindowStartPage.settings.rawValue, forKey: MainWindowState.startPageKey)
            let settingsState = MainWindowState(defaults: defaults)
            XCTAssertEqual(settingsState.page, .general)
            XCTAssertEqual(settingsState.settingsTab, .general)
            XCTAssertTrue(settingsState.hasVisitedSettings)
            XCTAssertEqual(state.startPageDestination, .general)
            XCTAssertTrue(state.opensWindowOnLaunch)
            defaults.set(MainWindowStartPage.lastViewed.rawValue, forKey: MainWindowState.startPageKey)
            state.select(.audio)
            XCTAssertEqual(MainWindowState(defaults: defaults).page, .audio)
            XCTAssertNil(state.startPageDestination)
            XCTAssertTrue(state.opensWindowOnLaunch)
            defaults.set("removed-choice", forKey: MainWindowState.startPageKey)
            XCTAssertEqual(state.startPageDestination, .home)
            XCTAssertTrue(state.opensWindowOnLaunch)
        }
    }

    @MainActor
    func testLaunchBehaviorIsIndependentOfStartPageAndMigratesLegacyHiddenStartPage() {
        withState { state, defaults in
            defaults.set(MainWindowLaunchBehavior.hidden.rawValue, forKey: MainWindowState.launchBehaviorKey)
            defaults.set(MainWindowStartPage.library.rawValue, forKey: MainWindowState.startPageKey)
            let hiddenLibraryState = MainWindowState(defaults: defaults)
            XCTAssertFalse(hiddenLibraryState.opensWindowOnLaunch)
            XCTAssertEqual(hiddenLibraryState.page, .library)
            XCTAssertEqual(hiddenLibraryState.startPageDestination, .library)

            defaults.set(MainWindowLaunchBehavior.mainWindow.rawValue, forKey: MainWindowState.launchBehaviorKey)
            XCTAssertTrue(state.opensWindowOnLaunch)
            defaults.set("removed-behavior", forKey: MainWindowState.launchBehaviorKey)
            XCTAssertTrue(state.opensWindowOnLaunch)

            // Legacy "hidden" in mainWindowStartPage migrates to mainWindowLaunchBehavior.
            defaults.removeObject(forKey: MainWindowState.launchBehaviorKey)
            defaults.set("hidden", forKey: MainWindowState.startPageKey)
            let migratedState = MainWindowState(defaults: defaults)
            XCTAssertFalse(migratedState.opensWindowOnLaunch)
            XCTAssertEqual(migratedState.page, .home)
            XCTAssertEqual(defaults.string(forKey: MainWindowState.launchBehaviorKey), MainWindowLaunchBehavior.hidden.rawValue)
            XCTAssertEqual(defaults.string(forKey: MainWindowState.startPageKey), MainWindowStartPage.home.rawValue)
        }
    }

    @MainActor
    func testShouldOpenWindowOnLaunchAndLoginItemDetection() {
        XCTAssertFalse(MainWindowState.isLoginItemLaunchEvent(nil))

        let plainOpenEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        XCTAssertFalse(MainWindowState.isLoginItemLaunchEvent(plainOpenEvent))

        let otherEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        XCTAssertFalse(MainWindowState.isLoginItemLaunchEvent(otherEvent))

        let loginItemEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        loginItemEvent.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(MainWindowState.isLoginItemLaunchEvent(loginItemEvent))

        let serviceItemEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        serviceItemEvent.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem), forKeyword: keyAEPropData)
        XCTAssertTrue(MainWindowState.isLoginItemLaunchEvent(serviceItemEvent))

        XCTAssertFalse(MainWindowState.isOpenDocumentsLaunchEvent(nil))
        XCTAssertFalse(MainWindowState.isOpenDocumentsLaunchEvent(plainOpenEvent))
        let openDocumentsEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        XCTAssertTrue(MainWindowState.isOpenDocumentsLaunchEvent(openDocumentsEvent))

        withState { state, defaults in
            defaults.set(MainWindowLaunchBehavior.mainWindow.rawValue, forKey: MainWindowState.launchBehaviorKey)
            XCTAssertTrue(state.opensWindowOnLaunch)

            // Incomplete onboarding never opens the main window on launch.
            XCTAssertFalse(state.shouldOpenWindowOnLaunch(hasCompletedOnboarding: false, isLaunchedAsLoginItem: false))
            XCTAssertFalse(state.shouldOpenWindowOnLaunch(hasCompletedOnboarding: false, isLaunchedAsLoginItem: true))

            // Automatic login-item launches stay quiet in the menu bar.
            XCTAssertFalse(state.shouldOpenWindowOnLaunch(hasCompletedOnboarding: true, isLaunchedAsLoginItem: true))

            // Manual launches open the window when On launch is mainWindow.
            XCTAssertTrue(state.shouldOpenWindowOnLaunch(hasCompletedOnboarding: true, isLaunchedAsLoginItem: false))

            // Opening external files via Finder Open With suppresses auto-opening the main window.
            XCTAssertFalse(
                state.shouldOpenWindowOnLaunch(
                    hasCompletedOnboarding: true,
                    isLaunchedAsLoginItem: false,
                    isOpeningExternalFiles: true
                )
            )

            // Hidden launch behavior keeps manual launches quiet in the menu bar too.
            defaults.set(MainWindowLaunchBehavior.hidden.rawValue, forKey: MainWindowState.launchBehaviorKey)
            XCTAssertFalse(state.opensWindowOnLaunch)
            XCTAssertFalse(state.shouldOpenWindowOnLaunch(hasCompletedOnboarding: true, isLaunchedAsLoginItem: false))
            XCTAssertFalse(state.shouldOpenWindowOnLaunch(hasCompletedOnboarding: true, isLaunchedAsLoginItem: true))
        }
    }

    @MainActor
    func testClosingTheWindowResetsToTheStartPageOnReopenButMinimisingDoesNot() {
        withState { state, defaults in
            defaults.set(MainWindowStartPage.library.rawValue, forKey: MainWindowState.startPageKey)
            state.select(.general)
            state.isWindowVisible = true
            state.isWindowClosed = false

            // Minimising keeps the page the user was on.
            state.windowDidHide()
            XCTAssertFalse(state.isWindowVisible)
            XCTAssertFalse(state.isWindowClosed)
            state.willOpenWindow()
            XCTAssertEqual(state.page, .general)
            XCTAssertTrue(state.isWindowVisible)
            XCTAssertFalse(state.isWindowClosed)

            // Closing does not flash or alter the page before hiding.
            state.windowDidClose()
            XCTAssertFalse(state.isWindowVisible)
            XCTAssertTrue(state.isWindowClosed)
            XCTAssertEqual(state.page, .general)

            // Reopening resets to the start page (Clip Library).
            state.willOpenWindow()
            XCTAssertEqual(state.page, .library)
            XCTAssertTrue(state.isWindowVisible)
            XCTAssertFalse(state.isWindowClosed)

            // Start page set to Home.
            defaults.set(MainWindowStartPage.home.rawValue, forKey: MainWindowState.startPageKey)
            state.select(.video)
            state.windowDidClose()
            XCTAssertEqual(state.page, .video)
            state.willOpenWindow()
            XCTAssertEqual(state.page, .home)

            // Last Viewed Page leaves the page alone on close and reopen.
            defaults.set(MainWindowStartPage.lastViewed.rawValue, forKey: MainWindowState.startPageKey)
            state.select(.audio)
            state.windowDidClose()
            XCTAssertEqual(state.page, .audio)
            state.willOpenWindow()
            XCTAssertEqual(state.page, .audio)

            // Explicit target always takes priority even after close.
            state.windowDidClose()
            state.willOpenWindow(page: .profiles)
            XCTAssertEqual(state.page, .profiles)
        }
    }

    @MainActor
    func testLibraryShortcutRoutesFromSettingsAndOnlyHidesFrontmostLibrary() {
        withState { state, _ in
            XCTAssertFalse(state.routeLibraryShortcut(windowIsFrontmost: true))
            XCTAssertEqual(state.page, .library)
            state.select(.audio)
            XCTAssertFalse(state.routeLibraryShortcut(windowIsFrontmost: true))
            XCTAssertEqual(state.page, .library)
            state.isWindowVisible = true
            XCTAssertTrue(state.routeLibraryShortcut(windowIsFrontmost: true))
            XCTAssertFalse(state.isWindowVisible)
            XCTAssertFalse(state.routeLibraryShortcut(windowIsFrontmost: false))
            // An open editor lives in its own window and never hides the library.
            state.openEditor(URL(fileURLWithPath: "/private/tmp/first.mp4"))
            XCTAssertTrue(state.isLibraryFrontmost)
            XCTAssertTrue(state.routeLibraryShortcut(windowIsFrontmost: true))
            state.closeEditor(URL(fileURLWithPath: "/private/tmp/first.mp4"))
        }
    }

    @MainActor
    func testEditorsAreOnePerClipAndSurviveMainWindowNavigation() throws {
        try withState { state, _ in
            let first = URL(fileURLWithPath: "/private/tmp/first.mp4")
            let second = URL(fileURLWithPath: "/private/tmp/second.mp4")
            var presented: [URL] = []
            state.presentEditor = { presented.append($0.url) }
            state.library.searchText = "goal"
            state.openEditor(first)
            let editor = try XCTUnwrap(state.editors[first])
            editor.trimStart = 4
            editor.trimEnd = 12
            state.openEditor(second)
            state.openEditor(first)
            XCTAssertEqual(state.editors.count, 2)
            XCTAssertTrue(state.editors[first] === editor)
            XCTAssertEqual(presented, [first, second, first])
            state.select(.video)
            state.windowDidHide()
            state.select(.library)
            XCTAssertEqual(state.library.searchText, "goal")
            XCTAssertEqual(editor.trimStart, 4)
            XCTAssertEqual(editor.trimEnd, 12)
            state.closeEditor(first)
            state.closeEditor(second)
        }
    }

    @MainActor
    func testOpenEditorDeduplicatesSymlinkAndCanonicalPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let realFile = directory.appendingPathComponent("clip.mp4")
        try Data("stub".utf8).write(to: realFile)
        let symlink = directory.appendingPathComponent("clip-link.mp4")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realFile)

        withState { state, _ in
            state.openEditor(realFile)
            state.openEditor(symlink)
            XCTAssertEqual(state.editors.count, 1)
            let canonical = ExternalVideoOpenPolicy.canonicalURL(for: realFile)
            XCTAssertNotNil(state.editors[canonical])
            state.closeEditor(symlink)
            XCTAssertTrue(state.editors.isEmpty)
        }
    }

    @MainActor
    func testClosingAnEditorDisposesItAndReleasesProtection() throws {
        try withState { state, _ in
            let first = URL(fileURLWithPath: "/private/tmp/first.mp4")
            let second = URL(fileURLWithPath: "/private/tmp/second.mp4")
            state.openEditor(first)
            state.openEditor(second)
            let editor = try XCTUnwrap(state.editors[first])
            XCTAssertTrue(state.isProtected(first))
            XCTAssertTrue(state.isProtected(second))
            state.closeEditor(first)
            XCTAssertTrue(editor.isClosed)
            XCTAssertNil(state.editors[first])
            XCTAssertFalse(state.isProtected(first))
            XCTAssertTrue(state.isProtected(second))
            state.closeEditor(second)
            XCTAssertFalse(state.isProtected(second))
        }
    }

    @MainActor
    func testSessionHistoryIsNewestFirstCappedAndStartsEmpty() {
        withState { state, defaults in
            XCTAssertTrue(state.recentClips.isEmpty)
            let first = URL(fileURLWithPath: "/private/tmp/first.mp4")
            state.recordSavedClips([first], kind: .replay)
            // A separate dual-display save records both files.
            let left = URL(fileURLWithPath: "/private/tmp/left.mp4")
            let right = URL(fileURLWithPath: "/private/tmp/right.mp4")
            state.recordSavedClips([left, right], kind: .session)
            XCTAssertEqual(state.recentClips.map(\.url), [left, right, first])
            XCTAssertEqual(state.recentClips.first?.kind, .session)
            for index in 0..<MainWindowState.recentClipLimit {
                state.recordSavedClips([URL(fileURLWithPath: "/private/tmp/\(index).mp4")], kind: .extendedReplay)
            }
            XCTAssertEqual(state.recentClips.count, MainWindowState.recentClipLimit)
            XCTAssertFalse(state.recentClips.contains { $0.url == first })
            // History is never persisted: a relaunch starts empty.
            XCTAssertTrue(MainWindowState(defaults: defaults).recentClips.isEmpty)
        }
    }

    @MainActor
    func testExportSurvivesNavigationHideAndEditorCloseAndBlocksConcurrentJobs() async throws {
        let name = "MainWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let state = makeState(defaults)
        let source = URL(fileURLWithPath: "/private/tmp/first.mp4")
        let result = URL(fileURLWithPath: "/private/tmp/result.mp4")
        let finished = expectation(description: "Job completes independently of the visible page")
        XCTAssertTrue(state.exports.start(source: source, title: "Export") {
            try await Task.sleep(for: .milliseconds(30))
            finished.fulfill()
            return result
        })
        XCTAssertFalse(state.exports.start(source: source, title: "Second") { result })
        state.select(.general)
        state.windowDidHide()
        XCTAssertTrue(state.exports.isBusy)
        XCTAssertTrue(state.isProtected(source))
        // An editor can open during an export, and closing it leaves the export running.
        state.openEditor(source)
        XCTAssertNotNil(state.editors[source])
        state.closeEditor(source)
        XCTAssertTrue(state.exports.isBusy)
        XCTAssertTrue(state.isProtected(source))
        await fulfillment(of: [finished], timeout: 2)
        await state.exports.cancelAndWait()
        XCTAssertEqual(state.page, .general)
        XCTAssertEqual(state.exports.completedURL, result)
        XCTAssertEqual(state.exports.resultSourceURL, ExternalVideoOpenPolicy.canonicalURL(for: source))
        XCTAssertFalse(state.exports.isBusy)
        XCTAssertFalse(state.isProtected(source))
        state.exports.dismissResult()
        XCTAssertNil(state.exports.resultSourceURL)
    }

    @MainActor
    func testCancellationWaitsForJobAndAllowsRetry() async {
        let exports = ClipExportCoordinator()
        let source = URL(fileURLWithPath: "/private/tmp/first.mp4")
        exports.start(source: source, title: "Long export") {
            try await Task.sleep(for: .seconds(60))
            return source
        }
        await exports.cancelAndWait()
        XCTAssertFalse(exports.isBusy)
        XCTAssertNil(exports.sourceURL)
        XCTAssertNil(exports.completedURL)
        XCTAssertNil(exports.errorMessage)
        XCTAssertTrue(exports.start(source: source, title: "Retry") { nil })
        await exports.cancelAndWait()
    }

    @MainActor
    func testFailedJobKeepsErrorForRetry() async {
        struct Failure: LocalizedError { var errorDescription: String? { "Example failure" } }
        let exports = ClipExportCoordinator()
        exports.start(source: URL(fileURLWithPath: "/private/tmp/first.mp4"), title: "Export") { throw Failure() }
        // Let the job start before waiting for it without cancellation.
        for _ in 0..<20 where exports.isBusy { await Task.yield() }
        XCTAssertEqual(exports.errorMessage, "Example failure")
        XCTAssertEqual(exports.resultSourceURL, ExternalVideoOpenPolicy.canonicalURL(for: URL(fileURLWithPath: "/private/tmp/first.mp4")))
        XCTAssertFalse(exports.isBusy)
        exports.dismissResult()
        XCTAssertNil(exports.errorMessage)
        XCTAssertNil(exports.resultSourceURL)
    }

    @MainActor
    func testCompletedExportAutoDismissesAndPausesOnHover() async throws {
        let exports = ClipExportCoordinator(autoDismissDelay: .milliseconds(80),
                                            hoverResumeDelay: .milliseconds(60))
        let source = URL(fileURLWithPath: "/private/tmp/clip.mp4")
        let result = URL(fileURLWithPath: "/private/tmp/clip.gif")
        XCTAssertTrue(exports.start(source: source, title: "Exporting GIF", origin: .mainWindow) { result })
        for _ in 0..<20 where exports.isBusy { await Task.yield() }
        XCTAssertEqual(exports.completedURL, result)

        // Hovering pauses auto-dismiss beyond the normal timeout.
        exports.setAutoDismissPaused(true, source: ClipExportCoordinator.mainWindowPauseSource)
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(exports.completedURL, result)

        // Unhovering resumes auto-dismiss and clears the result cleanly.
        exports.setAutoDismissPaused(false, source: ClipExportCoordinator.mainWindowPauseSource)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(exports.completedURL)
        XCTAssertNil(exports.resultSourceURL)
        XCTAssertNil(exports.resultOrigin)
    }

    @MainActor
    func testFailedExportStaysStickyAndDoesNotAutoDismiss() async throws {
        struct Failure: LocalizedError { var errorDescription: String? { "Disk full" } }
        let exports = ClipExportCoordinator(autoDismissDelay: .milliseconds(40),
                                            hoverResumeDelay: .milliseconds(40))
        let source = URL(fileURLWithPath: "/private/tmp/clip.mp4")
        XCTAssertTrue(exports.start(source: source, title: "Exporting MP4", origin: .mainWindow) { throw Failure() })
        for _ in 0..<20 where exports.isBusy { await Task.yield() }
        XCTAssertEqual(exports.errorMessage, "Disk full")

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(exports.errorMessage, "Disk full")
    }

    @MainActor
    func testStartingNewExportCancelsPreviousAutoDismissTimer() async throws {
        let exports = ClipExportCoordinator(autoDismissDelay: .milliseconds(100),
                                            hoverResumeDelay: .milliseconds(100))
        let source = URL(fileURLWithPath: "/private/tmp/clip.mp4")
        let firstResult = URL(fileURLWithPath: "/private/tmp/first.gif")
        let secondResult = URL(fileURLWithPath: "/private/tmp/second.gif")

        XCTAssertTrue(exports.start(source: source, title: "Export 1") { firstResult })
        for _ in 0..<20 where exports.isBusy { await Task.yield() }
        XCTAssertEqual(exports.completedURL, firstResult)

        // Start a second export before the first timer fires; it finishes after the first timer would have fired.
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(exports.start(source: source, title: "Export 2") {
            try await Task.sleep(for: .milliseconds(90))
            return secondResult
        })
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(exports.completedURL, secondResult)

        // Eventually the second result's own timer clears it.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(exports.completedURL)
    }

    @MainActor
    func testEditorExportSuppressionAndCloseBehavior() async throws {
        let name = "MainWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let exports = ClipExportCoordinator(autoDismissDelay: .seconds(30))
        let state = MainWindowState(defaults: defaults, exports: exports)
        state.presentEditor = nil

        let clipA = URL(fileURLWithPath: "/private/tmp/clipA.mp4")
        let clipB = URL(fileURLWithPath: "/private/tmp/clipB.mp4")
        let outA = URL(fileURLWithPath: "/private/tmp/clipA_trimmed.mp4")

        // 1. Editor export finishes while editor A is open -> suppressed in main window.
        state.openEditor(clipA)
        state.openEditor(clipB)
        XCTAssertTrue(exports.start(source: clipA, title: "Exporting MP4", origin: .editor) { outA })
        for _ in 0..<20 where exports.isBusy { await Task.yield() }
        XCTAssertEqual(exports.completedURL, outA)
        XCTAssertFalse(state.showsMainWindowExportStatus)

        // Closing unrelated editor B does not clear clip A's result.
        state.closeEditor(clipB)
        XCTAssertEqual(exports.completedURL, outA)
        XCTAssertFalse(state.showsMainWindowExportStatus)

        // Closing editor A clears its finished result so it does not flash in the main window.
        state.closeEditor(clipA)
        XCTAssertNil(exports.completedURL)
        XCTAssertFalse(state.showsMainWindowExportStatus)

        // 2. Editor export where editor closes mid-export -> surfaces in main window on completion.
        state.openEditor(clipA)
        let started = expectation(description: "Export running")
        XCTAssertTrue(exports.start(source: clipA, title: "Exporting MP4", origin: .editor) {
            started.fulfill()
            try await Task.sleep(for: .milliseconds(40))
            return outA
        })
        await fulfillment(of: [started], timeout: 2)
        state.closeEditor(clipA)
        XCTAssertTrue(exports.isBusy)
        XCTAssertTrue(state.showsMainWindowExportStatus)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(exports.isBusy)
        XCTAssertEqual(exports.completedURL, outA)
        XCTAssertTrue(state.showsMainWindowExportStatus)
        exports.dismissResult()

        // 3. Main-window export still shows in main window even if an editor is open for the same clip,
        // and closing that editor does not dismiss the main-window toast.
        state.openEditor(clipA)
        XCTAssertTrue(exports.start(source: clipA, title: "Exporting GIF", origin: .mainWindow) { outA })
        for _ in 0..<20 where exports.isBusy { await Task.yield() }
        XCTAssertTrue(state.showsMainWindowExportStatus)
        state.closeEditor(clipA)
        XCTAssertEqual(exports.completedURL, outA)
        XCTAssertTrue(state.showsMainWindowExportStatus)
    }

    @MainActor
    func testHidingMainWindowReleasesHoverPauseSoAutoDismissStillFires() async throws {
        let name = "MainWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let exports = ClipExportCoordinator(autoDismissDelay: .milliseconds(60),
                                            hoverResumeDelay: .milliseconds(50))
        let state = MainWindowState(defaults: defaults, exports: exports)
        state.presentEditor = nil

        let clip = URL(fileURLWithPath: "/private/tmp/clip.mp4")
        let out = URL(fileURLWithPath: "/private/tmp/clip.gif")
        XCTAssertTrue(exports.start(source: clip, title: "Exporting GIF", origin: .mainWindow) { out })
        for _ in 0..<20 where exports.isBusy { await Task.yield() }

        exports.setAutoDismissPaused(true, source: ClipExportCoordinator.mainWindowPauseSource)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(exports.completedURL, out)

        state.windowDidHide()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(exports.completedURL)
    }

    @MainActor
    func testStagedExportPreservesDestinationOnFailureAndCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let output = directory.appendingPathComponent("existing.mp4")
        try Data("source".utf8).write(to: source)
        try Data("original destination".utf8).write(to: output)
        do {
            _ = try await ClipExportCoordinator.write(source: source, destination: output) { staged in
                try Data("partial".utf8).write(to: staged)
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "original destination")
        do {
            _ = try await ClipExportCoordinator.write(source: source, destination: source) { _ in XCTFail("Source must never be opened for export") }
            XCTFail("Expected source overwrite refusal")
        } catch ExportFileError.sourceOverwrite {}
        _ = try await ClipExportCoordinator.write(source: source, destination: output) { staged in
            try Data("finished export".utf8).write(to: staged)
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "finished export")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
    }

    @MainActor
    func testProtectedSourceCannotBeDeletedOrRenamedThroughModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try Data("source".utf8).write(to: source)
        let model = ClipLibraryViewModel(outputDirectory: { directory })
        model.isProtected = { $0 == source }
        let row = ClipRow(info: ClipInfo(fileURL: source, creationDate: Date(), duration: 1, fileSize: 6), thumbnail: nil, userMetadata: .empty)
        model.rows = [row]
        await model.delete(row)
        await model.delete([row])
        XCTAssertNil(model.rename(row, to: "changed", metadata: .empty))
        await model.cleanup(.allNonFavorites)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(model.rows.count, 1)
    }

    @MainActor
    func testCleanupKeepsMetadataForClipsThatCouldNotBeTrashed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("stuck.mp4")
        try Data("clip".utf8).write(to: source)
        // An immutable file can't be moved to the Trash.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: source.path) }

        let model = ClipLibraryViewModel(outputDirectory: { directory })
        await model.reload()
        let row = try XCTUnwrap(model.rows.first)
        let metadata = ClipUserMetadata(displayName: "Keep me", isFavorite: false, tags: ["notes"], notes: "Still here")
        model.updateMetadata(for: row, metadata: metadata)

        await model.cleanup(.allNonFavorites)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let stored = ClipLibraryMetadataStore.load(in: directory)
        XCTAssertEqual(stored[ClipLibraryMetadataStore.key(for: source)], metadata)
        XCTAssertEqual(model.rows.first?.userMetadata, metadata)
    }

    @MainActor
    func testRenamePersistsUnifiedMetadataAndNewFilename() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("clip_01.mp4")
        try Data("clip".utf8).write(to: source)

        let model = ClipLibraryViewModel(outputDirectory: { directory })
        await model.reload()
        let row = ClipRow(
            info: ClipInfo(fileURL: source, creationDate: Date(), duration: 5, fileSize: 4),
            thumbnail: nil,
            userMetadata: .empty
        )
        model.rows = [row]

        let updatedMetadata = ClipUserMetadata(
            displayName: "Overtime Clutch",
            isFavorite: true,
            tags: ["ranked", "ace"],
            notes: "Final round"
        )
        let newID = model.rename(row, to: "overtime_clutch", metadata: updatedMetadata)
        let renamedURL = directory.appendingPathComponent("overtime_clutch.mp4")

        XCTAssertEqual(newID, renamedURL.path(percentEncoded: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))
        let stored = ClipLibraryMetadataStore.load(in: directory)
        XCTAssertEqual(stored[ClipLibraryMetadataStore.key(for: renamedURL)], updatedMetadata)
    }

    @MainActor
    func testVisibleSettingsPagesFollowPresetAndRouteFallback() {
        let originalModules = Defaults[.enabledFeatureModules]
        defer { Defaults[.enabledFeatureModules] = originalModules }

        withState { state, _ in
            AppSettings.applyExperiencePreset(.simple)
            XCTAssertEqual(state.visibleSettingsPages, [.general, .appearance, .video, .audio, .hotkeys])

            AppSettings.applyExperiencePreset(.balanced)
            XCTAssertEqual(state.visibleSettingsPages, [.general, .appearance, .video, .audio, .hotkeys])

            AppSettings.applyExperiencePreset(.full)
            XCTAssertEqual(state.visibleSettingsPages, [.general, .appearance, .video, .audio, .profiles, .hotkeys, .companion, .advanced])

            // If user is on an advanced page and its module is turned off, navigation gracefully routes to .general
            state.select(.companion)
            XCTAssertEqual(state.page, .companion)
            AppSettings.setFeatureEnabled(.companion, false)

            // Let the MainActor observation run
            let expectation = expectation(description: "Navigation falls back to general")
            Task { @MainActor in
                XCTAssertEqual(state.page, .general)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2.0)
        }
    }
}
