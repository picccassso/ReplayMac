import XCTest
import AVFoundation
@testable import Save
@testable import RingBuffer

final class SavePipelineTests: XCTestCase {

    // MARK: - ClipMetadata Tests

    func testDefaultOutputDirectory() {
        let dir = ClipMetadata.defaultOutputDirectory
        XCTAssertTrue(dir.path.contains("Movies/ReplayMac"))
    }

    func testCreateOutputDirectoryIfNeeded() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))

        try ClipMetadata.createOutputDirectoryIfNeeded(tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testGenerateUniqueFileURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url1 = try ClipMetadata.generateUniqueFileURL(in: tempDir)
        XCTAssertTrue(url1.lastPathComponent.hasPrefix("ReplayMac_"))
        XCTAssertTrue(url1.pathExtension == "mp4")

        try Data().write(to: url1)
        let url2 = try ClipMetadata.generateUniqueFileURL(in: tempDir)
        XCTAssertNotEqual(url1, url2)
        XCTAssertTrue(url2.lastPathComponent.contains("_1"))
    }

    func testScanClips() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("test.mp4")
        try Data([0x00, 0x00]).write(to: url)

        let clips = ClipMetadata.scanClips(in: tempDir)
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?.fileURL.lastPathComponent, "test.mp4")
    }

    func testMakeMetadataItems() {
        let items = ClipMetadata.makeMetadataItems()
        XCTAssertEqual(items.count, 2)

        let values = items.compactMap { $0.stringValue }
        XCTAssertTrue(values.contains("ReplayMac"))
        // ISO8601 date string contains 'T' separator
        XCTAssertTrue(values.contains { $0.contains("T") })
    }

    // MARK: - ClipSaver Tests

    func testSaveClipThrowsNoSamples() async {
        let ringBuffer = VideoRingBuffer()
        let saver = ClipSaver(videoRingBuffer: ringBuffer)
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            _ = try await saver.saveClip(lastSeconds: 30, outputDirectory: outputDir)
            XCTFail("Expected noSamples error")
        } catch ClipSaveError.noSamples {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
