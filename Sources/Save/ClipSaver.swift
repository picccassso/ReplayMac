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

public actor ClipSaver {
    private let videoRingBuffer: VideoRingBuffer
    private let dualDisplay1VideoRingBuffer: VideoRingBuffer?
    private let dualDisplay2VideoRingBuffer: VideoRingBuffer?
    private let systemAudioRingBuffer: AudioRingBuffer?
    private let micRingBuffer: AudioRingBuffer?
    private static let logger = Logger(subsystem: "com.replaycap", category: "Save")
    private var logger: Logger { Self.logger }

    public init(
        videoRingBuffer: VideoRingBuffer,
        dualDisplay1VideoRingBuffer: VideoRingBuffer? = nil,
        dualDisplay2VideoRingBuffer: VideoRingBuffer? = nil,
        systemAudioRingBuffer: AudioRingBuffer? = nil,
        micRingBuffer: AudioRingBuffer? = nil
    ) {
        self.videoRingBuffer = videoRingBuffer
        self.dualDisplay1VideoRingBuffer = dualDisplay1VideoRingBuffer
        self.dualDisplay2VideoRingBuffer = dualDisplay2VideoRingBuffer
        self.systemAudioRingBuffer = systemAudioRingBuffer
        self.micRingBuffer = micRingBuffer
    }

    public func saveClip(
        lastSeconds: TimeInterval,
        outputDirectory: URL,
        mergeAudioTracks: Bool = true,
        baseName: String? = nil
    ) async throws -> URL {
        try await saveClip(
            from: videoRingBuffer,
            lastSeconds: lastSeconds,
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

        let display1URL = try await saveClip(
            from: dualDisplay1VideoRingBuffer,
            lastSeconds: lastSeconds,
            outputDirectory: outputDirectory,
            fileNameSuffix: "Display_1",
            mergeAudioTracks: mergeAudioTracks,
            baseName: baseName
        )
        let display2URL = try await saveClip(
            from: dualDisplay2VideoRingBuffer,
            lastSeconds: lastSeconds,
            outputDirectory: outputDirectory,
            fileNameSuffix: "Display_2",
            mergeAudioTracks: mergeAudioTracks,
            baseName: baseName
        )

        return [display1URL, display2URL]
    }

    private func saveClip(
        from videoRingBuffer: VideoRingBuffer,
        lastSeconds: TimeInterval,
        outputDirectory: URL,
        fileNameSuffix: String?,
        mergeAudioTracks: Bool,
        baseName: String? = nil
    ) async throws -> URL {
        let videoSamples = videoRingBuffer.samples(last: lastSeconds)

        guard !videoSamples.isEmpty else {
            throw ClipSaveError.noSamples
        }

        guard let firstVideoSample = videoSamples.first,
              let videoFormatDescription = firstVideoSample.formatDescription else {
            throw ClipSaveError.missingFormatDescription
        }

        let videoStartPTS = CMSampleBufferGetPresentationTimeStamp(firstVideoSample)
        let videoEndPTS = CMSampleBufferGetPresentationTimeStamp(videoSamples.last!)
        let audioRange = Self.audioExtractionRange(videoStartPTS: videoStartPTS, videoEndPTS: videoEndPTS)

        let systemAudioSamples = systemAudioRingBuffer?.samples(between: audioRange.startPTS, and: audioRange.endPTS) ?? []
        let micAudioSamples = micRingBuffer?.samples(between: audioRange.startPTS, and: audioRange.endPTS) ?? []
        logger.debug(
            "Selected samples video=\(videoSamples.count, privacy: .public) \(Self.ptsRange(videoSamples), privacy: .public) sysAudio=\(systemAudioSamples.count, privacy: .public) \(Self.ptsRange(systemAudioSamples), privacy: .public) mic=\(micAudioSamples.count, privacy: .public) \(Self.ptsRange(micAudioSamples), privacy: .public)"
        )

        let fileURL = try ClipMetadata.generateUniqueFileURL(in: outputDirectory, baseName: baseName, suffix: fileNameSuffix)

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        // Anything that fails from here on may already have created the file,
        // so clean it up rather than leave an unplayable clip in the library.
        do {
            writer.metadata = ClipMetadata.makeMetadataItems()

            // Video input
            let videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: videoFormatDescription
            )
            videoInput.expectsMediaDataInRealTime = false

            guard writer.canAdd(videoInput) else {
                throw ClipSaveError.cannotAddInput
            }
            writer.add(videoInput)

            let systemAudioStartPTS = systemAudioSamples.first.map { CMSampleBufferGetPresentationTimeStamp($0) }
            let micAudioStartPTS = micAudioSamples.first.map { CMSampleBufferGetPresentationTimeStamp($0) }
            let offset = Self.timelineOffset(
                videoStartPTS: videoStartPTS,
                systemAudioStartPTS: systemAudioStartPTS,
                micAudioStartPTS: micAudioStartPTS
            )

            let retimedVideo = videoSamples.compactMap { retimeSample($0, offset: offset) }
            let retimedSystemAudio = systemAudioSamples
                .compactMap { retimeSample($0, offset: offset) }
                .filter { CMSampleBufferGetPresentationTimeStamp($0).seconds >= 0 }
            let retimedMicAudio = micAudioSamples
                .compactMap { retimeSample($0, offset: offset) }
                .filter { CMSampleBufferGetPresentationTimeStamp($0).seconds >= 0 }

            logger.info("Saving clip: video=\(retimedVideo.count) audio=\(retimedSystemAudio.count) mic=\(retimedMicAudio.count)")
            if let audioStart = [systemAudioStartPTS, micAudioStartPTS].compactMap({ $0 }).filter(\.isValid).min(by: { $0 < $1 }) {
                let delta = audioStart.seconds - videoStartPTS.seconds
                if delta > 0.05 {
                    logger.warning("Audio capture started \(delta, format: .fixed(precision: 3))s after video start; lead-in will be padded with silence")
                }
            }
            let earliestTrackStart = [videoStartPTS, systemAudioStartPTS, micAudioStartPTS]
                .compactMap { $0 }
                .filter(\.isValid)
                .min(by: { $0 < $1 }) ?? videoStartPTS
            logger.debug(
                "Retimed offset=\(offset.seconds, privacy: .public) earliestTrackStart=\(earliestTrackStart.seconds, privacy: .public) video \(Self.ptsRange(retimedVideo), privacy: .public) sysAudio \(Self.ptsRange(retimedSystemAudio), privacy: .public) mic \(Self.ptsRange(retimedMicAudio), privacy: .public)"
            )

            let audioPlans = try makeAudioAppendPlans(
                systemAudioSamples: retimedSystemAudio,
                micAudioSamples: retimedMicAudio,
                mergeAudioTracks: mergeAudioTracks
            )
            var audioJobs: [TrackAppendJob] = []
            for plan in audioPlans {
                let input = try makeAudioInput(for: plan.samples, writer: writer)
                audioJobs.append(TrackAppendJob(label: plan.label, samples: plan.samples, input: input, writer: writer))
            }

            guard writer.startWriting() else {
                throw ClipSaveError.cannotStartWriting
            }

            writer.startSession(atSourceTime: .zero)

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

    private func makeAudioAppendPlans(
        systemAudioSamples: [CMSampleBuffer],
        micAudioSamples: [CMSampleBuffer],
        mergeAudioTracks: Bool
    ) throws -> [AudioAppendPlan] {
        if mergeAudioTracks, !systemAudioSamples.isEmpty, !micAudioSamples.isEmpty {
            do {
                let mergedSamples = try AudioTrackMixer.merge(
                    systemAudioSamples: systemAudioSamples,
                    micAudioSamples: micAudioSamples
                )
                return [AudioAppendPlan(label: "mergedAudio", samples: mergedSamples)]
            } catch {
                logger.error("AudioTrackMixer failed (\(String(describing: error), privacy: .public)); falling back to separate audio tracks")
            }
        }

        var plans: [AudioAppendPlan] = []
        if !systemAudioSamples.isEmpty {
            let padded = Self.padLeadingSilenceIfNeeded(systemAudioSamples)
            plans.append(AudioAppendPlan(label: "sysAudio", samples: padded))
        }
        if !micAudioSamples.isEmpty {
            let padded = Self.padLeadingSilenceIfNeeded(micAudioSamples)
            plans.append(AudioAppendPlan(label: "mic", samples: padded))
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
        let channelCount = channelCountForSamples(samples)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channelCount,
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

    private func retimeSample(_ sample: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
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
            CMSampleTimingInfo(
                duration: timing.duration,
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
