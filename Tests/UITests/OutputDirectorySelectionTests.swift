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
}
