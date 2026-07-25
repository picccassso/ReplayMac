import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os.log

public enum CompositionRemuxError: LocalizedError {
    case noTracks
    case cannotAddReaderOutput(String)
    case cannotAddWriterInput(String)
    case cannotStartReading(Error?)
    case cannotStartWriting(Error?)
    case appendFailed(String, Error?)
    case writeFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .noTracks:
            return "The recording has no tracks to write."
        case .cannotAddReaderOutput(let label):
            return "Unable to read the \(label) track of the recording."
        case .cannotAddWriterInput(let label):
            return "Unable to write the \(label) track of the recording."
        case .cannotStartReading(let error):
            return "Unable to read the recording: \(error?.localizedDescription ?? "unknown")"
        case .cannotStartWriting(let error):
            return "Unable to write the recording: \(error?.localizedDescription ?? "unknown")"
        case .appendFailed(let label, let error):
            return "Failed writing the \(label) track: \(error?.localizedDescription ?? "unknown")"
        case .writeFailed(let error):
            return "Failed finishing the recording: \(error?.localizedDescription ?? "unknown")"
        }
    }
}

/// Writes a composition to an MP4 while passing compressed video through untouched.
///
/// `AVAssetExportSession` has no preset that passes video through *and* mixes
/// audio: asking it to merge two audio tracks selects a transcoding preset, so
/// every frame is decoded and re-encoded purely to combine two audio streams.
/// Driving an `AVAssetReader`/`AVAssetWriter` pair directly lets video sample
/// buffers move across in their stored format and confines encoding to audio.
enum CompositionRemuxer {
    private static let logger = Logger(subsystem: "com.replaycap", category: "Remux")

    /// LPCM the audio mixer decodes into before the AAC encoder picks it up.
    /// Interleaved 16-bit is the format `AVAssetReaderAudioMixOutput` accepts
    /// on every supported macOS version; the extra precision of float would be
    /// discarded by the AAC encode that follows regardless.
    private static var mixPCMSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// Matches the AAC settings the segment writer already uses, so a merged
    /// track is indistinguishable from a passed-through one.
    private static var aacSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
    }

    /// - Parameter mergeAudioTracks: when true and the composition carries more
    ///   than one audio track, the tracks are mixed down to a single AAC track.
    ///   Otherwise every audio track is passed through in its stored format.
    static func write(
        composition: AVComposition,
        to outputURL: URL,
        mergeAudioTracks: Bool,
        metadata: [AVMetadataItem]
    ) async throws {
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
            throw CompositionRemuxError.noTracks
        }

        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.metadata = metadata
        writer.shouldOptimizeForNetworkUse = true

        var pipes: [TrackPipe] = []

        if let videoTrack = videoTracks.first {
            // A session is stitched from independently written segments, so the
            // track normally carries one sample description per segment. MP4
            // stores several of those in a single track, and passthrough only
            // gives up when the writer rejects an append — which the caller
            // handles by falling back to a transcode.
            let formatDescriptions = try await videoTrack.load(.formatDescriptions)
            if formatDescriptions.count > 1 {
                logger.debug(
                    "Composition video track carries \(formatDescriptions.count, privacy: .public) format descriptions"
                )
            }
            pipes.append(
                try makePassthroughPipe(
                    label: "video",
                    mediaType: .video,
                    track: videoTrack,
                    formatDescription: formatDescriptions.first,
                    reader: reader,
                    writer: writer
                )
            )
        }

        if mergeAudioTracks, audioTracks.count > 1 {
            pipes.append(try makeMixedAudioPipe(tracks: audioTracks, reader: reader, writer: writer))
        } else {
            for (index, track) in audioTracks.enumerated() {
                pipes.append(
                    try makePassthroughPipe(
                        label: "audio \(index)",
                        mediaType: .audio,
                        track: track,
                        formatDescription: try await track.load(.formatDescriptions).first,
                        reader: reader,
                        writer: writer
                    )
                )
            }
        }

        guard reader.startReading() else {
            throw CompositionRemuxError.cannotStartReading(reader.error)
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw CompositionRemuxError.cannotStartWriting(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let readerBox = ReaderBox(reader)
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for pipe in pipes {
                        group.addTask { try await drain(pipe) }
                    }
                    try await group.waitForAll()
                }
            } onCancel: {
                readerBox.reader.cancelReading()
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        switch reader.status {
        case .cancelled:
            writer.cancelWriting()
            throw CancellationError()
        case .failed:
            writer.cancelWriting()
            throw CompositionRemuxError.cannotStartReading(reader.error)
        default:
            break
        }

        try await finishWriting(writer)
    }

    // MARK: - Track wiring

    private static func makePassthroughPipe(
        label: String,
        mediaType: AVMediaType,
        track: AVAssetTrack,
        formatDescription: CMFormatDescription?,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) throws -> TrackPipe {
        // A nil `outputSettings` vends sample buffers in their stored format,
        // so nothing is decoded on the way out.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CompositionRemuxError.cannotAddReaderOutput(label)
        }
        reader.add(output)

        let input = AVAssetWriterInput(
            mediaType: mediaType,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw CompositionRemuxError.cannotAddWriterInput(label)
        }
        writer.add(input)

        return TrackPipe(label: label, output: output, input: input)
    }

    private static func makeMixedAudioPipe(
        tracks: [AVAssetTrack],
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) throws -> TrackPipe {
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: mixPCMSettings)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1, at: .zero)
            return parameters
        }
        output.audioMix = audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CompositionRemuxError.cannotAddReaderOutput("mixed audio")
        }
        reader.add(output)

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw CompositionRemuxError.cannotAddWriterInput("mixed audio")
        }
        writer.add(input)

        return TrackPipe(label: "mixed audio", output: output, input: input)
    }

    // MARK: - Pumping

    private static func drain(_ pipe: TrackPipe) async throws {
        let queue = DispatchQueue(label: "com.replaycap.remux", qos: .userInitiated)
        let resume = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pipe.input.requestMediaDataWhenReady(on: queue) {
                while pipe.input.isReadyForMoreMediaData {
                    guard let sample = pipe.output.copyNextSampleBuffer() else {
                        pipe.input.markAsFinished()
                        if resume.claim() {
                            continuation.resume()
                        }
                        return
                    }
                    if !pipe.input.append(sample) {
                        pipe.input.markAsFinished()
                        if resume.claim() {
                            continuation.resume(
                                throwing: CompositionRemuxError.appendFailed(pipe.label, nil)
                            )
                        }
                        return
                    }
                }
            }
        }
    }

    private static func finishWriting(_ writer: AVAssetWriter) async throws {
        let box = WriterBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.writer.finishWriting {
                if box.writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CompositionRemuxError.writeFailed(box.writer.error))
                }
            }
        }
    }

    // MARK: - Boxes

    private final class TrackPipe: @unchecked Sendable {
        let label: String
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput

        init(label: String, output: AVAssetReaderOutput, input: AVAssetWriterInput) {
            self.label = label
            self.output = output
            self.input = input
        }
    }

    private final class ReaderBox: @unchecked Sendable {
        let reader: AVAssetReader

        init(_ reader: AVAssetReader) {
            self.reader = reader
        }
    }

    private final class WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter

        init(_ writer: AVAssetWriter) {
            self.writer = writer
        }
    }

    /// `requestMediaDataWhenReady` re-enters its callback, so the terminal
    /// branches must resume the continuation exactly once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed {
                return false
            }
            claimed = true
            return true
        }
    }
}
