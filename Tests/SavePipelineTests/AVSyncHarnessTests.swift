import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import Audio
@testable import Encode
@testable import RingBuffer
@testable import Save
@testable import UI

/// End-to-end audio/video sync checks.
///
/// Each scenario drives the real encoder, ring buffers, system audio capture
/// and clip saver on a simulated host clock, with markers placed at the same
/// instant in both tracks: a white video frame and a loud audio click. The
/// saved file is decoded and every click must land on its flash. Faults that
/// once broke sync (still screens, encoder drops, audio dropouts, paused
/// capture, short buffers) are injected one scenario at a time, so a new
/// timing bug anywhere in the pipeline shows up here as markers drifting
/// apart, silence where there should be sound, or a clip of the wrong length.
final class AVSyncHarnessTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AVSyncHarnessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: outputDirectory)
    }

    func testSteadyMotionStaysInSync() async throws {
        var scenario = Scenario(duration: 45, saveAt: 45, replaySeconds: 30)
        scenario.markers = [20, 30, 40]
        try await run(scenario)
    }

    /// No frames at all while the screen is still: the encoder's repeats keep
    /// the buffer on the clock, so the clip still ends at the save.
    func testStillScreenStaysInSync() async throws {
        var scenario = Scenario(duration: 50, saveAt: 50, replaySeconds: 30)
        scenario.stillRanges = [25...50]
        scenario.markers = [22, 24]
        try await run(scenario)
    }

    /// A real-time encoder drops frames under load. Each drop used to shift
    /// every later frame one frame earlier (issue #16).
    func testEncoderDropsStayInSync() async throws {
        var scenario = Scenario(duration: 60, saveAt: 60, replaySeconds: 30)
        scenario.dropsFrame = { index in index % 5 == 1 || index % 5 == 3 }
        scenario.markers = [35, 45, 55]
        try await run(scenario)
    }

    /// System audio stalls for longer than capture papers over with silence.
    func testSystemAudioDropoutStaysInSyncWhenMerged() async throws {
        var scenario = Scenario(duration: 60, saveAt: 60, replaySeconds: 30)
        scenario.systemAudioDropouts = [35...43]
        scenario.microphone = true
        scenario.markers = [32, 47, 55]
        try await run(scenario)
    }

    func testSystemAudioDropoutStaysInSyncInSeparateTracks() async throws {
        var scenario = Scenario(duration: 60, saveAt: 60, replaySeconds: 30)
        scenario.systemAudioDropouts = [35...43]
        scenario.microphone = true
        scenario.mergeAudioTracks = false
        scenario.markers = [32, 47, 55]
        try await run(scenario)
    }

    /// The buffer holds less than the requested window: save what there is.
    func testShortBufferStaysInSync() async throws {
        var scenario = Scenario(duration: 12, saveAt: 12, replaySeconds: 30)
        scenario.markers = [5, 10]
        scenario.expectedLength = 12
        try await run(scenario)
    }

    /// Capture paused (no frames, no repeats, no audio) well before the save:
    /// the clip falls back to the last footage recorded.
    func testSaveAfterCapturePausedUsesLastFootage() async throws {
        var scenario = Scenario(duration: 40, saveAt: 60, replaySeconds: 30)
        scenario.markers = [25, 35]
        scenario.expectedAnchoredToClock = false
        try await run(scenario)
    }

    func testSaveWindowEndsAtTheClockWhileCaptureIsLive() {
        let now = CMTime(value: 100_000, timescale: 1_000)
        let live = ClipSaver.saveWindow(now: now, newestVideoEnd: CMTime(value: 99_700, timescale: 1_000), lastSeconds: 30)
        XCTAssertTrue(live.anchoredToClock)
        XCTAssertEqual(live.end.seconds, 100, accuracy: 0.0001)
        XCTAssertEqual(live.start.seconds, 70, accuracy: 0.0001)

        let stale = ClipSaver.saveWindow(now: now, newestVideoEnd: CMTime(value: 90_000, timescale: 1_000), lastSeconds: 30)
        XCTAssertFalse(stale.anchoredToClock)
        XCTAssertEqual(stale.end.seconds, 90, accuracy: 0.0001)
        XCTAssertEqual(stale.start.seconds, 60, accuracy: 0.0001)
    }

    /// Memory pressure trims every buffer mid-session. Video can only trim
    /// whole keyframe groups and keeps more than it was asked to; audio must
    /// keep the same history, or a save right after opens on silence.
    func testMemoryPressureTrimKeepsAudioUnderAllVideo() async throws {
        var scenario = Scenario(duration: 60, saveAt: 60, replaySeconds: 30)
        scenario.trim = (at: 50.05, toSeconds: 10)
        scenario.markers = [53, 57]
        scenario.microphone = true
        scenario.checksLength = false
        try await run(scenario)
    }

    /// A 4-input interface used to crash the clip writer (AAC with more than
    /// two channels and no layout). It is folded down to stereo now.
    func testFourChannelMicStaysInSyncInSeparateTracks() async throws {
        var scenario = Scenario(duration: 45, saveAt: 45, replaySeconds: 30)
        scenario.microphone = true
        scenario.micChannels = 4
        scenario.mergeAudioTracks = false
        scenario.markers = [20, 30, 40]
        try await run(scenario)
    }

    func testFourChannelMicStaysInSyncWhenMerged() async throws {
        var scenario = Scenario(duration: 45, saveAt: 45, replaySeconds: 30)
        scenario.microphone = true
        scenario.micChannels = 4
        scenario.markers = [20, 30, 40]
        try await run(scenario)
    }

    /// Both displays' samples are taken before either file is written, so
    /// display 2 losing frames during display 1's write changes nothing.
    func testDualDisplaySaveTakesBothDisplaysBeforeWriting() async throws {
        let clock = SimulatedClock(Self.hostTime(0))
        var buffers: [VideoRingBuffer] = []
        for seed in 0..<2 {
            let buffer = VideoRingBuffer(timeCap: 33)
            let encoder = VideoEncoder(idleRefreshEnabled: false, clock: { clock.now })
            encoder.outputHandler = { buffer.append(encodedSample: $0) }
            try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)
            for index in 0..<(40 * 30) {
                let t = Double(index) * Self.frameInterval
                clock.now = Self.hostTime(t)
                encoder.encode(sampleBuffer: try Self.makeFrame(level: 40 + (index + seed) % 110, at: Self.hostTime(t)))
            }
            encoder.stop()
            buffers.append(buffer)
        }

        let saveTime = Self.hostTime(40)
        let saver = ClipSaver(
            videoRingBuffer: buffers[0],
            dualDisplay1VideoRingBuffer: buffers[0],
            dualDisplay2VideoRingBuffer: buffers[1],
            clock: { saveTime }
        )
        let display2 = buffers[1]
        await saver.setAfterDualSelection { display2.clear() }
        let urls = try await saver.saveDualDisplayClips(lastSeconds: 30, outputDirectory: outputDirectory)
        XCTAssertEqual(urls.count, 2)
        for url in urls {
            let length = try await AVURLAsset(url: url).load(.duration).seconds
            XCTAssertEqual(length, 30, accuracy: 0.1, url.lastPathComponent)
        }
    }

    /// Extended replay writes audio straight into segment files; a system
    /// audio dropout longer than capture fills used to close up there and
    /// pull everything after it early.
    func testExtendedReplaySystemAudioDropoutStaysInSync() async throws {
        let duration = 40.0
        let markers = [10.0, 30.0, 36.0]
        let dropout = 15.0...23.0
        let clock = SimulatedClock(Self.hostTime(0))

        let encoded = EncodedFrames()
        let encoder = VideoEncoder(idleRefreshEnabled: false, clock: { clock.now })
        encoder.outputHandler = { encoded.append($0) }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)
        for index in 0..<Int(duration * 30) {
            let t = Double(index) * Self.frameInterval
            clock.now = Self.hostTime(t)
            let isMarker = markers.contains { t >= $0 && t < $0 + Self.frameInterval }
            encoder.encode(sampleBuffer: try Self.makeFrame(level: isMarker ? 255 : 40 + (index * 7) % 110, at: Self.hostTime(t)))
        }
        encoder.stop()

        // Audio as SystemAudioCapture delivers it: up to 5 s of the dropout
        // filled with silence, the rest left as a hole.
        let audio = AudioSamples()
        let systemCapture = SystemAudioCapture()
        systemCapture.setHandler { audio.append($0) }
        var audioFrame: Int64 = 0
        var phase = 0.0
        while Double(audioFrame) / Self.sampleRate < duration {
            let t = Double(audioFrame) / Self.sampleRate
            let sample = try Self.makeAudio(startFrame: audioFrame, phase: phase, clicks: markers)
            if !dropout.contains(t) {
                systemCapture.process(sampleBuffer: sample)
            }
            phase += 2 * Double.pi * 440 * Double(Self.chunkFrames) / Self.sampleRate
            audioFrame += Int64(Self.chunkFrames)
        }

        let recorder = LongBufferRecorder()
        await recorder.configure(enabled: true, maxDurationSeconds: 120, outputDirectory: outputDirectory)
        // Interleave by time, as the append pump would.
        var videoQueue = encoded.all[...]
        var audioQueue = audio.all[...]
        while !videoQueue.isEmpty || !audioQueue.isEmpty {
            let videoTime = videoQueue.first.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? .infinity
            let audioTime = audioQueue.first.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? .infinity
            if videoTime <= audioTime {
                await recorder.appendVideo(LongBufferSample(videoQueue.removeFirst()))
            } else {
                await recorder.appendSystemAudio(LongBufferSample(audioQueue.removeFirst()))
                // The segment writer is real-time and drops what it is not
                // ready for; give it a moment, as live capture would.
                try await Task.sleep(nanoseconds: 300_000)
            }
        }
        let dropped = await recorder.droppedSystemAudioSamples
        XCTAssertEqual(dropped, 0, "writer backpressure dropped audio; the scenario would not mean anything")
        let url = try await recorder.saveClip(lastSeconds: duration, outputDirectory: outputDirectory, mergeAudioTracks: true)
        await recorder.stop(deleteSegments: true)

        let asset = AVURLAsset(url: url)
        let flashes = try await Self.whiteFrameTimes(of: asset)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let analysis = try await Self.analyseAudio(of: asset, track: audioTrack)
        XCTAssertEqual(flashes.count, markers.count, "flashes \(flashes)")
        XCTAssertEqual(analysis.clicks.count, markers.count, "clicks \(analysis.clicks)")
        for (flash, click) in zip(flashes, analysis.clicks) {
            XCTAssertEqual(click, flash, accuracy: Self.frameInterval + 0.02, "click at \(click)s vs flash at \(flash)s")
        }
    }

    // MARK: - Scenario

    private struct Scenario {
        var duration: Double
        var saveAt: Double
        var replaySeconds: Double
        var markers: [Double] = []
        var stillRanges: [ClosedRange<Double>] = []
        var systemAudioDropouts: [ClosedRange<Double>] = []
        var dropsFrame: (Int) -> Bool = { _ in false }
        var microphone = false
        var micChannels = 2
        var mergeAudioTracks = true
        var expectedLength: Double?
        var checksLength = true
        var expectedAnchoredToClock = true
        var trim: (at: Double, toSeconds: Double)?

        init(duration: Double, saveAt: Double, replaySeconds: Double) {
            self.duration = duration
            self.saveAt = saveAt
            self.replaySeconds = replaySeconds
        }

        func isStill(_ t: Double) -> Bool { stillRanges.contains { $0.contains(t) } }
        func isSystemAudioOut(_ t: Double) -> Bool { systemAudioDropouts.contains { $0.contains(t) } }
        func isMarker(_ t: Double, within: Double) -> Bool { markers.contains { t >= $0 && t < $0 + within } }
    }

    private static let base = 1_000.0
    private static let frameInterval = 1.0 / 30
    private static let sampleRate = 48_000.0
    private static let chunkFrames = 1_024
    private static let clickSeconds = 0.05
    private static let baselineAmplitude: Float = 0.05
    private static let clickAmplitude: Float = 0.8

    private func run(_ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) async throws {
        let timeCap = scenario.replaySeconds + AppSettings.ringBufferHeadroomSeconds
        let videoBuffer = VideoRingBuffer(timeCap: timeCap)
        let systemBuffer = AudioRingBuffer(timeCap: timeCap, memoryCap: 500_000_000)
        let micBuffer = AudioRingBuffer(timeCap: timeCap, memoryCap: 500_000_000)
        systemBuffer.retainHistory(coveredBy: [videoBuffer])
        micBuffer.retainHistory(coveredBy: [videoBuffer])

        let systemCapture = SystemAudioCapture()
        systemCapture.setHandler { systemBuffer.append($0) }

        let clock = SimulatedClock(Self.hostTime(0))
        let encoder = VideoEncoder(idleRefreshEnabled: false, clock: { clock.now })
        encoder.outputHandler = { videoBuffer.append(encodedSample: $0) }
        let droppedTimes = DroppedTimes()
        encoder.simulatesDroppedFrame = { droppedTimes.contains($0) }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)

        // Drive video, the encoder's idle clock and both audio sources in
        // time order, as capture would deliver them.
        var frameIndex = 0
        var nextFrame = 0.0
        var nextTick = 0.0
        var audioFrame: Int64 = 0
        var phase = 0.0
        var pendingTrim = scenario.trim
        while true {
            let nextAudio = Double(audioFrame) / Self.sampleRate
            let t = min(nextFrame, nextTick, nextAudio)
            if t >= scenario.duration { break }
            clock.now = Self.hostTime(t)

            if let trim = pendingTrim, t >= trim.at {
                videoBuffer.trimToDuration(maxSeconds: trim.toSeconds)
                systemBuffer.trimToDuration(maxSeconds: trim.toSeconds)
                micBuffer.trimToDuration(maxSeconds: trim.toSeconds)
                pendingTrim = nil
            }

            if t == nextAudio {
                let systemOut = scenario.isSystemAudioOut(t)
                let system = try Self.makeAudio(startFrame: audioFrame, phase: phase, clicks: scenario.markers)
                if !systemOut {
                    systemCapture.process(sampleBuffer: system)
                }
                if scenario.microphone {
                    micBuffer.append(try Self.makeAudio(startFrame: audioFrame, phase: phase, clicks: scenario.markers, channels: scenario.micChannels))
                }
                phase += 2 * Double.pi * 440 * Double(Self.chunkFrames) / Self.sampleRate
                audioFrame += Int64(Self.chunkFrames)
            } else if t == nextFrame {
                if !scenario.isStill(t) {
                    let isMarker = scenario.isMarker(t, within: Self.frameInterval)
                    let pts = Self.hostTime(t)
                    if !isMarker && scenario.dropsFrame(frameIndex) {
                        droppedTimes.insert(pts)
                    }
                    let level = isMarker ? 255 : 40 + (frameIndex * 7) % 110
                    encoder.encode(sampleBuffer: try Self.makeFrame(level: level, at: pts))
                }
                frameIndex += 1
                nextFrame = Double(frameIndex) * Self.frameInterval
            } else {
                encoder.refreshIfIdle(now: Self.hostTime(t))
                nextTick += 0.1
            }
        }
        encoder.stop()

        let saveTime = Self.hostTime(scenario.saveAt)
        let saver = ClipSaver(
            videoRingBuffer: videoBuffer,
            systemAudioRingBuffer: systemBuffer,
            micRingBuffer: scenario.microphone ? micBuffer : nil,
            clock: { saveTime }
        )
        let url = try await saver.saveClip(
            lastSeconds: scenario.replaySeconds,
            outputDirectory: outputDirectory,
            mergeAudioTracks: scenario.mergeAudioTracks
        )
        let savedReport = await saver.lastSyncReport
        let report = try XCTUnwrap(savedReport, file: file, line: line)
        XCTAssertEqual(report.anchoredToClock, scenario.expectedAnchoredToClock, "anchoredToClock", file: file, line: line)

        let asset = AVURLAsset(url: url)
        let length = try await asset.load(.duration).seconds
        let lastFootage = min(scenario.saveAt, scenario.duration)
        if scenario.checksLength {
            let expectedLength = scenario.expectedLength ?? scenario.replaySeconds
            XCTAssertEqual(length, expectedLength, accuracy: 0.1, "clip length", file: file, line: line)
        }

        // Clip time zero is this host time: the clip ends at the save, or at
        // the last footage when capture had paused.
        let clipStart = (scenario.expectedAnchoredToClock ? scenario.saveAt : lastFootage) - length

        let expectedMarkers = scenario.markers
            .map { $0 - clipStart }
            .filter { $0 >= 0 && $0 < length - Self.clickSeconds }
        let flashes = try await Self.whiteFrameTimes(of: asset)
        XCTAssertEqual(flashes.count, expectedMarkers.count, "flashes \(flashes) expected \(expectedMarkers)", file: file, line: line)
        for (expected, flash) in zip(expectedMarkers, flashes) {
            XCTAssertEqual(flash, expected, accuracy: Self.frameInterval + 0.01, "flash position", file: file, line: line)
        }

        // Separate-track mode writes system audio, then mic; both carry clicks.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let expectedTrackCount = scenario.microphone && !scenario.mergeAudioTracks ? 2 : 1
        XCTAssertEqual(audioTracks.count, expectedTrackCount, "audio tracks", file: file, line: line)
        for (trackIndex, track) in audioTracks.enumerated() {
            let isSystemOnly = !scenario.mergeAudioTracks && trackIndex == 0 || !scenario.microphone
            let analysis = try await Self.analyseAudio(of: asset, track: track)
            XCTAssertEqual(analysis.clicks.count, expectedMarkers.count, "track \(trackIndex) clicks \(analysis.clicks) expected \(expectedMarkers)", file: file, line: line)
            for (flash, click) in zip(flashes, analysis.clicks) {
                XCTAssertEqual(click, flash, accuracy: Self.frameInterval + 0.02, "track \(trackIndex) click at \(click)s vs flash at \(flash)s", file: file, line: line)
            }

            // Sound from the first moment to the last, apart from where this
            // track's only source really was silent.
            let silences = analysis.silences.filter { silence in
                let mid = clipStart + (silence.lowerBound + silence.upperBound) / 2
                let dropoutAudible = isSystemOnly && scenario.isSystemAudioOut(mid)
                return !dropoutAudible && mid <= lastFootage
            }
            XCTAssertTrue(silences.isEmpty, "track \(trackIndex) unexpected silence \(silences)", file: file, line: line)
        }
    }

    // MARK: - Media

    private static func hostTime(_ t: Double) -> CMTime {
        CMTime(value: Int64(((base + t) * 1_000_000).rounded()), timescale: 1_000_000)
    }

    private static func makeFrame(level: Int, at pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { throw HarnessError("pixel buffer") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(level), CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format,
              CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample
              ) == noErr, let sample else { throw HarnessError("video sample") }
        return sample
    }

    /// One chunk of stereo Float32 at 48 kHz: a quiet 440 Hz tone, with a loud
    /// 1 kHz click wherever a marker falls.
    private static func makeAudio(startFrame: Int64, phase: Double, clicks: [Double], channels: Int = 2) throws -> CMSampleBuffer {
        var samples = [Float](repeating: 0, count: chunkFrames * channels)
        for index in 0..<chunkFrames {
            let t = Double(startFrame + Int64(index)) / sampleRate
            let inClick = clicks.contains { t >= $0 && t < $0 + clickSeconds }
            let value: Float = inClick
                ? clickAmplitude * Float(sin(2 * Double.pi * 1_000 * t))
                : baselineAmplitude * Float(sin(phase + 2 * Double.pi * 440 * Double(index) / sampleRate))
            for channel in 0..<channels {
                samples[index * channels + channel] = value
            }
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ) == noErr, let format else { throw HarnessError("audio format") }

        let byteCount = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { throw HarnessError("audio block") }
        _ = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTimeAdd(
                CMTime(value: Int64(base * 1_000_000), timescale: 1_000_000),
                CMTime(value: startFrame, timescale: CMTimeScale(sampleRate))
            ),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: CMItemCount(chunkFrames), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else { throw HarnessError("audio sample") }
        return sample
    }

    /// Clip times of the first frame of each run of white frames.
    private static func whiteFrameTimes(of asset: AVURLAsset) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw HarnessError("clip has no video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        guard reader.startReading() else { throw HarnessError("video reader: \(String(describing: reader.error))") }

        var times: [Double] = []
        var previousWasWhite = false
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(image)
            let centre = bytes[(CVPixelBufferGetHeight(image) / 2) * row + (CVPixelBufferGetWidth(image) / 2) * 4 + 1]
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            let isWhite = centre > 220
            if isWhite && !previousWasWhite {
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
            previousWasWhite = isWhite
        }
        return times
    }

    private struct AudioAnalysis {
        var clicks: [Double] = []
        var silences: [ClosedRange<Double>] = []
    }

    /// Click onsets, and every stretch of 0.2 s or more without sound.
    private static func analyseAudio(of asset: AVURLAsset, track: AVAssetTrack) async throws -> AudioAnalysis {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: sampleRate
        ])
        reader.add(output)
        guard reader.startReading() else { throw HarnessError("audio reader: \(String(describing: reader.error))") }

        var analysis = AudioAnalysis()
        var lastLoud = -1.0
        var lastSound = 0.0
        let window = Int(sampleRate * 0.01)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / 4)
            _ = floats.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            var index = 0
            while index < floats.count {
                let end = min(index + window, floats.count)
                let peak = floats[index..<end].map(abs).max() ?? 0
                let t = start + Double(index) / sampleRate
                if peak > 0.4 {
                    if t - lastLoud > 0.2 { analysis.clicks.append(t) }
                    lastLoud = t
                }
                if peak > Self.baselineAmplitude / 3 {
                    if t - lastSound >= 0.2 { analysis.silences.append(lastSound...t) }
                    lastSound = t
                }
                index = end
            }
        }
        let duration = try await asset.load(.duration).seconds
        if duration - lastSound >= 0.2 { analysis.silences.append(lastSound...duration) }
        return analysis
    }

    private final class SimulatedClock: @unchecked Sendable {
        // @unchecked: only touched under `lock`.
        private let lock = NSLock()
        private var _now: CMTime
        init(_ now: CMTime) { _now = now }
        var now: CMTime {
            get { lock.lock(); defer { lock.unlock() }; return _now }
            set { lock.lock(); _now = newValue; lock.unlock() }
        }
    }

    private final class EncodedFrames: @unchecked Sendable {
        // @unchecked: only touched under `lock`.
        private let lock = NSLock()
        private var samples: [CMSampleBuffer] = []
        func append(_ sample: CMSampleBuffer) { lock.lock(); samples.append(sample); lock.unlock() }
        var all: [CMSampleBuffer] { lock.lock(); defer { lock.unlock() }; return samples }
    }

    private typealias AudioSamples = EncodedFrames

    private final class DroppedTimes: @unchecked Sendable {
        // @unchecked: only touched under `lock`.
        private let lock = NSLock()
        private var times = Set<Int64>()

        func insert(_ time: CMTime) {
            lock.lock()
            times.insert(Self.key(time))
            lock.unlock()
        }

        func contains(_ time: CMTime) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return times.contains(Self.key(time))
        }

        private static func key(_ time: CMTime) -> Int64 {
            Int64((time.seconds * 1_000_000).rounded())
        }
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
