import XCTest
import CoreGraphics
@preconcurrency import AVFoundation
import CoreVideo
import ImageIO
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
    }

    @MainActor
    private func writeTestVideo(to url: URL, size: CGSize) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
        )
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
        guard writer.startWriting() else {
            throw writer.error ?? TestVideoError.cannotStartWriter
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<2 {
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
                memset(baseAddress, frameIndex == 0 ? 0x33 : 0x99, CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: 30)
            ) else {
                throw writer.error ?? TestVideoError.cannotAppendFrame
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? TestVideoError.cannotFinishWriter
        }
    }
}

private enum TestVideoError: Error {
    case cannotAddInput
    case cannotStartWriter
    case cannotCreatePixelBuffer
    case cannotAppendFrame
    case cannotFinishWriter
}
