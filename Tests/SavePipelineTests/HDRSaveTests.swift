import XCTest
@preconcurrency import AVFoundation
import CoreVideo
import Encode
import RingBuffer
@testable import Save
@testable import UI

final class HDRSaveTests: XCTestCase {
    func testHDRSurvivesReplaySaveRemuxAndTranscode() async throws {
        #if !arch(arm64)
        throw XCTSkip("HDR capture requires Apple silicon")
        #endif
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let buffer = VideoRingBuffer()
        let encoder = VideoEncoder()
        defer { encoder.stop() }
        encoder.outputHandler = { buffer.append(encodedSample: $0) }
        try encoder.start(width: 128, height: 64, fps: 30, captureHDR: true)
        XCTAssertEqual(encoder.currentConfiguration?.captureHDR, true)
        for index in 0..<30 {
            encoder.encode(sampleBuffer: try hdrFrame(index: index))
        }
        encoder.stop() // Flush delayed frames before saving.

        let saver = ClipSaver(videoRingBuffer: buffer)
        let clip = try await saver.saveClip(lastSeconds: 2, outputDirectory: folder)
        try await assertHDR(clip)

        let composition = AVMutableComposition()
        let source = AVURLAsset(url: clip)
        let sourceTracks = try await source.loadTracks(withMediaType: .video)
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let duration = try await source.load(.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
        let remux = folder.appendingPathComponent("remux.mp4")
        try await CompositionRemuxer.write(composition: composition, to: remux, mergeAudioTracks: true, metadata: [])
        try await assertHDR(remux)

        let preset = try await HDRVideoExport.transcodePreset(for: composition)
        XCTAssertEqual(preset, AVAssetExportPresetHEVCHighestQuality)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: preset))
        exporter.videoComposition = try await VideoCropper.videoComposition(
            for: composition, crop: NormalizedVideoCrop(CGRect(x: 0, y: 0, width: 0.5, height: 1))
        )
        let transcode = folder.appendingPathComponent("transcode.mp4")
        try await exporter.export(to: transcode, as: .mp4)
        try await assertHDR(transcode)

        let controlledTranscode = folder.appendingPathComponent("controlled-transcode.mp4")
        let outputSize = CGSize(width: 64, height: 32)
        let controlledComposition = try await VideoCropper.videoComposition(
            for: composition,
            crop: .fullFrame,
            outputSize: outputSize
        )
        try await TrimVideoTranscoder().export(
            asset: composition,
            timeRange: CMTimeRange(start: .zero, duration: duration),
            videoComposition: controlledComposition,
            outputSize: outputSize,
            videoBitrateMbps: 1.5,
            to: controlledTranscode
        )
        try await assertHDR(controlledTranscode)
    }

    func testHDRAtMacBookDisplayDimensionsProducesFrames() throws {
        #if !arch(arm64)
        throw XCTSkip("HDR capture requires Apple silicon")
        #endif
        let buffer = VideoRingBuffer()
        let encoder = VideoEncoder()
        defer { encoder.stop() }
        encoder.outputHandler = { buffer.append(encodedSample: $0) }
        try encoder.start(width: 1512, height: 982, fps: 120, captureHDR: true)
        for index in 0..<12 {
            encoder.encode(sampleBuffer: try hdrFrame(index: index, width: 1512, height: 982))
        }
        encoder.stop()
        XCTAssertGreaterThan(buffer.duration, 0)
    }

    private func assertHDR(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let characteristics = try await track.load(.mediaCharacteristics)
        XCTAssertTrue(characteristics.contains(.containsHDRVideo))
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String, kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
        XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String)
        let atoms = try XCTUnwrap(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data])
        let hvcc = try XCTUnwrap(atoms["hvcC"])
        XCTAssertGreaterThan(hvcc.count, 18)
        guard hvcc.count > 18 else { return }
        XCTAssertEqual(hvcc[1] & 0x1f, 2, "HEVC Main 10 profile")
        XCTAssertEqual((hvcc[17] & 7) + 8, 10, "10-bit luma")
        XCTAssertEqual((hvcc[18] & 7) + 8, 10, "10-bit chroma")
    }

    private func hdrFrame(index: Int, width: Int = 128, height: Int = 64) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(image, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(image) {
            let height = CVPixelBufferGetHeightOfPlane(image, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane) / 2
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane)).assumingMemoryBound(to: UInt16.self)
            for row in 0..<height {
                for column in 0..<stride {
                    base[row * stride + column] = UInt16(plane == 0 ? 64 + (column % 128) * 876 / 127 : 512) << 6
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(30 + index), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
