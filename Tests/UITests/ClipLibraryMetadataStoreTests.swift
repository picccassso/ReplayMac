import XCTest
@testable import UI

final class ClipLibraryMetadataStoreTests: XCTestCase {
    func testLoadMigratesLegacyReplayMacMetadataFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent(".ReplayMacClipLibrary.json")
        let metadata = [
            "/tmp/clip.mp4": ClipUserMetadata(
                displayName: "Highlight",
                isFavorite: true,
                tags: ["game"],
                notes: "Legacy metadata"
            )
        ]
        try JSONEncoder().encode(metadata).write(to: legacyURL)

        XCTAssertEqual(ClipLibraryMetadataStore.load(in: directory), metadata)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".ReplayCapClipLibrary.json").path
            )
        )
    }

    func testUnreadableMetadataIsBackedUpBeforeItCanBeOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadataURL = ClipLibraryMetadataStore.metadataURL(in: directory)
        let unreadable = Data("{\"/tmp/clip.mp4\": {\"displayName\": ".utf8)
        try unreadable.write(to: metadataURL)

        XCTAssertEqual(ClipLibraryMetadataStore.load(in: directory), [:])

        // The library saves right after loading; the original bytes must survive that.
        ClipLibraryMetadataStore.save([:], in: directory)
        let backupURL = ClipLibraryMetadataStore.unreadableBackupURL(for: metadataURL)
        XCTAssertEqual(try Data(contentsOf: backupURL), unreadable)
    }

    func testMissingMetadataFileLoadsEmptyWithoutBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(ClipLibraryMetadataStore.load(in: directory), [:])
        let backupURL = ClipLibraryMetadataStore.unreadableBackupURL(
            for: ClipLibraryMetadataStore.metadataURL(in: directory)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }
}
