import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import Save

/// The session save used to run every frame through `AVAssetExportSession`
/// purely so it could merge two audio tracks, which transcodes the video. These
/// tests pin the property that matters: the video track comes out byte-identical
/// in codec and duration no matter what happens to the audio.
final class CompositionRemuxerTests: XCTestCase {
    private enum TestError: Error {
        case couldNotCreatePixelBuffer(OSStatus)
        case couldNotCreateSampleBuffer(OSStatus)
        case couldNotCreateFormatDescription(OSStatus)
        case writerFailed(Error?)
        case missingTrack
    }

    private var workingDirectory: URL!

    override func setUpWithError() throws {
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    func testMergingAudioKeepsVideoInItsOriginalCodec() async throws {
        let source = try await makeSourceClip(seconds: 2, audioTrackCount: 2)
        let sourceCodec = try await videoCodec(of: source)
        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds

        let output = workingDirectory.appendingPathComponent("merged.mp4")
        try await CompositionRemuxer.write(
            composition: try await makeComposition(from: [source]),
            to: output,
            mergeAudioTracks: true,
            metadata: ClipMetadata.makeMetadataItems()
        )

        let asset = AVURLAsset(url: output)
        let outputCodec = try await videoCodec(of: output)
        let audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
        let outputDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(outputCodec, sourceCodec, "Merging audio must not re-encode the video track")
        XCTAssertEqual(audioTrackCount, 1, "Both audio tracks should be mixed down to one")
        XCTAssertEqual(outputDuration, sourceDuration, accuracy: 0.2)
    }

    func testWithoutMergingBothAudioTracksArePassedThrough() async throws {
        let source = try await makeSourceClip(seconds: 2, audioTrackCount: 2)
        let sourceCodec = try await videoCodec(of: source)

        let output = workingDirectory.appendingPathComponent("separate.mp4")
        try await CompositionRemuxer.write(
            composition: try await makeComposition(from: [source]),
            to: output,
            mergeAudioTracks: false,
            metadata: ClipMetadata.makeMetadataItems()
        )

        let asset = AVURLAsset(url: output)
        let outputCodec = try await videoCodec(of: output)
        let audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(outputCodec, sourceCodec)
        XCTAssertEqual(audioTrackCount, 2)
    }

    /// A session recording is stitched from 60-second segments, so the export
    /// composition is always multi-segment in practice.
    func testMultipleSegmentsAreConcatenatedInOrder() async throws {
        let first = try await makeSourceClip(seconds: 2, audioTrackCount: 2)
        let second = try await makeSourceClip(seconds: 3, audioTrackCount: 2)

        let output = workingDirectory.appendingPathComponent("stitched.mp4")
        try await CompositionRemuxer.write(
            composition: try await makeComposition(from: [first, second]),
            to: output,
            mergeAudioTracks: true,
            metadata: ClipMetadata.makeMetadataItems()
        )

        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        let outputCodec = try await videoCodec(of: output)
        let sourceCodec = try await videoCodec(of: first)
        XCTAssertEqual(duration, 5, accuracy: 0.3, "Both segments should appear in the output")
        XCTAssertEqual(outputCodec, sourceCodec)
    }

    /// The merge is the only reason audio is touched at all, so a mix that
    /// silently produced an empty track would look identical by track count.
    func testMergedAudioCarriesActualSound() async throws {
        let source = try await makeSourceClip(seconds: 2, audioTrackCount: 2)

        let output = workingDirectory.appendingPathComponent("audible.mp4")
        try await CompositionRemuxer.write(
            composition: try await makeComposition(from: [source]),
            to: output,
            mergeAudioTracks: true,
            metadata: ClipMetadata.makeMetadataItems()
        )

        let peak = try await peakAmplitude(of: output)
        XCTAssertGreaterThan(peak, 0.01, "The merged track should contain the source tones, not silence")
    }

    func testAudioOnlyCompositionStillWrites() async throws {
        let source = try await makeSourceClip(seconds: 2, audioTrackCount: 1, includeVideo: false)

        let output = workingDirectory.appendingPathComponent("audio-only.mp4")
        try await CompositionRemuxer.write(
            composition: try await makeComposition(from: [source]),
            to: output,
            mergeAudioTracks: true,
            metadata: ClipMetadata.makeMetadataItems()
        )

        let asset = AVURLAsset(url: output)
        let audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
        let videoTracksEmpty = try await asset.loadTracks(withMediaType: .video).isEmpty
        XCTAssertEqual(audioTrackCount, 1)
        XCTAssertTrue(videoTracksEmpty)
    }

    func testEmptyCompositionThrowsRatherThanWritingAnUnplayableFile() async throws {
        let output = workingDirectory.appendingPathComponent("empty.mp4")
        do {
            try await CompositionRemuxer.write(
                composition: AVMutableComposition(),
                to: output,
                mergeAudioTracks: true,
                metadata: []
            )
            XCTFail("An empty composition should not produce an output file")
        } catch CompositionRemuxError.noTracks {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Fixtures

    private final class InputBox: @unchecked Sendable {
        let input: AVAssetWriterInput
        init(_ input: AVAssetWriterInput) { self.input = input }
    }

    private final class AdaptorBox: @unchecked Sendable {
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        init(_ adaptor: AVAssetWriterInputPixelBufferAdaptor) { self.adaptor = adaptor }
    }

    private func makeComposition(from urls: [URL]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        var videoTrack: AVMutableCompositionTrack?
        var audioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero

        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)

            if let track = try await asset.loadTracks(withMediaType: .video).first {
                if videoTrack == nil {
                    videoTrack = composition.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                try videoTrack?.insertTimeRange(range, of: track, at: cursor)
            }
            for (index, track) in (try await asset.loadTracks(withMediaType: .audio)).enumerated() {
                while audioTracks.count <= index {
                    if let added = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) {
                        audioTracks.append(added)
                    }
                }
                try audioTracks[index].insertTimeRange(range, of: track, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        return composition
    }

    /// Decodes the output's audio and returns the largest sample magnitude,
    /// normalised to 0...1.
    private func peakAmplitude(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TestError.missingTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        reader.add(output)
        guard reader.startReading() else {
            throw TestError.writerFailed(reader.error)
        }

        var peak: Int16 = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }

            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for index in 0..<(length / 2) {
                    peak = max(peak, abs(samples[index]))
                }
            }
        }
        return Double(peak) / Double(Int16.max)
    }

    private func videoCodec(of url: URL) async throws -> CMFormatDescription.MediaSubType {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else {
            throw TestError.missingTrack
        }
        return format.mediaSubType
    }

    /// Writes a real H.264 + AAC MP4, so the remuxer is exercised against
    /// genuinely compressed sample buffers rather than raw ones.
    private func makeSourceClip(
        seconds: Int,
        audioTrackCount: Int,
        includeVideo: Bool = true
    ) async throws -> URL {
        let url = workingDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let frameRate = 30
        var videoInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if includeVideo {
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 320,
                    AVVideoHeightKey: 240
                ]
            )
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: 320,
                    kCVPixelBufferHeightKey as String: 240
                ]
            )
            videoInput = input
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        let audioInputs = (0..<audioTrackCount).map { _ -> AVAssetWriterInput in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            return input
        }

        guard writer.startWriting() else {
            throw TestError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // Every input must be fed concurrently: AVAssetWriter holds one input
        // back while another input's timeline lags, so filling the tracks one
        // after another deadlocks.
        let videoBox = videoInput.map(InputBox.init)
        let adaptorBox = adaptor.map(AdaptorBox.init)
        let audioBoxes = audioInputs.map(InputBox.init)
        try await withThrowingTaskGroup(of: Void.self) { group in
            if let videoBox, let adaptorBox {
                group.addTask {
                    for frame in 0..<(seconds * frameRate) {
                        while !videoBox.input.isReadyForMoreMediaData {
                            try await Task.sleep(nanoseconds: 1_000_000)
                        }
                        let buffer = try Self.makePixelBuffer(seed: frame)
                        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))
                        XCTAssertTrue(adaptorBox.adaptor.append(buffer, withPresentationTime: time))
                    }
                    videoBox.input.markAsFinished()
                }
            }

            // 1024-frame chunks of silence, which is what the AAC encoder wants.
            let framesPerBuffer = 1024
            let totalAudioFrames = seconds * 48_000
            for (trackIndex, box) in audioBoxes.enumerated() {
                // A distinct tone per track, so a mix that drops one is visible.
                let toneHertz = 440.0 * Double(trackIndex + 1)
                group.addTask {
                    var position = 0
                    while position < totalAudioFrames {
                        while !box.input.isReadyForMoreMediaData {
                            try await Task.sleep(nanoseconds: 1_000_000)
                        }
                        let count = min(framesPerBuffer, totalAudioFrames - position)
                        let sample = try Self.makeToneAudioSample(
                            frameCount: count,
                            startFrame: position,
                            hertz: toneHertz
                        )
                        XCTAssertTrue(box.input.append(sample))
                        position += count
                    }
                    box.input.markAsFinished()
                }
            }
            try await group.waitForAll()
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TestError.writerFailed(writer.error)
        }
        return url
    }

    private static func makePixelBuffer(seed: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            320,
            240,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw TestError.couldNotCreatePixelBuffer(status)
        }
        // Vary the content so the encoder cannot collapse the clip to nothing.
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
            memset(base, Int32(seed % 251), byteCount)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private static func makeToneAudioSample(
        frameCount: Int,
        startFrame: Int,
        hertz: Double
    ) throws -> CMSampleBuffer {
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
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw TestError.couldNotCreateFormatDescription(formatStatus)
        }

        let byteCount = frameCount * 4
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else {
            throw TestError.couldNotCreateSampleBuffer(blockStatus)
        }
        var tone = [Int16](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * hertz * Double(startFrame + frame) / 48_000
            let value = Int16(sin(phase) * 8_000)
            tone[frame * 2] = value
            tone[frame * 2 + 1] = value
        }
        try tone.withUnsafeBytes { raw in
            let status = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
            guard status == noErr else {
                throw TestError.couldNotCreateSampleBuffer(status)
            }
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: 48_000),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw TestError.couldNotCreateSampleBuffer(sampleStatus)
        }
        return sampleBuffer
    }
}
