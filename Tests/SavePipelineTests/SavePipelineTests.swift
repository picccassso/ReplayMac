import XCTest
import AVFoundation
import CoreMedia
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

    func testTimelineOffsetAnchorsToVideoStartWhenAudioStartsEarlier() {
        let timescale: CMTimeScale = 600
        let videoStart = CMTime(seconds: 10.0, preferredTimescale: timescale)
        let systemAudioStart = CMTime(seconds: 9.0, preferredTimescale: timescale)
        let micAudioStart = CMTime(seconds: 9.4, preferredTimescale: timescale)

        let offset = ClipSaver.timelineOffset(
            videoStartPTS: videoStart,
            systemAudioStartPTS: systemAudioStart,
            micAudioStartPTS: micAudioStart
        )

        XCTAssertEqual(offset.seconds, videoStart.seconds, accuracy: 0.0001)
    }

    func testTimelineOffsetFallsBackToAudioWhenVideoIsInvalid() {
        let timescale: CMTimeScale = 600
        let invalidVideoStart = CMTime.invalid
        let systemAudioStart = CMTime(seconds: 4.2, preferredTimescale: timescale)
        let micAudioStart = CMTime(seconds: 4.7, preferredTimescale: timescale)

        let offset = ClipSaver.timelineOffset(
            videoStartPTS: invalidVideoStart,
            systemAudioStartPTS: systemAudioStart,
            micAudioStartPTS: micAudioStart
        )

        XCTAssertEqual(offset.seconds, systemAudioStart.seconds, accuracy: 0.0001)
    }

    func testAudioTrackMixerCombinesOverlappingTracks() throws {
        let system = try makePCMSampleBuffer(
            samples: [0.25, 0.25, 0.25, 0.25],
            channels: 2,
            startFrame: 0
        )
        let mic = try makePCMSampleBuffer(
            samples: [0.5, 0.5],
            channels: 1,
            startFrame: 0
        )

        let merged = try AudioTrackMixer.merge(systemAudioSamples: [system], micAudioSamples: [mic])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(CMSampleBufferGetNumSamples(merged[0]), 2)
        XCTAssertEqual(channelCount(for: merged[0]), 2)
        XCTAssertEqual(floatSamples(in: merged[0]), [0.75, 0.75, 0.75, 0.75])
    }

    func testAudioTrackMixerPreservesMicOffset() throws {
        let system = try makePCMSampleBuffer(
            samples: [0.25, 0.25, 0.25, 0.25],
            channels: 2,
            startFrame: 0
        )
        let mic = try makePCMSampleBuffer(
            samples: [0.5],
            channels: 1,
            startFrame: 1
        )

        let merged = try AudioTrackMixer.merge(systemAudioSamples: [system], micAudioSamples: [mic])

        XCTAssertEqual(floatSamples(in: merged[0]), [0.25, 0.25, 0.75, 0.75])
    }

    private func makePCMSampleBuffer(
        samples: [Float],
        channels: Int,
        startFrame: Int64,
        sampleRate: Int32 = 48_000
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ), noErr)
        guard let formatDescription else {
            throw AudioTrackMixError.unsupportedFormat
        }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ), noErr)
        guard let blockBuffer else {
            throw AudioTrackMixError.cannotCreateBlockBuffer(-1)
        }

        let copyStatus = samples.withUnsafeBytes { rawBuffer in
            CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        XCTAssertEqual(copyStatus, noErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: startFrame, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(samples.count / channels),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(createStatus, noErr)
        guard let sampleBuffer else {
            throw AudioTrackMixError.cannotCreateSampleBuffer(createStatus)
        }
        return sampleBuffer
    }

    private func channelCount(for sampleBuffer: CMSampleBuffer) -> Int {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0
        }
        return Int(asbd.pointee.mChannelsPerFrame)
    }

    private func floatSamples(in sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return [] }
        let byteCount = CMBlockBufferGetDataLength(dataBuffer)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { rawBuffer in
            CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: rawBuffer.baseAddress!
            )
        }
        guard status == noErr else { return [] }
        return bytes.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }
}
