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
            defaults.set(MainWindowStartPage.library.rawValue, forKey: MainWindowState.startPageKey)
            XCTAssertEqual(MainWindowState(defaults: defaults).page, .library)
            XCTAssertEqual(state.startPageDestination, .library)
            defaults.set(MainWindowStartPage.lastViewed.rawValue, forKey: MainWindowState.startPageKey)
            XCTAssertEqual(MainWindowState(defaults: defaults).page, .general)
            XCTAssertNil(state.startPageDestination)
            defaults.set("removed-choice", forKey: MainWindowState.startPageKey)
            XCTAssertEqual(state.startPageDestination, .home)
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
        XCTAssertFalse(state.exports.isBusy)
        XCTAssertFalse(state.isProtected(source))
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
        XCTAssertFalse(exports.isBusy)
        exports.dismissResult()
        XCTAssertNil(exports.errorMessage)
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
}
