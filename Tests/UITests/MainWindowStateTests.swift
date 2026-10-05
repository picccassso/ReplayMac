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
        try run(MainWindowState(defaults: defaults), defaults)
    }

    @MainActor
    func testFirstPageAndSettingsShortcutRestoration() {
        withState { state, defaults in
            XCTAssertEqual(state.page, .library)
            XCTAssertFalse(state.hasVisitedSettings)
            state.select(.audio)
            XCTAssertTrue(state.hasVisitedSettings)
            XCTAssertEqual(MainWindowState(defaults: defaults).page, .audio)
            XCTAssertEqual(MainWindowState(defaults: defaults).settingsTab, .audio)
            state.select(.general)
            XCTAssertEqual(state.settingsTab, .general)
            defaults.set("removed-page", forKey: "mainWindowPage")
            XCTAssertEqual(MainWindowState(defaults: defaults).page, .library)
        }
    }

    @MainActor
    func testLibraryShortcutRoutesFromSettingsAndEditorAndOnlyHidesFrontmostLibrary() {
        withState { state, _ in
            state.select(.audio)
            XCTAssertFalse(state.routeLibraryShortcut(windowIsFrontmost: true))
            XCTAssertEqual(state.page, .library)
            state.isWindowVisible = true
            XCTAssertTrue(state.routeLibraryShortcut(windowIsFrontmost: true))
            XCTAssertFalse(state.isWindowVisible)
            XCTAssertFalse(state.routeLibraryShortcut(windowIsFrontmost: false))
            state.openEditor(URL(fileURLWithPath: "/private/tmp/first.mp4"))
            let editor = state.editor
            XCTAssertFalse(state.routeLibraryShortcut(windowIsFrontmost: true))
            XCTAssertTrue(state.isLibraryFrontmost)
            XCTAssertTrue(state.editor === editor)
            XCTAssertTrue(state.sidebarVisible)
            state.discardEditor()
        }
    }

    @MainActor
    func testDraftAndLibraryStateSurviveNavigationAndWindowHiding() throws {
        try withState { state, _ in
            state.library.searchText = "goal"
            state.library.selection = ["clip.mp4"]
            state.library.metadataDraft.notes = "Keep this note"
            state.openEditor(URL(fileURLWithPath: "/private/tmp/first.mp4"))
            let editor = try XCTUnwrap(state.editor)
            editor.trimStart = 4
            editor.trimEnd = 12
            editor.cropEnabled = true
            editor.exportQuality = .compact
            XCTAssertTrue(state.isEditing)
            XCTAssertFalse(state.sidebarVisible)
            state.select(.video)
            state.windowDidHide()
            XCTAssertTrue(state.sidebarVisible)
            XCTAssertFalse(editor.isVisible)
            state.select(.library)
            XCTAssertTrue(state.isLibraryFrontmost)
            XCTAssertEqual(state.library.searchText, "goal")
            XCTAssertEqual(state.library.selection, ["clip.mp4"])
            XCTAssertEqual(state.library.metadataDraft.notes, "Keep this note")
            state.resumeEditor()
            XCTAssertTrue(state.editor === editor)
            XCTAssertEqual(editor.trimStart, 4)
            XCTAssertEqual(editor.trimEnd, 12)
            XCTAssertTrue(editor.cropEnabled)
            XCTAssertEqual(editor.exportQuality, .compact)
            state.discardEditor()
        }
    }

    @MainActor
    func testSidebarReturnsToBrowsingPreference() {
        withState { state, defaults in
            state.toggleSidebar()
            XCTAssertFalse(state.sidebarVisible)
            state.openEditor(URL(fileURLWithPath: "/private/tmp/first.mp4"))
            state.toggleSidebar()
            XCTAssertTrue(state.sidebarVisible)
            state.select(.library)
            XCTAssertFalse(state.sidebarVisible)
            XCTAssertFalse(MainWindowState(defaults: defaults).sidebarVisible)
            state.discardEditor()
        }
    }

    @MainActor
    func testReplacementRequiresExplicitConfirmationAndReleasesProtection() throws {
        try withState { state, _ in
            let first = URL(fileURLWithPath: "/private/tmp/first.mp4")
            let second = URL(fileURLWithPath: "/private/tmp/second.mp4")
            state.openEditor(first)
            let editor = try XCTUnwrap(state.editor)
            state.openEditor(second)
            XCTAssertTrue(state.editor === editor)
            XCTAssertEqual(state.replacementCandidate, second)
            XCTAssertTrue(state.isProtected(first))
            state.replaceEditor()
            XCTAssertEqual(state.editor?.url, second)
            XCTAssertFalse(state.isProtected(first))
            XCTAssertTrue(state.isProtected(second))
            state.discardEditor()
            XCTAssertFalse(state.isProtected(second))
        }
    }

    @MainActor
    func testExportSurvivesNavigationAndHideAndBlocksConcurrentJobs() async throws {
        let name = "MainWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let state = MainWindowState(defaults: defaults)
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
        state.openEditor(source)
        XCTAssertNil(state.editor)
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
