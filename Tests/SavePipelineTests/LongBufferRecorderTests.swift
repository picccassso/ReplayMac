import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import Encode
@testable import Save

final class LongBufferRecorderTests: XCTestCase {
    private enum TestError: Error {
        case simulatedFinishFailure
        case couldNotCreatePixelBuffer(OSStatus)
        case couldNotCreateSampleBuffer(OSStatus)
        case encoderProducedNoSample
    }

    private actor FinishAttemptTracker {
        private(set) var writerIDs: [ObjectIdentifier] = []

        func record(_ writerID: ObjectIdentifier) -> Int {
            writerIDs.append(writerID)
            return writerIDs.count
        }

        func snapshot() -> [ObjectIdentifier] {
            writerIDs
        }
    }

    func testFinishFailureDoesNotPoisonNextSegment() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let tracker = FinishAttemptTracker()
        let recorder = LongBufferRecorder { writerBox in
            let attempt = await tracker.record(ObjectIdentifier(writerBox.writer))
            writerBox.writer.cancelWriting()
            if attempt == 1 {
                throw TestError.simulatedFinishFailure
            }
        }

        await recorder.configure(
            enabled: true,
            maxDurationSeconds: 300,
            outputDirectory: outputDirectory
        )

        let sample = try await makeEncodedVideoSample()
        await recorder.appendVideo(sample)
        await recorder.stop()

        let segmentDirectory = outputDirectory
            .appendingPathComponent(".ReplayMacLongBuffer", isDirectory: true)
        let filesAfterFailure = try FileManager.default.contentsOfDirectory(
            at: segmentDirectory,
            includingPropertiesForKeys: nil
        )
        let partialSegments = filesAfterFailure.filter { $0.pathExtension == "mp4" }
        XCTAssertTrue(
            partialSegments.isEmpty,
            "A failed partial segment should be deleted; found \(partialSegments.map(\.lastPathComponent))"
        )

        // A new sample must create a new AVAssetWriter. Before the fix, the
        // failed writer remained installed and every later save retried it.
        await recorder.appendVideo(sample)
        await recorder.stop()

        let writerIDs = await tracker.snapshot()
        XCTAssertEqual(writerIDs.count, 2)
        XCTAssertNotEqual(writerIDs[0], writerIDs[1])

        await recorder.stop(deleteSegments: true)
    }

    func testRealWriterCanFinalizeAndStartAnotherSegment() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let recorder = LongBufferRecorder()
        await recorder.configure(
            enabled: true,
            maxDurationSeconds: 300,
            outputDirectory: outputDirectory
        )

        let sample = try await makeEncodedVideoSample()
        await recorder.appendVideo(sample)
        await recorder.stop()
        await recorder.appendVideo(sample)
        await recorder.stop()

        let segmentDirectory = outputDirectory
            .appendingPathComponent(".ReplayMacLongBuffer", isDirectory: true)
        let segmentURLs = try FileManager.default.contentsOfDirectory(
            at: segmentDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "mp4" }

        XCTAssertEqual(segmentURLs.count, 2)
        for segmentURL in segmentURLs {
            let videoTracks = try await AVURLAsset(url: segmentURL).loadTracks(withMediaType: .video)
            XCTAssertEqual(videoTracks.count, 1)
        }

        await recorder.stop(deleteSegments: true)
    }

    private func makeEncodedVideoSample() async throws -> LongBufferSample {
        let encoder = VideoEncoder()
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 500_000)

        let stream = AsyncStream<LongBufferSample> { continuation in
            encoder.outputHandler = { sample in
                continuation.yield(LongBufferSample(sample))
                continuation.finish()
            }
        }

        var pixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            encoder.stop()
            throw TestError.couldNotCreatePixelBuffer(pixelStatus)
        }

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            encoder.stop()
            throw TestError.couldNotCreateSampleBuffer(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 1, timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            encoder.stop()
            throw TestError.couldNotCreateSampleBuffer(sampleStatus)
        }

        encoder.encode(sampleBuffer: sampleBuffer)
        encoder.stop()

        for await sample in stream {
            return sample
        }
        throw TestError.encoderProducedNoSample
    }
}
