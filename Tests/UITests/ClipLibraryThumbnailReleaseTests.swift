import XCTest
@preconcurrency import AVFoundation
import CoreVideo
@testable import UI

/// The clip library holds a decoded thumbnail per clip. They are released
/// while its window is hidden and brought back when it is shown again.
final class ClipLibraryThumbnailReleaseTests: XCTestCase {
    @MainActor
    func testThumbnailsAreReleasedWhileHiddenAndComeBackWhenShown() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.writeClip(to: directory.appendingPathComponent("first.mp4"))

        let model = ClipLibraryViewModel(outputDirectory: { directory }, thumbnailReleaseDelay: .milliseconds(20))
        await model.reload()
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertNotNil(model.rows.first?.thumbnail)
        let duration = try XCTUnwrap(model.rows.first?.info.duration)
        XCTAssertGreaterThan(duration, 0)

        model.setWindowVisible(false)
        try await waitUntil("thumbnails released") { model.rows.first?.thumbnail == nil }
        XCTAssertFalse(model.keepsThumbnails)
        // The clip itself stays listed, details included.
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.info.duration, duration)

        // A clip saved while the window is hidden is listed, still without
        // bringing any thumbnails back.
        try await Self.writeClip(to: directory.appendingPathComponent("second.mp4"))
        await model.reload()
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertTrue(model.rows.allSatisfy { $0.thumbnail == nil })
        XCTAssertTrue(model.rows.allSatisfy { $0.info.duration > 0 })

        model.setWindowVisible(true)
        try await waitUntil("thumbnails restored") {
            model.rows.count == 2 && model.rows.allSatisfy { $0.thumbnail != nil }
        }
        XCTAssertTrue(model.keepsThumbnails)
    }

    /// Closing the window and opening it again in passing must not throw the
    /// thumbnails away just to regenerate them.
    @MainActor
    func testReopeningBeforeTheDelayKeepsThumbnails() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.writeClip(to: directory.appendingPathComponent("clip.mp4"))

        let model = ClipLibraryViewModel(outputDirectory: { directory }, thumbnailReleaseDelay: .milliseconds(200))
        await model.reload()
        let thumbnail = try XCTUnwrap(model.rows.first?.thumbnail)

        model.setWindowVisible(false)
        model.setWindowVisible(true)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(model.keepsThumbnails)
        XCTAssertTrue(model.rows.first?.thumbnail === thumbnail)
    }

    // MARK: - Helpers

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    /// A real, tiny H.264 clip, so a thumbnail can actually be generated.
    private static func writeClip(to url: URL) async throws {
        let width = 128
        let height = 72
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<10 {
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(
                CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer),
                kCVReturnSuccess
            )
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
