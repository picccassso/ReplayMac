import Foundation
import XCTest
@testable import UI

final class OutputDirectorySelectionTests: XCTestCase {
    func testAppStoreDefaultDoesNotProposeAnOutputDirectory() {
        let directDefault = URL(filePath: "/Users/test/Movies/ReplayMac", directoryHint: .isDirectory)

        XCTAssertEqual(
            AppSettings.defaultOutputDirectoryPath(
                requiresExplicitSelection: true,
                directBuildDefault: directDefault
            ),
            ""
        )
    }

    func testDirectBuildRetainsItsOutputDirectoryDefault() {
        let directDefault = URL(filePath: "/Users/test/Movies/ReplayMac", directoryHint: .isDirectory)

        XCTAssertEqual(
            AppSettings.defaultOutputDirectoryPath(
                requiresExplicitSelection: false,
                directBuildDefault: directDefault
            ),
            directDefault.standardizedFileURL.path(percentEncoded: false)
        )
    }

    func testEmptyStoredPathDoesNotResolveToAWorkingDirectory() {
        XCTAssertNil(AppSettings.outputDirectoryURL(for: ""))
        XCTAssertNil(AppSettings.outputDirectoryURL(for: "   "))
    }

    func testFreshPickerDoesNotSetAnInitialDirectory() {
        XCTAssertNil(OutputDirectoryAccess.initialPanelDirectoryURL(storedPath: ""))
    }

    func testPickerCanReturnToAnExistingUserSelectedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(
            OutputDirectoryAccess.initialPanelDirectoryURL(
                storedPath: directory.path(percentEncoded: false)
            ),
            directory.standardizedFileURL
        )
    }

    func testPreservesUnresolvedBookmarkOnlyWhenExternalVolumeIsUnmounted() throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fakeVolumesRoot = sandboxRoot.appendingPathComponent("Volumes", isDirectory: true)
        let mountedDrive = fakeVolumesRoot.appendingPathComponent("MountedSSD", isDirectory: true)
        try FileManager.default.createDirectory(at: mountedDrive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let unmountedPath = fakeVolumesRoot
            .appendingPathComponent("UnpluggedSSD/ReplayMac", isDirectory: true)
            .path(percentEncoded: false)
        XCTAssertTrue(
            OutputDirectoryAccess.shouldPreserveUnresolvedBookmark(
                storedPath: unmountedPath,
                volumesRootURL: fakeVolumesRoot
            )
        )

        let deletedFolderOnMountedDrive = mountedDrive
            .appendingPathComponent("DeletedClips", isDirectory: true)
            .path(percentEncoded: false)
        XCTAssertFalse(
            OutputDirectoryAccess.shouldPreserveUnresolvedBookmark(
                storedPath: deletedFolderOnMountedDrive,
                volumesRootURL: fakeVolumesRoot
            )
        )

        let deletedLocalFolder = sandboxRoot
            .appendingPathComponent("Users/test/Movies/DeletedClips", isDirectory: true)
            .path(percentEncoded: false)
        XCTAssertFalse(
            OutputDirectoryAccess.shouldPreserveUnresolvedBookmark(
                storedPath: deletedLocalFolder,
                volumesRootURL: fakeVolumesRoot
            )
        )
    }
}
