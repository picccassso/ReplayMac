import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import Encode
@testable import RingBuffer
@testable import Save
@testable import UI

/// Regression cover for clips that opened on 10-20 seconds of silence and then
/// "started" their audio late.
///
/// ScreenCaptureKit sends no complete frames while the screen is still, so the
/// video buffer stopped advancing while audio kept arriving. A save measured
/// its window back from the last video frame, reached further back than the
/// audio buffer held, and padded the difference with silence.
final class StillScreenAudioSyncTests: XCTestCase {
    private static let sampleRate = 48_000.0
    private static let start = 1_000.0
    /// A saved clip runs one frame past its window; allow for that and AAC framing.
    private static let lengthTolerance = 0.1

    private var outputDirectory: URL!

    override func setUpWithError() throws {
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillScreenAudioSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: outputDirectory)
    }

    /// 30 s of motion, then 30 s of still screen, then a 30 s save: the clip
    /// must cover the still stretch right up to the save, with sound from its
    /// first moment to its last.
    func testClipSavedAfterStillScreenHasAudioFromTheStart() async throws {
        let timeCap = 30 + AppSettings.ringBufferHeadroomSeconds
        let videoBuffer = VideoRingBuffer(timeCap: timeCap)
        let audioBuffer = AudioRingBuffer(timeCap: timeCap, memoryCap: 200_000_000)

        let encoder = VideoEncoder(idleRefreshEnabled: false)
        encoder.outputHandler = { videoBuffer.append(encodedSample: $0) }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)

        // Motion: a new frame every 1/30 s.
        var frameIndex = 0
        var ms = 0
        while ms < 30_000 {
            encoder.encode(sampleBuffer: try Self.makeFrame(seed: frameIndex, at: Self.time(ms: ms)))
            frameIndex += 1
            ms += 33
        }
        // Still screen: no frames at all, only the idle clock ticking, as the
        // encoder's timer would.
        while ms <= 60_000 {
            encoder.refreshIfIdle(now: Self.time(ms: ms))
            ms += 100
        }
        encoder.stop()

        // Audio arrives the whole time, still screen or not.
        var phase = 0.0
        var frame: Int64 = 0
        let endFrame = Int64(60 * Self.sampleRate)
        while frame < endFrame {
            audioBuffer.append(try Self.makeToneSample(startFrame: frame, frameCount: 1_024, phase: &phase))
            frame += 1_024
        }

        let newestVideo = try XCTUnwrap(videoBuffer.samples(last: 0.001).last)
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(newestVideo).seconds,
            Self.start + 60,
            accuracy: IdleFrameRefreshPolicy.idleInterval.seconds + 0.11,
            "The video buffer has to keep pace with the clock while the screen is still"
        )

        let saver = ClipSaver(videoRingBuffer: videoBuffer, systemAudioRingBuffer: audioBuffer)
        let url = try await saver.saveClip(lastSeconds: 30, outputDirectory: outputDirectory)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 30, accuracy: Self.lengthTolerance)

        let audible = try await Self.audibleRange(of: asset)
        XCTAssertLessThan(audible.first, 0.25, "Clip opens on \(audible.first)s of silence")
        XCTAssertGreaterThan(audible.last, duration - 0.5, "Clip loses its audio at \(audible.last)s of \(duration)s")
    }

    /// Video has to start on a keyframe, up to a GOP before the window. The
    /// lead-in is written for decoding but must not play: a 30 s save is 30 s.
    func testClipPlaysExactlyTheRequestedLength() async throws {
        let videoBuffer = VideoRingBuffer(timeCap: 30 + AppSettings.ringBufferHeadroomSeconds)
        let audioBuffer = AudioRingBuffer(timeCap: 30 + AppSettings.ringBufferHeadroomSeconds, memoryCap: 200_000_000)

        let encoder = VideoEncoder(idleRefreshEnabled: false)
        encoder.outputHandler = { videoBuffer.append(encodedSample: $0) }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)
        // 41.3 s of motion, so the 30 s window starts mid-GOP.
        var frameIndex = 0
        var ms = 0
        while ms <= 41_300 {
            encoder.encode(sampleBuffer: try Self.makeFrame(seed: frameIndex, at: Self.time(ms: ms)))
            frameIndex += 1
            ms += 33
        }
        encoder.stop()

        var phase = 0.0
        var frame: Int64 = 0
        while frame < Int64(41.3 * Self.sampleRate) {
            audioBuffer.append(try Self.makeToneSample(startFrame: frame, frameCount: 1_024, phase: &phase))
            frame += 1_024
        }

        let snapped = videoBuffer.samples(last: 30)
        let snappedLength = CMSampleBufferGetPresentationTimeStamp(snapped.last!).seconds
            - CMSampleBufferGetPresentationTimeStamp(snapped.first!).seconds
        XCTAssertGreaterThan(snappedLength, 30.2, "Window should start mid-GOP for this test to mean anything")

        let saver = ClipSaver(videoRingBuffer: videoBuffer, systemAudioRingBuffer: audioBuffer)
        let url = try await saver.saveClip(lastSeconds: 30, outputDirectory: outputDirectory)
        let asset = AVURLAsset(url: url)

        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 30, accuracy: Self.lengthTolerance)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let videoDuration = try await videoTrack.load(.timeRange).duration.seconds
        XCTAssertEqual(videoDuration, 30, accuracy: Self.lengthTolerance)

        let audible = try await Self.audibleRange(of: asset)
        XCTAssertLessThan(audible.first, 0.25)

        // The first presented frame sits after the keyframe and must still decode.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        _ = try await generator.image(at: .zero)
    }

    func testPresentationStartSkipsTheKeyframeLeadIn() {
        let start = CMTime(value: 10_000, timescale: 1_000)
        let end = CMTime(value: 41_500, timescale: 1_000)
        XCTAssertEqual(ClipSaver.presentationStart(videoStartPTS: start, videoEndPTS: end, lastSeconds: 30).seconds, 1.5, accuracy: 0.001)
        // Buffer holds less than the window: play from the first frame.
        XCTAssertEqual(ClipSaver.presentationStart(videoStartPTS: start, videoEndPTS: end, lastSeconds: 60), .zero)
        XCTAssertEqual(ClipSaver.presentationStart(videoStartPTS: .invalid, videoEndPTS: end, lastSeconds: 30), .zero)
    }

    /// A save starts on the keyframe at or before its window; the audio buffers'
    /// headroom is what keeps sound under that lead-in.
    func testRingBufferHeadroomCoversWorstCaseKeyframeSpacing() {
        XCTAssertGreaterThan(
            AppSettings.ringBufferHeadroomSeconds,
            IdleFrameRefreshPolicy.worstCaseKeyframeSpacing
        )
    }

    // MARK: - Helpers

    private static func time(ms: Int) -> CMTime {
        CMTime(value: Int64(start * 1_000) + Int64(ms), timescale: 1_000)
    }

    private static func makeFrame(seed: Int, at pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else {
            throw TestFailure("pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(seed % 256), CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format,
              CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sample
              ) == noErr,
              let sample else {
            throw TestFailure("video sample")
        }
        return sample
    }

    /// 440 Hz stereo Float32 tone on the host-clock timeline the capture uses.
    private static func makeToneSample(startFrame: Int64, frameCount: Int, phase: inout Double) throws -> CMSampleBuffer {
        let channels = 2
        var samples = [Float](repeating: 0, count: frameCount * channels)
        let step = 2 * Double.pi * 440 / sampleRate
        for index in 0..<frameCount {
            let value = Float(sin(phase) * 0.5)
            samples[index * channels] = value
            samples[index * channels + 1] = value
            phase += step
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ) == noErr, let format else {
            throw TestFailure("audio format")
        }

        let byteCount = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else {
            throw TestFailure("audio block")
        }
        _ = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }

        let startTime = CMTimeAdd(
            CMTime(value: Int64(start * 1_000), timescale: 1_000),
            CMTime(value: startFrame, timescale: CMTimeScale(sampleRate))
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: startTime,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: CMItemCount(frameCount), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            throw TestFailure("audio sample")
        }
        return sample
    }

    /// First and last moment, in clip seconds, where the decoded audio is audible.
    private static func audibleRange(of asset: AVURLAsset) async throws -> (first: Double, last: Double) {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TestFailure("clip has no audio track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw TestFailure("reader: \(String(describing: reader.error))")
        }

        var first: Double?
        var last = 0.0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let startSeconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / 4)
            _ = floats.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            for (index, value) in floats.enumerated() where abs(value) > 0.05 {
                let seconds = startSeconds + Double(index) / sampleRate
                if first == nil { first = seconds }
                last = seconds
            }
        }
        guard let first else { throw TestFailure("clip is silent") }
        return (first, last)
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
