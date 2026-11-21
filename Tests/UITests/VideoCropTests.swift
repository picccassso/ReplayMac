import XCTest
import CoreGraphics
@preconcurrency import AVFoundation
import CoreVideo
import ImageIO
import AppKit
import QuartzCore
@testable import UI

final class VideoCropTests: XCTestCase {
    func test1440pLandscapeFitsExactlyInto1080p() {
        let output = TrimExportResolution.fullHD.outputSize(
            for: CGSize(width: 2560, height: 1440)
        )

        XCTAssertEqual(output, CGSize(width: 1920, height: 1080))
    }

    func testPortrait1080pPreservesOrientation() {
        let output = TrimExportResolution.fullHD.outputSize(
            for: CGSize(width: 1440, height: 2560)
        )

        XCTAssertEqual(output, CGSize(width: 1080, height: 1920))
    }

    func test1080pHighEstimateKeepsSixtySecondClipUnderDiscordLimit() {
        let output = CGSize(width: 1920, height: 1080)
        let estimate = TrimExportEstimate.bytes(
            durationSeconds: 60,
            quality: .high,
            outputSize: output,
            audioTrackCount: 1,
            sourceTotalBitrateMbps: 0
        )

        XCTAssertLessThan(estimate, TrimExportEstimate.discordLimitBytes)
        XCTAssertGreaterThan(estimate, 90_000_000)
    }

    func testEstimateAccountsForEveryRetainedAudioTrack() {
        let output = CGSize(width: 1920, height: 1080)
        let oneTrack = TrimExportEstimate.bytes(
            durationSeconds: 60,
            quality: .balanced,
            outputSize: output,
            audioTrackCount: 1,
            sourceTotalBitrateMbps: 0
        )
        let twoTracks = TrimExportEstimate.bytes(
            durationSeconds: 60,
            quality: .balanced,
            outputSize: output,
            audioTrackCount: 2,
            sourceTotalBitrateMbps: 0
        )

        XCTAssertGreaterThan(twoTracks, oneTrack)
    }

    func testNormalizedCropClampsToVideoBounds() {
        let crop = NormalizedVideoCrop(CGRect(x: -0.2, y: 0.25, width: 0.7, height: 1))

        XCTAssertEqual(crop.rect.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(crop.rect.minY, 0.25, accuracy: 0.0001)
        XCTAssertEqual(crop.rect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(crop.rect.height, 0.75, accuracy: 0.0001)
    }

    func testPixelCropUsesEvenEncoderDimensions() {
        let crop = NormalizedVideoCrop(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let rect = VideoCropper.pixelRect(for: crop, displaySize: CGSize(width: 1919, height: 1079))

        XCTAssertEqual(rect.origin.x, 479)
        XCTAssertEqual(rect.origin.y, 269)
        XCTAssertEqual(rect.width, 958)
        XCTAssertEqual(rect.height, 538)
        XCTAssertEqual(rect.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(rect.height.truncatingRemainder(dividingBy: 2), 0)
    }

    func testGeometryNormalizesNinetyDegreePreferredTransform() {
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let geometry = VideoCropper.geometry(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: transform
        )

        XCTAssertEqual(geometry.displaySize.width, 1080, accuracy: 0.0001)
        XCTAssertEqual(geometry.displaySize.height, 1920, accuracy: 0.0001)
        let displayedBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            .applying(geometry.orientationTransform)
            .standardized
        XCTAssertEqual(displayedBounds.origin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(displayedBounds.origin.y, 0, accuracy: 0.0001)
    }

    func testSquarePresetIsSquareInDisplayedPixels() {
        let videoSize = CGSize(width: 1920, height: 1080)
        let crop = CropAspectPreset.square.cropRect(for: videoSize)

        XCTAssertEqual(crop.width * videoSize.width, crop.height * videoSize.height, accuracy: 0.0001)
        XCTAssertEqual(crop.midX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(crop.midY, 0.5, accuracy: 0.0001)
    }

    func testAspectFitRectCentersLetterboxedVideo() {
        let fitted = VideoCropSelectionMath.aspectFitRect(
            contentSize: CGSize(width: 16, height: 9),
            in: CGRect(x: 0, y: 0, width: 600, height: 600)
        )

        XCTAssertEqual(fitted.width, 600, accuracy: 0.0001)
        XCTAssertEqual(fitted.height, 337.5, accuracy: 0.0001)
        XCTAssertEqual(fitted.minY, 131.25, accuracy: 0.0001)
    }

    func testGIFFrameCropAndScaleUsesSelectedAspectRatio() throws {
        guard let context = CGContext(
            data: nil,
            width: 160,
            height: 120,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            return XCTFail("Could not create test image")
        }
        let crop = NormalizedVideoCrop(CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let output = GIFExporter.croppedAndScaled(image, crop: crop, maxWidth: 40)

        XCTAssertEqual(output?.width, 40)
        XCTAssertEqual(output?.height, 60)
    }

    @MainActor
    func testVideoCompositionExportsCroppedDimensions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapCropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.mp4")
        let outputURL = directory.appendingPathComponent("cropped.mp4")
        try await writeTestVideo(to: sourceURL, size: CGSize(width: 160, height: 120))

        let asset = AVURLAsset(url: sourceURL)
        let crop = NormalizedVideoCrop(CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let videoComposition = try await VideoCropper.videoComposition(for: asset, crop: crop)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            return XCTFail("Could not create test export session")
        }
        exporter.videoComposition = videoComposition
        try await exporter.export(to: outputURL, as: .mp4)

        let resultGeometry = try await VideoCropper.geometry(for: AVURLAsset(url: outputURL))
        XCTAssertEqual(resultGeometry.displaySize.width, 80, accuracy: 0.5)
        XCTAssertEqual(resultGeometry.displaySize.height, 120, accuracy: 0.5)
    }

    @MainActor
    func testControlledExportWritesHEVCAtRequestedSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapControlledExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.mp4")
        let outputURL = directory.appendingPathComponent("output.mp4")
        try await writeTestVideo(to: sourceURL, size: CGSize(width: 2560, height: 1440))

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let outputSize = TrimExportResolution.fullHD.outputSize(
            for: CGSize(width: 2560, height: 1440)
        )
        let composition = try await VideoCropper.videoComposition(
            for: asset,
            crop: .fullFrame,
            outputSize: outputSize
        )
        try await TrimVideoTranscoder().export(
            asset: asset,
            timeRange: CMTimeRange(start: .zero, duration: duration),
            videoComposition: composition,
            outputSize: outputSize,
            videoBitrateMbps: 8,
            to: outputURL
        )

        let outputAsset = AVURLAsset(url: outputURL)
        let resultGeometry = try await VideoCropper.geometry(for: outputAsset)
        let tracks = try await outputAsset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(formatDescriptions.first)
        let codec = CMFormatDescriptionGetMediaSubType(description)

        XCTAssertEqual(resultGeometry.displaySize.width, 1920, accuracy: 0.5)
        XCTAssertEqual(resultGeometry.displaySize.height, 1080, accuracy: 0.5)
        XCTAssertTrue(codec == kCMVideoCodecType_HEVC)
    }

    @MainActor
    func testDirectUncroppedTranscodeScalesTrimsPassesAACThroughAndReportsProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapDirectTranscodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.mp4")
        let outputURL = directory.appendingPathComponent("output.mp4")
        try await writeTestVideo(
            to: sourceURL,
            size: CGSize(width: 640, height: 360),
            frameCount: 60,
            includeAACAudio: true
        )

        let asset = AVURLAsset(url: sourceURL)
        let outputSize = CGSize(width: 320, height: 180)
        let trimRange = CMTimeRangeFromTimeToTime(
            start: CMTime(seconds: 0.4, preferredTimescale: 600),
            end: CMTime(seconds: 1.6, preferredTimescale: 600)
        )
        let transcoder = TrimVideoTranscoder()
        try await transcoder.export(
            asset: asset,
            timeRange: trimRange,
            videoComposition: nil,
            outputSize: outputSize,
            videoBitrateMbps: 2,
            to: outputURL
        )

        XCTAssertEqual(transcoder.progress, 1.0, accuracy: 0.001)

        let outputAsset = AVURLAsset(url: outputURL)
        let resultGeometry = try await VideoCropper.geometry(for: outputAsset)
        XCTAssertEqual(resultGeometry.displaySize.width, 320, accuracy: 0.5)
        XCTAssertEqual(resultGeometry.displaySize.height, 180, accuracy: 0.5)

        let outputDuration = try await outputAsset.load(.duration).seconds
        XCTAssertEqual(outputDuration, 1.2, accuracy: 0.15)

        let videoTracks = try await outputAsset.loadTracks(withMediaType: .video)
        let videoFormats = try await videoTracks.first?.load(.formatDescriptions)
        let videoFormat = try XCTUnwrap(videoFormats?.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(videoFormat), kCMVideoCodecType_HEVC)

        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let audioFormats = try await audioTracks.first?.load(.formatDescriptions)
        let audioFormat = try XCTUnwrap(audioFormats?.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(audioFormat), kAudioFormatMPEG4AAC)
    }

    @MainActor
    func testDirectAndCroppedTranscodesPreserveVFRFrameCount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapVFRTranscodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("vfr.mp4")
        // 12 frames at 60 fps (0.0s ..< 0.2s) + 8 frames at 4 fps (0.25s .. 2.0s) = 20 frames.
        var frameTimes = (0..<12).map { CMTime(value: CMTimeValue($0), timescale: 60) }
        for index in 1...8 {
            frameTimes.append(CMTime(value: CMTimeValue(index), timescale: 4))
        }
        try await writeTestVideo(to: sourceURL, size: CGSize(width: 320, height: 180), frameTimes: frameTimes)

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: duration)

        let directURL = directory.appendingPathComponent("direct.mp4")
        try await TrimVideoTranscoder().export(
            asset: asset,
            timeRange: fullRange,
            videoComposition: nil,
            outputSize: CGSize(width: 160, height: 90),
            videoBitrateMbps: 2,
            to: directURL
        )
        let directCount = try await countVideoFrames(in: directURL)
        XCTAssertEqual(directCount, frameTimes.count)

        let croppedURL = directory.appendingPathComponent("cropped.mp4")
        let crop = NormalizedVideoCrop(CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let croppedSize = CGSize(width: 160, height: 180)
        let composition = try await VideoCropper.videoComposition(for: asset, crop: crop, outputSize: croppedSize)
        try await TrimVideoTranscoder().export(
            asset: asset,
            timeRange: fullRange,
            videoComposition: composition,
            outputSize: croppedSize,
            videoBitrateMbps: 2,
            to: croppedURL
        )
        let croppedCount = try await countVideoFrames(in: croppedURL)
        XCTAssertEqual(croppedCount, frameTimes.count)
    }

    @MainActor
    func testDirectTranscodeFallsBackToCompositionForRotatedTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapRotatedTranscodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("rotated.mp4")
        let outputURL = directory.appendingPathComponent("portrait.mp4")
        try await writeTestVideo(
            to: sourceURL,
            size: CGSize(width: 320, height: 180),
            frameCount: 6,
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        )

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let outputSize = CGSize(width: 90, height: 160)
        try await TrimVideoTranscoder().export(
            asset: asset,
            timeRange: CMTimeRange(start: .zero, duration: duration),
            videoComposition: nil,
            outputSize: outputSize,
            videoBitrateMbps: 2,
            to: outputURL
        )

        let resultGeometry = try await VideoCropper.geometry(for: AVURLAsset(url: outputURL))
        XCTAssertEqual(resultGeometry.displaySize.width, 90, accuracy: 0.5)
        XCTAssertEqual(resultGeometry.displaySize.height, 160, accuracy: 0.5)
    }

    @MainActor
    func testGIFExporterWritesCroppedFrameDimensions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapGIFCropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.mp4")
        let outputURL = directory.appendingPathComponent("cropped.gif")
        try await writeTestVideo(to: sourceURL, size: CGSize(width: 160, height: 120))
        try await GIFExporter.export(
            sourceURL: sourceURL,
            startSeconds: 0,
            endSeconds: 0.03,
            maxWidth: 40,
            crop: NormalizedVideoCrop(CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            to: outputURL
        )

        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("Could not read exported GIF frame")
        }
        XCTAssertEqual(frame.width, 40)
        XCTAssertEqual(frame.height, 60)
    }

    @MainActor
    func testTrimPreviewAssetUsesSelectedDurationAndZeroBasedTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapTrimPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.mp4")
        try await writeTestVideo(to: sourceURL, size: CGSize(width: 160, height: 120))

        let source = AVURLAsset(url: sourceURL)
        let preview = try await TrimPreviewAsset.make(
            from: source,
            startSeconds: 0.01,
            endSeconds: 0.04
        )
        let previewDuration = try await preview.load(.duration)
        let previewTracks = try await preview.loadTracks(withMediaType: .video)
        let sourceTracks = try await source.loadTracks(withMediaType: .video)
        let previewTrackRange = try await previewTracks.first?.load(.timeRange)

        XCTAssertEqual(CMTimeGetSeconds(previewDuration), 0.03, accuracy: 0.001)
        XCTAssertEqual(previewTracks.count, 1)
        XCTAssertEqual(previewTrackRange?.start, .zero)
        XCTAssertEqual(previewTracks.first?.trackID, sourceTracks.first?.trackID)

        let player = AVPlayer(playerItem: AVPlayerItem(asset: preview))
        TrimPreviewAsset.restoreSource(to: player, url: sourceURL)
        let editingAsset = try XCTUnwrap(player.currentItem?.asset)
        let editingDuration = try await editingAsset.load(.duration)
        XCTAssertGreaterThan(editingDuration.seconds, 0.04)
        XCTAssertEqual((editingAsset as? AVURLAsset)?.url, sourceURL)
        // The new item contains the source before and after the prior selection.
        XCTAssertGreaterThan(editingDuration.seconds, 0.05)
        let expandedPreview = try await TrimPreviewAsset.make(
            from: source, startSeconds: 0, endSeconds: 0.05)
        let expandedDuration = try await expandedPreview.load(.duration)
        XCTAssertEqual(expandedDuration.seconds, 0.05, accuracy: 0.001)
    }

    @MainActor
    func testShortGIFEstimateMatchesActualCroppedExportAndCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapGIFEstimateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp4")
        let outputURL = directory.appendingPathComponent("sample.gif")
        try await writeTestVideo(to: sourceURL, size: CGSize(width: 160, height: 120))
        let crop = NormalizedVideoCrop(CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let estimate = try await GIFExporter.estimateBytes(
            sourceURL: sourceURL, startSeconds: 0, endSeconds: 0.03, maxWidth: 40, crop: crop)
        try await GIFExporter.export(sourceURL: sourceURL, startSeconds: 0, endSeconds: 0.03,
                                     maxWidth: 40, crop: crop, to: outputURL)
        let actual = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(estimate, Int64(try XCTUnwrap(actual)))
        let cancelled = Task {
            try await GIFExporter.estimateBytes(sourceURL: sourceURL, startSeconds: 0, endSeconds: 0.03)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled GIF estimation must not produce a result")
        } catch is CancellationError {
        }
    }

    @MainActor
    func testCropPlayerCanReleaseItsLayerRepeatedly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapPlayerTeardownTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp4")
        try await writeTestVideo(to: sourceURL, size: CGSize(width: 160, height: 120))
        for _ in 0..<3 {
            autoreleasepool {
                let view = TrimNativePlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
                view.player = AVPlayer(url: sourceURL)
                view.layoutSubtreeIfNeeded()
                _ = view.videoBounds
                view.player = nil
            }
            // AVPlayerLayer deallocation occurs during the transaction flush. An
            // external dependent-key observer previously caused an exception here.
            CATransaction.flush()
        }
    }

    @MainActor
    func testGIFKeepsRepeatedFramesAndSampledDuration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapGIFTimingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let output = directory.appendingPathComponent("output.gif")
        try await writeTestVideo(to: source, size: CGSize(width: 160, height: 120), frameCount: 240)
        try await GIFExporter.export(sourceURL: source, startSeconds: 0, endSeconds: 8,
                                     maxWidth: 160, to: output)
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 96)
        var duration = 0.0
        for index in 0..<CGImageSourceGetCount(gif) {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(gif, index, nil) as? [String: Any])
            let timing = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            duration += try XCTUnwrap(timing[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
        }
        // GIF stores centiseconds; the 12 fps target rounds to 0.08 s per frame.
        XCTAssertEqual(duration, 7.68, accuracy: 0.001)
    }

    @MainActor
    func testControlledExportCancellationReleasesDrainTasks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayCapExportCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let output = directory.appendingPathComponent("cancelled.mp4")
        let size = CGSize(width: 320, height: 180)
        try await writeTestVideo(to: source, size: size, frameCount: 600)
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let composition = try await VideoCropper.videoComposition(for: asset, crop: .fullFrame, outputSize: size)
        let transcoder = TrimVideoTranscoder()
        let stopped = expectation(description: "Cancelled export returns without waiting for another readiness callback")
        let exporting = Task {
            do {
                try await transcoder.export(asset: asset,
                    timeRange: CMTimeRange(start: .zero, duration: duration),
                    videoComposition: composition, outputSize: size, videoBitrateMbps: 2, to: output)
                XCTFail("A cancelled export must not succeed")
            } catch is CancellationError {
                // Expected, including cancellation during writer setup.
            } catch {
                XCTFail("Unexpected cancellation result: \(error)")
            }
            stopped.fulfill()
        }
        // Writer creation leaves the destination file before draining begins.
        // Wait for that boundary so cancellation also exercises setup races.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: output.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(20))
        transcoder.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        exporting.cancel()

        let cancelledBeforeStart = TrimVideoTranscoder()
        cancelledBeforeStart.cancel()
        do {
            try await cancelledBeforeStart.export(asset: asset,
                timeRange: CMTimeRange(start: .zero, duration: duration),
                videoComposition: composition, outputSize: size, videoBitrateMbps: 2,
                to: directory.appendingPathComponent("never-started.mp4"))
            XCTFail("Cancellation before setup must also be retained")
        } catch is CancellationError { }
    }

    @MainActor
    private func writeTestVideo(
        to url: URL,
        size: CGSize,
        frameCount: Int = 2,
        includeAACAudio: Bool = false,
        transform: CGAffineTransform = .identity
    ) async throws {
        let times = (0..<frameCount).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        try await writeTestVideo(
            to: url,
            size: size,
            frameTimes: times,
            includeAACAudio: includeAACAudio,
            transform: transform
        )
    }

    @MainActor
    private func writeTestVideo(
        to url: URL,
        size: CGSize,
        frameTimes: [CMTime],
        includeAACAudio: Bool = false,
        transform: CGAffineTransform = .identity
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
        )
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        guard writer.canAdd(input) else {
            throw TestVideoError.cannotAddInput
        }
        writer.add(input)

        var audioInput: AVAssetWriterInput?
        if includeAACAudio {
            let audio = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000
                ]
            )
            guard writer.canAdd(audio) else {
                throw TestVideoError.cannotAddInput
            }
            writer.add(audio)
            audioInput = audio
        }

        guard writer.startWriting() else {
            throw writer.error ?? TestVideoError.cannotStartWriter
        }
        writer.startSession(atSourceTime: .zero)

        for (frameIndex, pts) in frameTimes.enumerated() {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? TestVideoError.cannotAppendFrame }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw TestVideoError.cannotCreatePixelBuffer
            }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer else {
                throw TestVideoError.cannotCreatePixelBuffer
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(baseAddress, frameIndex % 2 == 0 ? 0x33 : 0x99, CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw writer.error ?? TestVideoError.cannotAppendFrame
            }
        }
        input.markAsFinished()

        if let audioInput {
            let durationSeconds = max(0.1, (frameTimes.last?.seconds ?? 0) + (1.0 / 30.0))
            try await appendSilentPCM(to: audioInput, writer: writer, durationSeconds: durationSeconds)
            audioInput.markAsFinished()
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? TestVideoError.cannotFinishWriter
        }
    }

    @MainActor
    private func appendSilentPCM(
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        durationSeconds: Double
    ) async throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else {
            throw TestVideoError.cannotCreatePixelBuffer
        }

        let totalSamples = Int((durationSeconds * 48_000).rounded(.up))
        var written = 0
        while written < totalSamples {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? TestVideoError.cannotAppendFrame }
                try await Task.sleep(for: .milliseconds(1))
            }
            let count = min(1024, totalSamples - written)
            var blockBuffer: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: count * 4,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: count * 4,
                flags: 0,
                blockBufferOut: &blockBuffer
            ) == noErr, let blockBuffer else {
                throw TestVideoError.cannotCreatePixelBuffer
            }
            CMBlockBufferFillDataBytes(
                with: 0,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: count * 4
            )
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: 48_000),
                decodeTimeStamp: .invalid
            )
            var sampleSize = 4
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: format,
                sampleCount: count,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sample
            ) == noErr, let sample else {
                throw TestVideoError.cannotCreatePixelBuffer
            }
            guard input.append(sample) else {
                throw writer.error ?? TestVideoError.cannotAppendFrame
            }
            written += count
        }
    }

    @MainActor
    private func countVideoFrames(in url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while output.copyNextSampleBuffer() != nil {
            count += 1
        }
        return count
    }
}

private enum TestVideoError: Error {
    case cannotAddInput
    case cannotStartWriter
    case cannotCreatePixelBuffer
    case cannotAppendFrame
    case cannotFinishWriter
}
