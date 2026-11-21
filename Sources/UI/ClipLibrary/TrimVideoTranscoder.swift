import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreVideo
import VideoToolbox

enum TrimVideoTranscodeError: LocalizedError {
    case noVideoTrack
    case cannotAddReaderOutput(String)
    case cannotAddWriterInput(String)
    case cannotStartReading(Error?)
    case cannotStartWriting(Error?)
    case appendFailed(String, Error?)
    case writeFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The clip does not contain a video track to export."
        case .cannotAddReaderOutput(let label):
            return "Unable to read the \(label) track for export."
        case .cannotAddWriterInput(let label):
            return "Unable to configure the \(label) track for HEVC export."
        case .cannotStartReading(let error):
            return "Unable to read the clip: \(error?.localizedDescription ?? "unknown error")"
        case .cannotStartWriting(let error):
            return "Unable to start the HEVC export: \(error?.localizedDescription ?? "unknown error")"
        case .appendFailed(let label, let error):
            return "Failed while exporting the \(label) track: \(error?.localizedDescription ?? "unknown error")"
        case .writeFailed(let error):
            return "Failed to finish the HEVC export: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}

/// A cancellable AVAssetReader/AVAssetWriter HEVC export. AVAssetExportSession
/// presets choose their own bitrate, so a reader/writer pipeline is required
/// for meaningful Compact/Balanced/High quality controls and size estimates.
final class TrimVideoTranscoder: @unchecked Sendable {
    // @unchecked: mutable state is only touched inside `stateLock`.
    private let stateLock = NSLock()
    private var activeReader: AVAssetReader?
    private var activeWriter: AVAssetWriter?
    private var activePumps: [PipePumpState] = []
    private var cancelled = false
    private var _progress: Double = 0

    var progress: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _progress
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        let reader = activeReader
        let writer = activeWriter
        let pumps = activePumps
        activePumps.removeAll()
        stateLock.unlock()
        for pump in pumps {
            pump.finish(returning: .failure(CancellationError()))
        }
        if reader?.status == .reading { reader?.cancelReading() }
        if writer?.status == .writing { writer?.cancelWriting() }
    }

    func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        videoComposition: AVVideoComposition? = nil,
        outputSize: CGSize,
        videoBitrateMbps: Double,
        to outputURL: URL
    ) async throws {
        try checkCancellation()
        setProgress(0)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw TrimVideoTranscodeError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var isHDR = false
        for track in videoTracks {
            if try await track.load(.mediaCharacteristics).contains(.containsHDRVideo) {
                isHDR = true
                break
            }
        }
        let nominalFrameRate = try await videoTracks[0].load(.nominalFrameRate)
        let frameRate = nominalFrameRate.isFinite && nominalFrameRate > 0
            ? nominalFrameRate
            : 30

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = (try? await asset.load(.metadata)) ?? []

        let videoPixelFormatSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: isHDR
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        // When not cropping (and the single video track has no rotation/flip
        // transform), decode directly from the track and let AVAssetWriterInput
        // scale. This bypasses the video compositor and preserves variable
        // frame-rate timestamps from ScreenCaptureKit recordings.
        let resolvedComposition: AVVideoComposition?
        if let videoComposition {
            resolvedComposition = videoComposition
        } else if videoTracks.count == 1,
                  try await videoTracks[0].load(.preferredTransform).isIdentity {
            resolvedComposition = nil
        } else {
            resolvedComposition = try await VideoCropper.videoComposition(
                for: asset,
                crop: .fullFrame,
                outputSize: outputSize
            )
        }

        let videoOutput: AVAssetReaderOutput
        if let resolvedComposition {
            let compositionOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: videoPixelFormatSettings
            )
            compositionOutput.videoComposition = resolvedComposition
            compositionOutput.alwaysCopiesSampleData = false
            videoOutput = compositionOutput
        } else {
            let trackOutput = AVAssetReaderTrackOutput(
                track: videoTracks[0],
                outputSettings: videoPixelFormatSettings
            )
            trackOutput.alwaysCopiesSampleData = false
            videoOutput = trackOutput
        }
        guard reader.canAdd(videoOutput) else {
            throw TrimVideoTranscodeError.cannotAddReaderOutput("video")
        }
        reader.add(videoOutput)

        let bitrate = max(1_000_000, Int(videoBitrateMbps * 1_000_000))
        var compressionProperties: [String: Any] = [
            kVTCompressionPropertyKey_AverageBitRate as String: bitrate,
            kVTCompressionPropertyKey_DataRateLimits as String: [
                Double(bitrate) / 8 * 1.5,
                1.0
            ],
            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
            AVVideoAllowFrameReorderingKey: true,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: true
        ]
        if isHDR {
            compressionProperties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            compressionProperties[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String]
                = kVTHDRMetadataInsertionMode_None
        }

        let colorProperties: [String: Any] = isHDR
            ? [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
            : [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compressionProperties,
            AVVideoColorPropertiesKey: colorProperties
        ]
        if resolvedComposition == nil {
            videoSettings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspectFill
        }
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            compressionProperties.removeValue(
                forKey: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String
            )
            videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties
            guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
                throw TrimVideoTranscodeError.cannotAddWriterInput("video")
            }
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw TrimVideoTranscodeError.cannotAddWriterInput("video")
        }
        writer.add(videoInput)

        var pipes = [TrackPipe(label: "video", isVideo: true, output: videoOutput, input: videoInput)]
        for (index, track) in audioTracks.enumerated() {
            let label = "audio \(index + 1)"
            let (output, input) = await Self.makeAudioPipe(
                for: track,
                reader: reader,
                writer: writer
            )
            guard reader.canAdd(output) else {
                throw TrimVideoTranscodeError.cannotAddReaderOutput(label)
            }
            reader.add(output)
            guard writer.canAdd(input) else {
                throw TrimVideoTranscodeError.cannotAddWriterInput(label)
            }
            writer.add(input)
            pipes.append(TrackPipe(label: label, isVideo: false, output: output, input: input))
        }

        try checkCancellation()
        guard reader.startReading() else {
            throw TrimVideoTranscodeError.cannotStartReading(reader.error)
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw TrimVideoTranscodeError.cannotStartWriting(writer.error)
        }
        writer.startSession(atSourceTime: timeRange.start)
        guard install(reader: reader, writer: writer) else {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        defer { clearActiveObjects(reader: reader, writer: writer) }

        let writerBox = WriterBox(writer)
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for pipe in pipes {
                        group.addTask {
                            try await self.drain(pipe, writer: writerBox, timeRange: timeRange)
                        }
                    }
                    try await group.waitForAll()
                }
            } onCancel: {
                self.cancel()
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
            throw TrimVideoTranscodeError.cannotStartReading(reader.error)
        default:
            break
        }

        try checkCancellation()
        try await Self.finishWriting(writer)
        try checkCancellation()
        setProgress(1)
    }

    /// Passes AAC tracks through without decoding to PCM and re-encoding;
    /// falls back to PCM -> AAC for non-AAC or multi-format audio tracks.
    private static func makeAudioPipe(
        for track: AVAssetTrack,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async -> (AVAssetReaderTrackOutput, AVAssetWriterInput) {
        let formatDescriptions = (try? await track.load(.formatDescriptions)) ?? []
        if formatDescriptions.count == 1,
           CMFormatDescriptionGetMediaSubType(formatDescriptions[0]) == kAudioFormatMPEG4AAC {
            let passthroughOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            passthroughOutput.alwaysCopiesSampleData = false
            let passthroughInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescriptions[0]
            )
            passthroughInput.expectsMediaDataInRealTime = false
            if reader.canAdd(passthroughOutput) && writer.canAdd(passthroughInput) {
                return (passthroughOutput, passthroughInput)
            }
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pcmSettings)
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
        input.expectsMediaDataInRealTime = false
        return (output, input)
    }

    private static var pcmSettings: [String: Any] {
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

    private static var aacSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func install(reader: AVAssetReader, writer: AVAssetWriter) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancelled else { return false }
        activeReader = reader
        activeWriter = writer
        return true
    }

    private func registerPump(_ pump: PipePumpState) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancelled else { return false }
        activePumps.append(pump)
        return true
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
    }

    private func clearActiveObjects(reader: AVAssetReader, writer: AVAssetWriter) {
        stateLock.lock()
        if activeReader === reader { activeReader = nil }
        if activeWriter === writer { activeWriter = nil }
        activePumps.removeAll()
        stateLock.unlock()
    }

    private func setProgress(_ value: Double) {
        stateLock.lock()
        _progress = value
        stateLock.unlock()
    }

    private func updateProgress(for sample: CMSampleBuffer, timeRange: CMTimeRange) {
        let totalSeconds = CMTimeGetSeconds(timeRange.duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { return }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, timeRange.start))
        guard elapsed.isFinite else { return }
        let fraction = min(max(elapsed / totalSeconds, 0), 0.98)
        stateLock.lock()
        if fraction > _progress {
            _progress = fraction
        }
        stateLock.unlock()
    }

    private func drain(_ pipe: TrackPipe, writer: WriterBox, timeRange: CMTimeRange) async throws {
        // Use event-driven readiness callbacks to avoid polling sleep latency.
        // Cancelling a writer stops its readiness callbacks, so `PipePumpState`
        // lets `cancel()` and sibling task cancellation resume the continuation
        // immediately without stranding the export.
        let pumpState = PipePumpState()
        guard registerPump(pumpState) else {
            throw CancellationError()
        }
        let queue = DispatchQueue(
            label: "com.replaycap.transcode.\(pipe.label)",
            qos: .userInitiated
        )
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard pumpState.attach(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if self.isCancelled {
                    pumpState.finish(returning: .failure(CancellationError()))
                    return
                }
                pipe.input.requestMediaDataWhenReady(on: queue) { [weak self] in
                    guard let self else {
                        pumpState.finish(returning: .failure(CancellationError()))
                        return
                    }
                    while !pumpState.isFinished && pipe.input.isReadyForMoreMediaData {
                        if self.isCancelled {
                            pumpState.finish(returning: .failure(CancellationError()))
                            return
                        }
                        switch writer.writer.status {
                        case .cancelled:
                            pumpState.finish(returning: .failure(CancellationError()))
                            return
                        case .failed:
                            pumpState.finish(
                                returning: .failure(TrimVideoTranscodeError.writeFailed(writer.writer.error))
                            )
                            return
                        case .writing:
                            break
                        default:
                            pumpState.finish(
                                returning: .failure(TrimVideoTranscodeError.cannotStartWriting(writer.writer.error))
                            )
                            return
                        }
                        guard let sample = pipe.output.copyNextSampleBuffer() else {
                            if self.isCancelled {
                                pumpState.finish(returning: .failure(CancellationError()))
                            } else {
                                pipe.input.markAsFinished()
                                pumpState.finish(returning: .success(()))
                            }
                            return
                        }
                        if pipe.isVideo {
                            self.updateProgress(for: sample, timeRange: timeRange)
                        }
                        guard pipe.input.append(sample) else {
                            if self.isCancelled || writer.writer.status == .cancelled {
                                pumpState.finish(returning: .failure(CancellationError()))
                            } else {
                                pumpState.finish(
                                    returning: .failure(
                                        TrimVideoTranscodeError.appendFailed(pipe.label, writer.writer.error)
                                    )
                                )
                            }
                            return
                        }
                    }
                }
            }
        } onCancel: {
            pumpState.finish(returning: .failure(CancellationError()))
        }
    }

    private static func finishWriting(_ writer: AVAssetWriter) async throws {
        let box = WriterBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.writer.finishWriting {
                if box.writer.status == .completed {
                    continuation.resume()
                } else if box.writer.status == .cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: TrimVideoTranscodeError.writeFailed(box.writer.error))
                }
            }
        }
    }

    private final class PipePumpState: @unchecked Sendable {
        // @unchecked: all state is accessed exclusively under `lock`.
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        func attach(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished {
                return false
            }
            self.continuation = continuation
            return true
        }

        func finish(returning result: Result<Void, Error>) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
    }

    private final class TrackPipe: @unchecked Sendable {
        // @unchecked: immutable, and each pipe is drained by one serial queue.
        let label: String
        let isVideo: Bool
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput

        init(label: String, isVideo: Bool, output: AVAssetReaderOutput, input: AVAssetWriterInput) {
            self.label = label
            self.isVideo = isVideo
            self.output = output
            self.input = input
        }
    }

    private final class WriterBox: @unchecked Sendable {
        // @unchecked: immutable; drain callbacks only read the writer's status, and it finishes after they end.
        let writer: AVAssetWriter
        init(_ writer: AVAssetWriter) { self.writer = writer }
    }
}
