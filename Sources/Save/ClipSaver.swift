import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import os.log
import RingBuffer

public enum ClipSaveError: LocalizedError {
    case noSamples
    case missingFormatDescription
    case cannotAddInput
    case cannotStartWriting
    case appendFailed(Error?)
    case writerFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .noSamples:
            return "No samples available in ring buffer."
        case .missingFormatDescription:
            return "First sample is missing format description."
        case .cannotAddInput:
            return "Cannot add input to asset writer."
        case .cannotStartWriting:
            return "Failed to start asset writer."
        case .appendFailed(let error):
            return "Failed to append sample: \(error?.localizedDescription ?? "unknown")"
        case .writerFailed(let error):
            return "Asset writer failed: \(error?.localizedDescription ?? "unknown")"
        }
    }
}

/// What one save selected, measured against the window it was asked for.
/// Logged with every save so a sync problem in a user's clip can be read off
/// their logs, and kept on `ClipSaver.lastSyncReport` for tests.
public struct ClipSyncReport: Sendable, Equatable {
    public struct AudioTrack: Sendable, Equatable {
        public let label: String
        /// Seconds of silence the clip opens on before this track's first sample.
        public let leadInSeconds: Double
        /// Seconds of silence after this track's last sample before the clip ends.
        public let tailSeconds: Double
        /// Longest stretch inside the clip with no samples for this track.
        public let largestGapSeconds: Double
    }

    public let windowStart: Double
    public let windowEnd: Double
    /// True when the window ends at the moment of the save; false when the
    /// video buffer had gone stale (capture paused) and it ends at the last frame.
    public let anchoredToClock: Bool
    /// How far the newest video frame trailed the clock when the save began.
    public let videoLagSeconds: Double
    /// How far the first video frame (a keyframe) sits before the window.
    public let keyframeLeadSeconds: Double
    public let audioTracks: [AudioTrack]

    /// A clip should open on its own audio, keep it to the end, and have no
    /// holes. Anything past these marks is worth a warning in the log.
    public var isInSync: Bool {
        audioTracks.allSatisfy { track in
            track.leadInSeconds <= 0.25 && track.tailSeconds <= 0.25 && track.largestGapSeconds <= 0.5
        } && (!anchoredToClock || videoLagSeconds <= 1.0)
    }
}

public actor ClipSaver {
    /// A video buffer whose newest frame trails the clock by more than this is
    /// treated as stale (capture paused or stopped): the save then ends at the
    /// last frame rather than at the clock. Live capture stays well inside it,
    /// because the encoder repeats its last frame within a fraction of a
    /// second on a still screen.
    static let staleVideoToleranceSeconds: Double = 2.0

    private let videoRingBuffer: VideoRingBuffer
    private let dualDisplay1VideoRingBuffer: VideoRingBuffer?
    private let dualDisplay2VideoRingBuffer: VideoRingBuffer?
    private let systemAudioRingBuffer: AudioRingBuffer?
    private let micRingBuffer: AudioRingBuffer?
    private let clock: @Sendable () -> CMTime
    private static let logger = Logger(subsystem: "com.replaycap", category: "Save")
    private var logger: Logger { Self.logger }

    /// Sync measurements from the most recent save.
    public private(set) var lastSyncReport: ClipSyncReport?

    /// Test seam: runs once both displays' samples are taken in a
    /// dual-display save, before either file is written.
    private var afterDualSelection: (@Sendable () -> Void)?

    func setAfterDualSelection(_ hook: (@Sendable () -> Void)?) {
        afterDualSelection = hook
    }

    /// - Parameter clock: the host clock that capture stamps every frame and
    ///   audio buffer with. Tests pass their own.
    public init(
        videoRingBuffer: VideoRingBuffer,
        dualDisplay1VideoRingBuffer: VideoRingBuffer? = nil,
        dualDisplay2VideoRingBuffer: VideoRingBuffer? = nil,
        systemAudioRingBuffer: AudioRingBuffer? = nil,
        micRingBuffer: AudioRingBuffer? = nil,
        clock: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
    ) {
        self.videoRingBuffer = videoRingBuffer
        self.dualDisplay1VideoRingBuffer = dualDisplay1VideoRingBuffer
        self.dualDisplay2VideoRingBuffer = dualDisplay2VideoRingBuffer
        self.systemAudioRingBuffer = systemAudioRingBuffer
        self.micRingBuffer = micRingBuffer
        self.clock = clock
    }

    public func saveClip(
        lastSeconds: TimeInterval,
        outputDirectory: URL,
        mergeAudioTracks: Bool = true,
        baseName: String? = nil
    ) async throws -> URL {
        let now = clock()
        guard let newestEnd = videoRingBuffer.newestEndPTS else {
            throw ClipSaveError.noSamples
        }
        let window = Self.saveWindow(now: now, newestVideoEnd: Self.hostTime(newestEnd), lastSeconds: lastSeconds)
        let selection = try select(from: videoRingBuffer, window: window, now: now)
        return try await write(
            selection,
            outputDirectory: outputDirectory,
            fileNameSuffix: nil,
            mergeAudioTracks: mergeAudioTracks,
            baseName: baseName
        )
    }

    public func saveDualDisplayClips(
        lastSeconds: TimeInterval,
        outputDirectory: URL,
        mergeAudioTracks: Bool = true,
        baseName: String? = nil
    ) async throws -> [URL] {
        guard let dualDisplay1VideoRingBuffer, let dualDisplay2VideoRingBuffer else {
            throw ClipSaveError.noSamples
        }

        // One window for both files, and both displays' samples taken before
        // either file is written: display 2 keeps capturing (and evicting)
        // while display 1 is saved, and must not lose the start of the window.
        let now = clock()
        guard let newestEnd = [dualDisplay1VideoRingBuffer.newestEndPTS, dualDisplay2VideoRingBuffer.newestEndPTS]
            .compactMap({ $0 }).max() else {
            throw ClipSaveError.noSamples
        }
        let window = Self.saveWindow(now: now, newestVideoEnd: Self.hostTime(newestEnd), lastSeconds: lastSeconds)
        let display1 = try select(from: dualDisplay1VideoRingBuffer, window: window, now: now)
        let display2 = try select(from: dualDisplay2VideoRingBuffer, window: window, now: now)
        afterDualSelection?()
        let display1URL = try await write(
            display1,
            outputDirectory: outputDirectory,
            fileNameSuffix: "Display_1",
            mergeAudioTracks: mergeAudioTracks,
            baseName: baseName
        )
        let display2URL = try await write(
            display2,
            outputDirectory: outputDirectory,
            fileNameSuffix: "Display_2",
            mergeAudioTracks: mergeAudioTracks,
            baseName: baseName
        )

        return [display1URL, display2URL]
    }

    /// The window a save covers, on the capture (host) clock.
    struct SaveWindow: Equatable {
        let start: CMTime
        let end: CMTime
        let anchoredToClock: Bool
    }

    /// Ends the window at the moment of the save, so every track is cut to
    /// the same span of real time no matter how far behind any one buffer's
    /// newest sample is. A stale video buffer (capture paused) instead ends
    /// the window at its last frame, so saving while paused still returns the
    /// last footage recorded.
    static func saveWindow(now: CMTime, newestVideoEnd: CMTime, lastSeconds: TimeInterval) -> SaveWindow {
        let length = CMTime(seconds: max(lastSeconds, 0), preferredTimescale: 1_000_000_000)
        let lag = CMTimeGetSeconds(CMTimeSubtract(now, newestVideoEnd))
        let anchoredToClock = now.isNumeric && lag <= staleVideoToleranceSeconds
        // A frame stamped a hair past `now` still belongs in the clip.
        let end = anchoredToClock ? CMTimeMaximum(now, newestVideoEnd) : newestVideoEnd
        return SaveWindow(start: CMTimeSubtract(end, length), end: end, anchoredToClock: anchoredToClock)
    }

    private static func hostTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }

    /// Everything one file needs, taken from the ring buffers in one go.
    private struct Selection {
        let window: SaveWindow
        let videoSamples: [CMSampleBuffer]
        let videoFormatDescription: CMFormatDescription
        let videoStartPTS: CMTime
        let systemAudioSamples: [CMSampleBuffer]
        let micAudioSamples: [CMSampleBuffer]
    }

    /// Takes the window's video (from the keyframe at or before its start)
    /// and audio out of the ring buffers, and logs how well they line up.
    private func select(from videoRingBuffer: VideoRingBuffer, window: SaveWindow, now: CMTime) throws -> Selection {
        let videoSamples = videoRingBuffer.samples(coveringFrom: window.start.seconds)
        let newestEnd = videoRingBuffer.newestEndPTS.map(Self.hostTime) ?? window.end

        guard !videoSamples.isEmpty else {
            throw ClipSaveError.noSamples
        }

        guard let firstVideoSample = videoSamples.first,
              let videoFormatDescription = firstVideoSample.formatDescription else {
            throw ClipSaveError.missingFormatDescription
        }

        let videoStartPTS = CMSampleBufferGetPresentationTimeStamp(firstVideoSample)
        let audioRange = Self.audioExtractionRange(videoStartPTS: videoStartPTS, videoEndPTS: window.end)

        let systemAudioSamples = systemAudioRingBuffer?.samples(between: audioRange.startPTS, and: audioRange.endPTS) ?? []
        let micAudioSamples = micRingBuffer?.samples(between: audioRange.startPTS, and: audioRange.endPTS) ?? []

        let report = Self.makeSyncReport(
            window: window,
            now: now,
            newestVideoEnd: newestEnd,
            videoStartPTS: videoStartPTS,
            audioTracks: [("sysAudio", systemAudioSamples), ("mic", micAudioSamples)]
        )
        lastSyncReport = report
        logSyncReport(report)

        return Selection(
            window: window,
            videoSamples: videoSamples,
            videoFormatDescription: videoFormatDescription,
            videoStartPTS: videoStartPTS,
            systemAudioSamples: systemAudioSamples,
            micAudioSamples: micAudioSamples
        )
    }

    private func write(
        _ selection: Selection,
        outputDirectory: URL,
        fileNameSuffix: String?,
        mergeAudioTracks: Bool,
        baseName: String? = nil
    ) async throws -> URL {
        let window = selection.window
        let videoSamples = selection.videoSamples
        let videoStartPTS = selection.videoStartPTS
        let systemAudioSamples = selection.systemAudioSamples
        let micAudioSamples = selection.micAudioSamples
        // Zero is the first video frame. Playback starts at the window, which
        // is later whenever the keyframe sits before it; it ends with the window.
        let presentationStart = Self.presentationStart(videoStartPTS: videoStartPTS, windowStart: window.start)
        let presentationEnd = CMTimeSubtract(window.end, videoStartPTS)

        let fileURL = try ClipMetadata.generateUniqueFileURL(in: outputDirectory, baseName: baseName, suffix: fileNameSuffix)

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        // Anything that fails from here on may already have created the file,
        // so clean it up rather than leave an unplayable clip in the library.
        do {
            writer.metadata = ClipMetadata.makeMetadataItems()

            let videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: selection.videoFormatDescription
            )
            videoInput.expectsMediaDataInRealTime = false

            guard writer.canAdd(videoInput) else {
                throw ClipSaveError.cannotAddInput
            }
            writer.add(videoInput)

            // Every track is shifted by the same amount, so whatever lines up
            // on the capture clock still lines up in the file.
            let offset = videoStartPTS
            var retimedVideo = videoSamples.compactMap { retimeSample($0, offset: offset) }
            // The newest frame stays on screen until the window ends: on a
            // still screen it can be a few hundred milliseconds older than the
            // save, and the audio in between still belongs to the clip.
            if let last = retimedVideo.last,
               let held = retimeSample(last, offset: .zero, holdingUntil: presentationEnd) {
                retimedVideo[retimedVideo.count - 1] = held
            }
            let retimedSystemAudio = systemAudioSamples
                .compactMap { retimeSample($0, offset: offset) }
                .filter { CMSampleBufferGetPresentationTimeStamp($0).seconds >= 0 }
            let retimedMicAudio = micAudioSamples
                .compactMap { retimeSample($0, offset: offset) }
                .filter { CMSampleBufferGetPresentationTimeStamp($0).seconds >= 0 }

            logger.info("Saving clip: video=\(retimedVideo.count) audio=\(retimedSystemAudio.count) mic=\(retimedMicAudio.count)")

            let audioPlans = try makeAudioAppendPlans(
                systemAudioSamples: retimedSystemAudio,
                micAudioSamples: retimedMicAudio,
                mergeAudioTracks: mergeAudioTracks,
                timelineEnd: presentationEnd
            )
            var audioJobs: [TrackAppendJob] = []
            for plan in audioPlans {
                let input = try makeAudioInput(for: plan.samples, writer: writer)
                audioJobs.append(TrackAppendJob(label: plan.label, samples: plan.samples, input: input, writer: writer))
            }

            guard writer.startWriting() else {
                throw ClipSaveError.cannotStartWriting
            }

            // Everything from the keyframe on is written so the first frames
            // can be decoded, but playback starts at the requested window.
            // Samples before the session start stay in the file and are left
            // out of the presentation by an edit list, so a 30 s save plays
            // as 30 s instead of 30 s plus however far back the keyframe was.
            writer.startSession(atSourceTime: presentationStart)

            // Append all tracks concurrently. AVAssetWriter stalls one input if
            // another input's timeline falls too far behind, so a purely sequential
            // per-track append deadlocks as soon as video runs past the first audio
            // frame (which has been added but not yet fed).
            var tracks: [TrackAppendJob] = [
                TrackAppendJob(label: "video", samples: retimedVideo, input: videoInput, writer: writer)
            ]
            tracks.append(contentsOf: audioJobs)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for track in tracks {
                    group.addTask {
                        try await Self.runTrack(track)
                    }
                }
                try await group.waitForAll()
            }

            writer.endSession(atSourceTime: presentationEnd)
            try await finishWriting(writer)
        } catch {
            logger.error(
                "Clip save failed file=\(fileURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            Self.discardPartialClip(writer: writer, at: fileURL)
            throw error
        }
        logger.info("Saved clip path=\(fileURL.path, privacy: .public)")

        NotificationCenter.default.post(name: .replayCapClipSaved, object: fileURL)

        return fileURL
    }

    // MARK: - Sync report

    static func makeSyncReport(
        window: SaveWindow,
        now: CMTime,
        newestVideoEnd: CMTime,
        videoStartPTS: CMTime,
        audioTracks: [(label: String, samples: [CMSampleBuffer])]
    ) -> ClipSyncReport {
        let windowStart = window.start.seconds
        let windowEnd = window.end.seconds
        // Audio under the keyframe lead-in is cut by the edit list, so only
        // the presented span counts.
        let presentedStart = max(windowStart, videoStartPTS.seconds)

        let tracks: [ClipSyncReport.AudioTrack] = audioTracks.compactMap { track in
            let spans = track.samples.compactMap { sample -> (start: Double, end: Double)? in
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard pts.isNumeric else { return nil }
                let frames = Double(CMSampleBufferGetNumSamples(sample))
                let rate = sample.formatDescription
                    .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48_000
                return (pts.seconds, pts.seconds + (rate > 0 ? frames / rate : 0))
            }
            guard let first = spans.first, let last = spans.last else { return nil }
            var largestGap = 0.0
            var covered = first.end
            for span in spans.dropFirst() {
                largestGap = max(largestGap, span.start - covered)
                covered = max(covered, span.end)
            }
            return ClipSyncReport.AudioTrack(
                label: track.label,
                leadInSeconds: max(0, first.start - presentedStart),
                tailSeconds: max(0, windowEnd - max(covered, last.end)),
                largestGapSeconds: largestGap
            )
        }

        return ClipSyncReport(
            windowStart: windowStart,
            windowEnd: windowEnd,
            anchoredToClock: window.anchoredToClock,
            videoLagSeconds: max(0, CMTimeGetSeconds(CMTimeSubtract(now, newestVideoEnd))),
            keyframeLeadSeconds: max(0, windowStart - videoStartPTS.seconds),
            audioTracks: tracks
        )
    }

    private func logSyncReport(_ report: ClipSyncReport) {
        let tracks = report.audioTracks.map {
            String(format: "%@ lead=%.3fs tail=%.3fs gap=%.3fs", $0.label, $0.leadInSeconds, $0.tailSeconds, $0.largestGapSeconds)
        }.joined(separator: " | ")
        let summary = String(
            format: "window=%.3f...%.3f clock=%@ videoLag=%.3fs keyframeLead=%.3fs",
            report.windowStart, report.windowEnd, report.anchoredToClock ? "yes" : "stale", report.videoLagSeconds, report.keyframeLeadSeconds
        )
        if report.isInSync {
            logger.notice("Clip sync OK \(summary, privacy: .public) \(tracks.isEmpty ? "no audio" : tracks, privacy: .public)")
        } else {
            logger.warning("Clip sync off \(summary, privacy: .public) \(tracks.isEmpty ? "no audio" : tracks, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Audio extraction window aligned to the selected video frames.
    /// Video samples start at a keyframe that may precede the requested duration cutoff,
    /// so audio must start at `videoStartPTS` rather than an arbitrary duration cutoff
    /// to prevent a leading muted gap in the saved clip.
    static func audioExtractionRange(
        videoStartPTS: CMTime,
        videoEndPTS: CMTime
    ) -> (startPTS: Double, endPTS: Double) {
        (
            startPTS: videoStartPTS.isValid ? videoStartPTS.seconds : 0,
            endPTS: videoEndPTS.isValid ? videoEndPTS.seconds : 0
        )
    }

    /// Where playback starts on the clip timeline (zero is the first video
    /// frame): the window's start, or zero when the buffer starts after it.
    /// Video has to start on a keyframe, which can sit up to a GOP before.
    static func presentationStart(videoStartPTS: CMTime, windowStart: CMTime) -> CMTime {
        guard videoStartPTS.isNumeric, windowStart.isNumeric else { return .zero }
        let lead = CMTimeSubtract(windowStart, videoStartPTS)
        return CMTimeCompare(lead, .zero) > 0 ? lead : .zero
    }

    static func timelineOffset(
        videoStartPTS: CMTime,
        systemAudioStartPTS: CMTime?,
        micAudioStartPTS: CMTime?
    ) -> CMTime {
        // Always anchor the clip timeline to the first video frame. If audio
        // starts earlier than video and we anchor to audio, players render a
        // black lead-in before the first video frame arrives.
        if videoStartPTS.isValid {
            return videoStartPTS
        }
        return [systemAudioStartPTS, micAudioStartPTS]
            .compactMap { $0 }
            .filter(\.isValid)
            .min(by: { $0 < $1 }) ?? .zero
    }

    private func channelCountForSamples(_ samples: [CMSampleBuffer]) -> Int {
        guard let first = samples.first,
              let formatDesc = first.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return 2 // default to stereo
        }
        return Int(asbd.pointee.mChannelsPerFrame)
    }

    private struct AudioAppendPlan {
        let label: String
        let samples: [CMSampleBuffer]
    }

    /// Every audio track goes through the mixer, merged or not, so each one is
    /// a continuous run of samples from the first video frame to the end of
    /// the clip: silence fills a late start, a dropout in the middle and a
    /// short tail. Left as holes, those let a track begin late or slide
    /// against the video wherever the file's audio timeline closes up a gap.
    private func makeAudioAppendPlans(
        systemAudioSamples: [CMSampleBuffer],
        micAudioSamples: [CMSampleBuffer],
        mergeAudioTracks: Bool,
        timelineEnd: CMTime
    ) throws -> [AudioAppendPlan] {
        if mergeAudioTracks, !systemAudioSamples.isEmpty, !micAudioSamples.isEmpty {
            do {
                let mergedSamples = try AudioTrackMixer.merge(
                    systemAudioSamples: systemAudioSamples,
                    micAudioSamples: micAudioSamples,
                    timelineEnd: timelineEnd
                )
                return [AudioAppendPlan(label: "mergedAudio", samples: mergedSamples)]
            } catch {
                logger.error("AudioTrackMixer failed (\(String(describing: error), privacy: .public)); falling back to separate audio tracks")
            }
        }

        var plans: [AudioAppendPlan] = []
        for (label, samples) in [("sysAudio", systemAudioSamples), ("mic", micAudioSamples)] where !samples.isEmpty {
            do {
                let continuous = try AudioTrackMixer.merge(
                    systemAudioSamples: samples,
                    micAudioSamples: [],
                    timelineEnd: timelineEnd
                )
                plans.append(AudioAppendPlan(label: label, samples: continuous))
            } catch {
                logger.error("Could not make \(label, privacy: .public) continuous (\(String(describing: error), privacy: .public)); writing it as captured")
                plans.append(AudioAppendPlan(label: label, samples: Self.padLeadingSilenceIfNeeded(samples)))
            }
        }
        return plans
    }

    /// Prepend silence buffers starting at timeline zero if unmerged audio samples begin
    /// after video start (> 20ms). This ensures every individual audio track in the MP4
    /// file starts synchronously with video at t = 0, preventing muted lead-ins.
    private static func padLeadingSilenceIfNeeded(_ samples: [CMSampleBuffer]) -> [CMSampleBuffer] {
        guard let first = samples.first else { return samples }
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(first)
        guard firstPTS.isValid, firstPTS.seconds > 0.02,
              let formatDesc = first.formatDescription,
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return samples
        }
        let asbd = asbdPointer.pointee
        let sampleRate = asbd.mSampleRate
        guard sampleRate > 0 else { return samples }

        let gapDuration = firstPTS.seconds
        let totalFrames = Int(gapDuration * sampleRate)
        guard totalFrames > 0 else { return samples }

        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerFrame = isNonInterleaved
            ? Int(asbd.mBytesPerFrame) * max(1, Int(asbd.mChannelsPerFrame))
            : Int(asbd.mBytesPerFrame)
        let maxFramesPerChunk = 2048
        var silenceBuffers: [CMSampleBuffer] = []
        var currentFrame = 0

        while currentFrame < totalFrames {
            let chunkFrames = min(maxFramesPerChunk, totalFrames - currentFrame)
            let byteCount = chunkFrames * bytesPerFrame
            var blockBuffer: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            ) == noErr, let blockBuffer else { break }

            guard CMBlockBufferFillDataBytes(
                with: 0,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            ) == noErr else { break }

            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: Int64(currentFrame), timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid
            )
            var silenceBuffer: CMSampleBuffer?
            guard CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDesc,
                sampleCount: CMItemCount(chunkFrames),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &silenceBuffer
            ) == noErr, let silenceBuffer else { break }

            silenceBuffers.append(silenceBuffer)
            currentFrame += chunkFrames
        }

        return silenceBuffers + samples
    }

    private func makeAudioInput(for samples: [CMSampleBuffer], writer: AVAssetWriter) throws -> AVAssetWriterInput {
        // AAC in this writer is mono or stereo. Wider settings with no channel
        // layout make AVAssetWriterInput raise an Objective-C exception, which
        // nothing here can catch, so capture mixes wider sources down and the
        // layout is always spelled out.
        let channelCount = min(max(channelCountForSamples(samples), 1), 2)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channelCount == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channelCount,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVEncoderBitRateKey: channelCount == 2 ? 192000 : 96000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw ClipSaveError.cannotAddInput
        }
        writer.add(input)
        return input
    }

    /// Shifts a sample by `offset`. With `holdingUntil`, a single-timing sample
    /// (a video frame) is also lengthened so it stays on screen until then.
    private func retimeSample(_ sample: CMSampleBuffer, offset: CMTime, holdingUntil: CMTime? = nil) -> CMSampleBuffer? {
        var originalTimings: [CMSampleTimingInfo]
        if let timings = try? sample.sampleTimingInfos(), !timings.isEmpty {
            originalTimings = timings
        } else {
            // Raw PCM audio from SCK often has no timing info array — construct from PTS/duration
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            originalTimings = [CMSampleTimingInfo(
                duration: duration.isValid ? duration : CMTime(value: 1, timescale: 48000),
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )]
        }

        let newTimings = originalTimings.map { timing in
            var duration = timing.duration
            if let holdingUntil, originalTimings.count == 1, timing.presentationTimeStamp.isNumeric {
                let held = CMTimeSubtract(holdingUntil, CMTimeSubtract(timing.presentationTimeStamp, offset))
                if CMTimeCompare(held, duration.isNumeric ? duration : .zero) > 0 {
                    duration = held
                }
            }
            return CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: CMTimeSubtract(timing.presentationTimeStamp, offset),
                decodeTimeStamp: timing.decodeTimeStamp.isValid
                    ? CMTimeSubtract(timing.decodeTimeStamp, offset)
                    : .invalid
            )
        }

        var newSample: CMSampleBuffer?
        let status: OSStatus = newTimings.withUnsafeBufferPointer { timingPtr in
            guard let baseAddress = timingPtr.baseAddress else {
                return OSStatus(kCMSampleBufferError_AllocationFailed)
            }
            return CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sample,
                sampleTimingEntryCount: newTimings.count,
                sampleTimingArray: baseAddress,
                sampleBufferOut: &newSample
            )
        }

        guard status == noErr else { return nil }
        return newSample
    }

    private struct TrackAppendJob: @unchecked Sendable {
        let label: String
        let samples: [CMSampleBuffer]
        let input: AVAssetWriterInput
        let writer: AVAssetWriter
    }

    private static func runTrack(_ job: TrackAppendJob) async throws {
        try await appendSamples(job.samples, to: job.input, writer: job.writer, label: job.label)
        job.input.markAsFinished()
        logger.debug("Finished appending track=\(job.label, privacy: .public) samples=\(job.samples.count, privacy: .public)")
    }

    private static func appendSamples(
        _ samples: [CMSampleBuffer],
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        label: String
    ) async throws {
        // Polling (a 1 ms suspending sleep, not a blocked thread) is deliberate.
        // requestMediaDataWhenReady only re-invokes its block when the input
        // becomes ready again, so a writer that fails while every input is
        // stalled would leave the continuation hanging unless a separate
        // status watchdog polled anyway. The SDK also deprecates both it and
        // isReadyForMoreMediaData in favour of the async append on macOS 27;
        // that is the API to move to once the deployment target allows it.
        for (index, sample) in samples.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
                guard writer.status == .writing else {
                    logger.error(
                        "Writer stopped while track=\(label, privacy: .public) waited at sample \(index, privacy: .public)/\(samples.count, privacy: .public) status=\(writer.status.rawValue, privacy: .public) error=\(writer.error?.localizedDescription ?? "none", privacy: .public)"
                    )
                    throw ClipSaveError.writerFailed(writer.error)
                }
            }
            guard input.append(sample) else {
                logger.error(
                    "Append failed track=\(label, privacy: .public) sample=\(index, privacy: .public)/\(samples.count, privacy: .public) status=\(writer.status.rawValue, privacy: .public) error=\(writer.error?.localizedDescription ?? "none", privacy: .public)"
                )
                throw ClipSaveError.appendFailed(writer.error)
            }
        }
    }

    /// "first...last" PTS in seconds, for debug logging.
    private static func ptsRange(_ samples: [CMSampleBuffer]) -> String {
        guard let first = samples.first, let last = samples.last else { return "empty" }
        let start = CMSampleBufferGetPresentationTimeStamp(first).seconds
        let end = CMSampleBufferGetPresentationTimeStamp(last).seconds
        return String(format: "%.3f...%.3f", start, end)
    }

    /// Stops a writer that did not finish and deletes whatever it wrote.
    private static func discardPartialClip(writer: AVAssetWriter, at fileURL: URL) {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        // Best effort: the file may never have been created.
        try? FileManager.default.removeItem(at: fileURL)
    }

    private final class WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter
        init(_ writer: AVAssetWriter) { self.writer = writer }
    }

    private func finishWriting(_ writer: AVAssetWriter) async throws {
        let box = WriterBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                switch box.writer.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled, .unknown, .writing:
                    continuation.resume(throwing: ClipSaveError.writerFailed(box.writer.error))
                @unknown default:
                    continuation.resume(throwing: ClipSaveError.writerFailed(box.writer.error))
                }
            }
        }
    }
}
