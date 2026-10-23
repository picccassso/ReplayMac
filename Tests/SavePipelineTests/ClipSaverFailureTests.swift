import XCTest
@preconcurrency import AVFoundation
import CoreVideo
import Encode
import RingBuffer
@testable import Save

final class ClipSaverFailureTests: XCTestCase {
    /// Regression: a save that failed partway through used to leave a broken,
    /// unplayable .mp4 in the clips folder.
    func testFailedSaveRemovesPartialFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let encoded = try encodeFrames(count: 30)
        XCTAssertFalse(encoded.isEmpty)

        // Feeding the same frames twice makes timestamps jump backwards halfway
        // through, which AVAssetWriter rejects after the file has been started.
        let buffer = VideoRingBuffer(timeCap: 100)
        for sample in encoded + encoded {
            buffer.append(encodedSample: sample)
        }

        let saver = ClipSaver(videoRingBuffer: buffer)
        do {
            let url = try await saver.saveClip(lastSeconds: 100, outputDirectory: folder)
            XCTFail("Expected the save to fail, but it wrote \(url.lastPathComponent)")
        } catch {
            // expected
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(leftovers, [], "Failed save must not leave a partial clip behind")
    }

    private func encodeFrames(count: Int) throws -> [CMSampleBuffer] {
        let buffer = VideoRingBuffer(timeCap: 100)
        let encoder = VideoEncoder()
        defer { encoder.stop() }
        encoder.outputHandler = { buffer.append(encodedSample: $0) }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264)
        for index in 0..<count {
            encoder.encode(sampleBuffer: try frame(index: index))
        }
        encoder.stop() // Flush delayed frames.
        return buffer.samples(last: 100)
    }

    private func frame(index: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) {
            memset(base, Int32(index * 8 % 256), CVPixelBufferGetDataSize(image))
        }
        CVPixelBufferUnlockBaseAddress(image, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(30 + index), timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: image,
            formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return try XCTUnwrap(sample)
    }
}
