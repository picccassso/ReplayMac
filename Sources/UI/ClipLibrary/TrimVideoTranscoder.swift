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
    private let stateLock = NSLock()
    private var activeReader: AVAssetReader?
    private var activeWriter: AVAssetWriter?
    private var cancelled = false

    func cancel() {
        stateLock.lock()
        cancelled = true
        let reader = activeReader
        let writer = activeWriter
        stateLock.unlock()
        if reader?.status == .reading { reader?.cancelReading() }
        if writer?.status == .writing { writer?.cancelWriting() }
    }

    func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        videoComposition: AVVideoComposition,
        outputSize: CGSize,
        videoBitrateMbps: Double,
        to outputURL: URL
    ) async throws {
        try checkCancellation()
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

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: isHDR
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
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
            AVVideoAllowFrameReorderingKey: true
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

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compressionProperties,
            AVVideoColorPropertiesKey: colorProperties
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw TrimVideoTranscodeError.cannotAddWriterInput("video")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw TrimVideoTranscodeError.cannotAddWriterInput("video")
        }
        writer.add(videoInput)

        var pipes = [TrackPipe(label: "video", output: videoOutput, input: videoInput)]
        for (index, track) in audioTracks.enumerated() {
            let label = "audio \(index + 1)"
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pcmSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw TrimVideoTranscodeError.cannotAddReaderOutput(label)
            }
            reader.add(output)

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw TrimVideoTranscodeError.cannotAddWriterInput(label)
            }
            writer.add(input)
            pipes.append(TrackPipe(label: label, output: output, input: input))
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
                            try await self.drain(pipe, writer: writerBox)
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

    private func install(reader: AVAssetReader, writer: AVAssetWriter) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancelled else { return false }
        activeReader = reader
        activeWriter = writer
        return true
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        stateLock.lock()
        let stopped = cancelled
        stateLock.unlock()
        if stopped { throw CancellationError() }
    }

    private func clearActiveObjects(reader: AVAssetReader, writer: AVAssetWriter) {
        stateLock.lock()
        if activeReader === reader { activeReader = nil }
        if activeWriter === writer { activeWriter = nil }
        stateLock.unlock()
    }

    private func drain(_ pipe: TrackPipe, writer: WriterBox) async throws {
        // Cancelling a writer stops its readiness callbacks. Awaiting a callback
        // continuation can therefore strand the export indefinitely. Cooperatively
        // drain ready batches, yielding briefly under backpressure and checking both
        // cancellation and writer failure even when the input is not ready.
        while true {
            try checkCancellation()
            switch writer.writer.status {
            case .cancelled:
                throw CancellationError()
            case .failed:
                throw TrimVideoTranscodeError.writeFailed(writer.writer.error)
            case .writing:
                break
            default:
                throw TrimVideoTranscodeError.cannotStartWriting(writer.writer.error)
            }
            guard pipe.input.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            guard let sample = pipe.output.copyNextSampleBuffer() else {
                try checkCancellation()
                pipe.input.markAsFinished()
                return
            }
            guard pipe.input.append(sample) else {
                try checkCancellation()
                if writer.writer.status == .cancelled { throw CancellationError() }
                throw TrimVideoTranscodeError.appendFailed(pipe.label, writer.writer.error)
            }
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

    private final class WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter
        init(_ writer: AVAssetWriter) { self.writer = writer }
    }

}
