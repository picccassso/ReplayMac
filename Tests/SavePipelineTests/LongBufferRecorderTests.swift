import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import Save

final class LongBufferRecorderTests: XCTestCase {
    private enum TestError: Error {
        case simulatedFinishFailure
        case simulatedExportFailure
        case couldNotCreatePixelBuffer(OSStatus)
        case couldNotCreateSampleBuffer(OSStatus)
    }

    private actor ExportGate {
        private var didStart = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func pauseExporter() async {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                didStart = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        func waitUntilStarted() async {
            if didStart {
                return
            }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor ExportObservation {
        private(set) var stagedURLs: [URL] = []

        func record(_ urls: [URL]) {
            stagedURLs = urls
        }

        func snapshot() -> [URL] {
            stagedURLs
        }
    }

    private actor StartSignal {
        private var didStart = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            didStart = true
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
        }

        func wait() async {
            if didStart {
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private actor ExportAttemptTracker {
        private var count = 0

        func next() -> Int {
            count += 1
            return count
        }
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
        let recorder = LongBufferRecorder(
            writerFinisher: { writerBox in
                let attempt = await tracker.record(ObjectIdentifier(writerBox.writer))
                writerBox.writer.cancelWriting()
                if attempt == 1 {
                    throw TestError.simulatedFinishFailure
                }
            },
            writerBuilder: { url, _, _ in
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                return LongBufferWriterComponents(
                    writer: writer,
                    videoInput: nil,
                    systemAudioInput: nil,
                    micInput: nil
                )
            }
        )

        await recorder.configure(
            enabled: true,
            maxDurationSeconds: 300,
            outputDirectory: outputDirectory
        )

        let sample = try makeVideoSample()
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

    func testExportUsesProtectedCopiesAndRejectsOverlappingSave() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let gate = ExportGate()
        let observation = ExportObservation()
        let recorder = makeFileBackedRecorder { segments, _, outputDirectory, _, _ in
            await observation.record(segments.map(\.url))
            await gate.pauseExporter()
            let outputURL = outputDirectory.appendingPathComponent("SuccessfulExport.mp4")
            try Data("export".utf8).write(to: outputURL)
            return outputURL
        }
        await recorder.configure(
            enabled: true,
            maxDurationSeconds: 120,
            outputDirectory: outputDirectory
        )

        await recorder.appendVideo(try makeVideoSample(pts: 0))
        await recorder.appendVideo(try makeVideoSample(pts: 61))

        let saveTask = Task {
            try await recorder.saveClip(lastSeconds: 120, outputDirectory: outputDirectory)
        }
        await gate.waitUntilStarted()

        let sourceURLs = try segmentFiles(in: outputDirectory)
        let stagedURLs = await observation.snapshot()
        XCTAssertEqual(sourceURLs.count, 2)
        XCTAssertEqual(stagedURLs.count, 2)
        XCTAssertTrue(stagedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(Set(sourceURLs).isDisjoint(with: Set(stagedURLs)))
        XCTAssertEqual(Set(sourceURLs.map(\.lastPathComponent)), Set(stagedURLs.map {
            String($0.lastPathComponent.dropFirst(4))
        }))

        do {
            _ = try await recorder.saveClip(lastSeconds: 120, outputDirectory: outputDirectory)
            XCTFail("A second long-buffer export should be rejected while one is running")
        } catch let error as LongBufferRecorderError {
            XCTAssertEqual(error, .longBufferExportAlreadyInProgress)
            XCTAssertEqual(error.localizedDescription, "A long replay is already saving.")
        } catch {
            XCTFail("Unexpected overlapping-export error: \(error)")
        }

        // Force the selected source segments beyond the retention window, then
        // request full recorder cleanup. Both deletion paths must defer the
        // selected files until the in-flight export releases them.
        await recorder.appendVideo(try makeVideoSample(pts: 500))
        XCTAssertTrue(sourceURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await recorder.stop(deleteSegments: true)
        XCTAssertTrue(sourceURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await recorder.configure(
            enabled: false,
            maxDurationSeconds: 120,
            outputDirectory: outputDirectory
        )
        XCTAssertTrue(
            sourceURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
            "Reconfiguration must not delete segments pinned by an active export"
        )

        await gate.release()
        let outputURL = try await saveTask.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(sourceURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(stagedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputDirectory.appendingPathComponent(".ReplayMacLongBufferExports").path
            )
        )
    }

    func testExportFailureCleansCopiesAndRestartsActiveWriter() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let gate = ExportGate()
        let observation = ExportObservation()
        let attempts = ExportAttemptTracker()
        let recorder = makeFileBackedRecorder { segments, _, outputDirectory, _, _ in
            await observation.record(segments.map(\.url))
            if await attempts.next() == 1 {
                await gate.pauseExporter()
                throw TestError.simulatedExportFailure
            }
            let outputURL = outputDirectory.appendingPathComponent("RecoveredExport.mp4")
            try Data("recovered export".utf8).write(to: outputURL)
            return outputURL
        }
        await recorder.configure(
            enabled: true,
            maxDurationSeconds: 300,
            outputDirectory: outputDirectory
        )
        await recorder.appendVideo(try makeVideoSample(pts: 0))

        let saveTask = Task {
            try await recorder.saveClip(lastSeconds: 300, outputDirectory: outputDirectory)
        }
        await gate.waitUntilStarted()

        let stagedURLs = await observation.snapshot()
        XCTAssertEqual(stagedURLs.count, 1)
        XCTAssertTrue(stagedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // Recording continues during export. This active segment must be reset
        // when the export fails so it cannot poison the next save.
        await recorder.appendVideo(try makeVideoSample(pts: 10))
        XCTAssertEqual(try segmentFiles(in: outputDirectory).count, 2)

        await gate.release()
        do {
            _ = try await saveTask.value
            XCTFail("The injected export failure should be returned")
        } catch TestError.simulatedExportFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected export error: \(error)")
        }

        XCTAssertTrue(stagedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputDirectory.appendingPathComponent(".ReplayMacLongBufferExports").path
            )
        )
        XCTAssertEqual(
            try segmentFiles(in: outputDirectory).count,
            1,
            "The active partial segment should be removed while the completed source remains"
        )

        await recorder.appendVideo(try makeVideoSample(pts: 11))
        XCTAssertEqual(
            try segmentFiles(in: outputDirectory).count,
            2,
            "The next sample should immediately start a fresh writer"
        )
        let recoveredOutput = try await recorder.saveClip(
            lastSeconds: 300,
            outputDirectory: outputDirectory
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recoveredOutput.path),
            "A save following export recovery should succeed without restarting the app"
        )
        await recorder.stop(deleteSegments: true)
    }

    func testCancellationReleasesPinsAndDeletesPendingSegments() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let signal = StartSignal()
        let recorder = makeFileBackedRecorder { _, _, _, _, _ in
            await signal.markStarted()
            try await Task.sleep(for: .seconds(60))
            throw TestError.simulatedExportFailure
        }
        await recorder.configure(
            enabled: true,
            maxDurationSeconds: 300,
            outputDirectory: outputDirectory
        )
        await recorder.appendVideo(try makeVideoSample(pts: 0))

        let saveTask = Task {
            try await recorder.saveClip(lastSeconds: 300, outputDirectory: outputDirectory)
        }
        await signal.wait()

        let sourceURLs = try segmentFiles(in: outputDirectory)
        XCTAssertEqual(sourceURLs.count, 1)
        await recorder.stop(deleteSegments: true)
        XCTAssertTrue(sourceURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        saveTask.cancel()
        do {
            _ = try await saveTask.value
            XCTFail("The cancelled export should throw cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        XCTAssertTrue(
            sourceURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
            "Deferred deletion should run when cancellation releases the final pin"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputDirectory.appendingPathComponent(".ReplayMacLongBufferExports").path
            )
        )
    }

    func testConfigureRemovesOnlyOrphanedReplayMacSegments() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let segmentDirectory = outputDirectory
            .appendingPathComponent(".ReplayMacLongBuffer", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let orphan = segmentDirectory.appendingPathComponent("ReplayMac_LongBuffer_stale.mp4")
        let unrelated = segmentDirectory.appendingPathComponent("KeepMe.mp4")
        let similarlyNamedDirectory = segmentDirectory
            .appendingPathComponent("ReplayMac_LongBuffer_folder.mp4", isDirectory: true)
        try Data("orphan".utf8).write(to: orphan)
        try Data("user file".utf8).write(to: unrelated)
        try FileManager.default.createDirectory(at: similarlyNamedDirectory, withIntermediateDirectories: true)

        let recorder = makeFileBackedRecorder { _, _, outputDirectory, _, _ in
            outputDirectory.appendingPathComponent("unused.mp4")
        }
        await recorder.configure(
            enabled: true,
            maxDurationSeconds: 300,
            outputDirectory: outputDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: similarlyNamedDirectory.path))
    }

    private func makeFileBackedRecorder(
        clipExporter: @escaping LongBufferRecorder.ClipExporter
    ) -> LongBufferRecorder {
        LongBufferRecorder(
            writerFinisher: { _ in },
            writerBuilder: { url, _, _ in
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                try Data("segment".utf8).write(to: url)
                return LongBufferWriterComponents(
                    writer: writer,
                    videoInput: nil,
                    systemAudioInput: nil,
                    micInput: nil
                )
            },
            clipExporter: clipExporter
        )
    }

    private func segmentFiles(in outputDirectory: URL) throws -> [URL] {
        let segmentDirectory = outputDirectory
            .appendingPathComponent(".ReplayMacLongBuffer", isDirectory: true)
        guard FileManager.default.fileExists(atPath: segmentDirectory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: segmentDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "mp4" }
    }

    private func makeVideoSample(pts: Double = 1.0 / 30.0) throws -> LongBufferSample {
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
            throw TestError.couldNotCreatePixelBuffer(pixelStatus)
        }

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw TestError.couldNotCreateSampleBuffer(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 600),
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
            throw TestError.couldNotCreateSampleBuffer(sampleStatus)
        }
        return LongBufferSample(sampleBuffer)
    }
}
