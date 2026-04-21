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
    private let systemAudioRingBuffer: AudioRingBuffer?
    private let micRingBuffer: AudioRingBuffer?
    private let logger = Logger(subsystem: "com.replaymac", category: "Save")

    public init(
        videoRingBuffer: VideoRingBuffer,
        systemAudioRingBuffer: AudioRingBuffer? = nil,
        micRingBuffer: AudioRingBuffer? = nil
    ) {
        self.videoRingBuffer = videoRingBuffer
        self.systemAudioRingBuffer = systemAudioRingBuffer
        self.micRingBuffer = micRingBuffer
    }

    public func saveClip(
        lastSeconds: TimeInterval,
        outputDirectory: URL
    ) async throws -> URL {
        let videoSamples = videoRingBuffer.samples(last: lastSeconds)

        guard !videoSamples.isEmpty else {
            throw ClipSaveError.noSamples
        }

        let videoEndPTS = CMSampleBufferGetPresentationTimeStamp(videoSamples.last!).seconds
        let requestedWindowStartPTS = videoEndPTS - lastSeconds

        let systemAudioSamples = systemAudioRingBuffer?.samples(between: requestedWindowStartPTS, and: videoEndPTS) ?? []
        let micAudioSamples = micRingBuffer?.samples(between: requestedWindowStartPTS, and: videoEndPTS) ?? []
        let firstAudioTimingCount = systemAudioSamples.first.flatMap { try? $0.sampleTimingInfos().count } ?? -1
        print("[SAVE] video=\(videoSamples.count) sysAudio=\(systemAudioSamples.count) mic=\(micAudioSamples.count)")
        print("[SAVE] first audio timing count: \(firstAudioTimingCount)")
        if let firstVideo = videoSamples.first, let lastVideo = videoSamples.last {
            print("[SAVE] video PTS range: \(CMSampleBufferGetPresentationTimeStamp(firstVideo).seconds) ... \(CMSampleBufferGetPresentationTimeStamp(lastVideo).seconds)")
        }
        if let firstSystem = systemAudioSamples.first, let lastSystem = systemAudioSamples.last {
            print("[SAVE] sysAudio PTS range: \(CMSampleBufferGetPresentationTimeStamp(firstSystem).seconds) ... \(CMSampleBufferGetPresentationTimeStamp(lastSystem).seconds)")
        }
        if let firstMic = micAudioSamples.first, let lastMic = micAudioSamples.last {
            print("[SAVE] mic PTS range: \(CMSampleBufferGetPresentationTimeStamp(firstMic).seconds) ... \(CMSampleBufferGetPresentationTimeStamp(lastMic).seconds)")
        }

        let fileURL = try ClipMetadata.generateUniqueFileURL(in: outputDirectory)

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        writer.metadata = ClipMetadata.makeMetadataItems()

        guard let firstVideoSample = videoSamples.first,
              let videoFormatDescription = firstVideoSample.formatDescription else {
            throw ClipSaveError.missingFormatDescription
        }

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

        // System audio input — encode to AAC on write
        var systemAudioInput: AVAssetWriterInput?
        if !systemAudioSamples.isEmpty {
            let channelCount = channelCountForSamples(systemAudioSamples)
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
            systemAudioInput = input
        }

        // Mic audio input — encode to AAC on write
        var micAudioInput: AVAssetWriterInput?
        if !micAudioSamples.isEmpty {
            let channelCount = channelCountForSamples(micAudioSamples)
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
            micAudioInput = input
        }

        guard writer.startWriting() else {
            throw ClipSaveError.cannotStartWriting
        }

        writer.startSession(atSourceTime: .zero)

        let videoStartPTS = CMSampleBufferGetPresentationTimeStamp(firstVideoSample)
        let systemAudioStartPTS = systemAudioSamples.first.map { CMSampleBufferGetPresentationTimeStamp($0) }
        let micAudioStartPTS = micAudioSamples.first.map { CMSampleBufferGetPresentationTimeStamp($0) }
        let offset = [videoStartPTS, systemAudioStartPTS, micAudioStartPTS]
            .compactMap { $0 }
            .filter(\.isValid)
            .min(by: { $0 < $1 }) ?? videoStartPTS

        let retimedVideo = videoSamples.compactMap { retimeSample($0, offset: offset) }
        let retimedSystemAudio = systemAudioSamples
            .compactMap { retimeSample($0, offset: offset) }
            .filter { CMSampleBufferGetPresentationTimeStamp($0).seconds >= 0 }
        let retimedMicAudio = micAudioSamples
            .compactMap { retimeSample($0, offset: offset) }
            .filter { CMSampleBufferGetPresentationTimeStamp($0).seconds >= 0 }

        logger.info("Saving clip: video=\(retimedVideo.count) audio=\(retimedSystemAudio.count) mic=\(retimedMicAudio.count)")
        print("[SAVE] offset=\(offset.seconds) retimed video=\(retimedVideo.count) sysAudio=\(retimedSystemAudio.count) mic=\(retimedMicAudio.count)")
        if let firstV = retimedVideo.first, let lastV = retimedVideo.last {
            print("[SAVE] retimed video PTS: \(CMSampleBufferGetPresentationTimeStamp(firstV).seconds) ... \(CMSampleBufferGetPresentationTimeStamp(lastV).seconds)")
        }
        if let firstA = retimedSystemAudio.first, let lastA = retimedSystemAudio.last {
            print("[SAVE] retimed sysAudio PTS: \(CMSampleBufferGetPresentationTimeStamp(firstA).seconds) ... \(CMSampleBufferGetPresentationTimeStamp(lastA).seconds)")
        }
        if let firstM = retimedMicAudio.first, let lastM = retimedMicAudio.last {
            print("[SAVE] retimed mic PTS: \(CMSampleBufferGetPresentationTimeStamp(firstM).seconds) ... \(CMSampleBufferGetPresentationTimeStamp(lastM).seconds)")
        }

        // Append all tracks concurrently. AVAssetWriter stalls one input if
        // another input's timeline falls too far behind, so a purely sequential
        // per-track append deadlocks as soon as video runs past the first audio
        // frame (which has been added but not yet fed).
        print("[SAVE] appending concurrently: video=\(retimedVideo.count) sysAudio=\(retimedSystemAudio.count) mic=\(retimedMicAudio.count)")
        var tracks: [TrackAppendJob] = [
            TrackAppendJob(label: "video", samples: retimedVideo, input: videoInput, writer: writer)
        ]
        if let systemAudioInput, !retimedSystemAudio.isEmpty {
            tracks.append(TrackAppendJob(label: "sysAudio", samples: retimedSystemAudio, input: systemAudioInput, writer: writer))
        }
        if let micAudioInput, !retimedMicAudio.isEmpty {
            tracks.append(TrackAppendJob(label: "mic", samples: retimedMicAudio, input: micAudioInput, writer: writer))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for track in tracks {
                group.addTask {
                    try await Self.runTrack(track)
                }
            }
            try await group.waitForAll()
        }

        print("[SAVE] calling finishWriting...")
        try await finishWriting(writer)
        print("[SAVE] finishWriting returned")

        NotificationCenter.default.post(name: .replayMacClipSaved, object: fileURL)

        return fileURL
    }

    // MARK: - Helpers

    private func channelCountForSamples(_ samples: [CMSampleBuffer]) -> Int {
        guard let first = samples.first,
              let formatDesc = first.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return 2 // default to stereo
        }
        return Int(asbd.pointee.mChannelsPerFrame)
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
        print("[SAVE] \(job.label) markAsFinished; writer.status=\(job.writer.status.rawValue)")
    }

    private static func appendSamples(
        _ samples: [CMSampleBuffer],
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        label: String
    ) async throws {
        var waitIterations = 0
        for (index, sample) in samples.enumerated() {
            while !input.isReadyForMoreMediaData {
                waitIterations += 1
                if waitIterations == 1 || waitIterations % 500 == 0 {
                    print("[SAVE] \(label) waiting for readiness at sample \(index)/\(samples.count); waitIter=\(waitIterations) writer.status=\(writer.status.rawValue)")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
                guard writer.status == .writing else {
                    print("[SAVE] \(label) writer left .writing during wait: status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
                    throw ClipSaveError.writerFailed(writer.error)
                }
            }
            guard input.append(sample) else {
                print("[SAVE] \(label) append failed at sample \(index)/\(samples.count); writer.status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
                throw ClipSaveError.appendFailed(writer.error)
            }
            if index == 0 || (index + 1) % 200 == 0 || index == samples.count - 1 {
                print("[SAVE] \(label) appended \(index + 1)/\(samples.count)")
            }
        }
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
