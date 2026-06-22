import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia

public enum LongBufferRecorderError: LocalizedError {
    case noSegments
    case cannotAddInput
    case cannotCreateExportSession
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .noSegments:
            return "No long-buffer segments are available yet."
        case .cannotAddInput:
            return "Unable to add a track to the long-buffer writer."
        case .cannotCreateExportSession:
            return "Unable to create the long-buffer export session."
        case .exportFailed:
            return "Long-buffer export did not complete."
        }
    }
}

public struct LongBufferSample: @unchecked Sendable {
    public let buffer: CMSampleBuffer

    public init(_ buffer: CMSampleBuffer) {
        self.buffer = buffer
    }
}

public actor LongBufferRecorder {
    private struct Segment: Sendable {
        let url: URL
        let startPTS: Double
        var endPTS: Double
    }

    private let segmentSeconds: Double = 60
    private var isEnabled = false
    private var maxDurationSeconds: Double = 300
    private var segmentDirectory: URL?
    private var segments: [Segment] = []

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var activeSegmentURL: URL?
    private var activeSegmentStartPTS: Double?
    private var activeSegmentEndPTS: Double?
    private var droppedVideoSamples = 0
    private var droppedSystemAudioSamples = 0
    private var droppedMicSamples = 0

    public init() {}

    public func configure(
        enabled: Bool,
        maxDurationSeconds: TimeInterval,
        outputDirectory: URL
    ) async {
        isEnabled = enabled
        self.maxDurationSeconds = maxDurationSeconds
        segmentDirectory = outputDirectory
            .appendingPathComponent(".ReplayMacLongBuffer", isDirectory: true)
        droppedVideoSamples = 0
        droppedSystemAudioSamples = 0
        droppedMicSamples = 0

        if !enabled {
            await stop(deleteSegments: true)
            return
        }

        if let segmentDirectory {
            try? FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        }
    }

    public func appendVideo(_ sample: LongBufferSample) async {
        let sample = sample.buffer
        guard isEnabled, sample.isValid else { return }
        let pts = presentationTimeStamp(sample)

        do {
            if writer == nil {
                try startSegment(at: pts, videoSample: sample)
            } else if let activeSegmentStartPTS, pts - activeSegmentStartPTS >= segmentSeconds {
                try await finishCurrentSegment()
                try startSegment(at: pts, videoSample: sample)
            }

            if !append(sample, to: videoInput) {
                droppedVideoSamples += 1
                logDropIfNeeded(label: "video", count: droppedVideoSamples)
            }
            activeSegmentEndPTS = max(activeSegmentEndPTS ?? pts, pts)
            pruneSegments(keepingNewestPTS: pts)
        } catch {
            print("Long buffer video append failed: \(error)")
        }
    }

    public func appendSystemAudio(_ sample: LongBufferSample) async {
        let sample = sample.buffer
        if !appendAudio(sample, to: systemAudioInput) {
            droppedSystemAudioSamples += 1
            logDropIfNeeded(label: "system audio", count: droppedSystemAudioSamples)
        }
    }

    public func appendMicrophone(_ sample: LongBufferSample) async {
        let sample = sample.buffer
        if !appendAudio(sample, to: micInput) {
            droppedMicSamples += 1
            logDropIfNeeded(label: "microphone", count: droppedMicSamples)
        }
    }

    public func stop(deleteSegments: Bool = false) async {
        try? await finishCurrentSegment()
        if deleteSegments {
            if let segmentDirectory {
                try? FileManager.default.removeItem(at: segmentDirectory)
            }
            segments.removeAll()
        }
    }

    public func saveClip(
        lastSeconds: TimeInterval,
        outputDirectory: URL,
        mergeAudioTracks: Bool = true,
        baseName: String? = nil
    ) async throws -> URL {
        try await finishCurrentSegment()

        let newestPTS = segments.map(\.endPTS).max() ?? 0
        let cutoffPTS = newestPTS - lastSeconds
        let selectedSegments = segments.filter { $0.endPTS >= cutoffPTS }
        guard !selectedSegments.isEmpty else {
            throw LongBufferRecorderError.noSegments
        }

        let composition = AVMutableComposition()
        var compositionVideoTrack: AVMutableCompositionTrack?
        var compositionAudioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero

        for segment in selectedSegments {
            let asset = AVURLAsset(url: segment.url)
            let duration = try await asset.load(.duration)
            let localStartSeconds = max(0, cutoffPTS - segment.startPTS)
            let localStart = CMTime(seconds: localStartSeconds, preferredTimescale: 600)
            let localDuration = CMTimeSubtract(duration, localStart)
            guard localDuration.seconds > 0 else {
                continue
            }
            let range = CMTimeRange(start: localStart, duration: localDuration)

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = videoTracks.first {
                if compositionVideoTrack == nil {
                    compositionVideoTrack = composition.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                try compositionVideoTrack?.insertTimeRange(range, of: videoTrack, at: cursor)
            }

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            for (index, audioTrack) in audioTracks.enumerated() {
                while compositionAudioTracks.count <= index {
                    if let track = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) {
                        compositionAudioTracks.append(track)
                    }
                }
                try compositionAudioTracks[index].insertTimeRange(range, of: audioTrack, at: cursor)
            }

            cursor = CMTimeAdd(cursor, localDuration)
        }

        let outputURL = try ClipMetadata.generateUniqueFileURL(in: outputDirectory, baseName: baseName, suffix: "LongBuffer")
        let preset: String
        if mergeAudioTracks, compositionAudioTracks.count > 1 {
            preset = AVAssetExportPresetHighestQuality
        } else {
            preset = await AVAssetExportSession.compatibility(
                ofExportPreset: AVAssetExportPresetPassthrough,
                with: composition,
                outputFileType: .mp4
            ) ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw LongBufferRecorderError.cannotCreateExportSession
        }
        if mergeAudioTracks, compositionAudioTracks.count > 1 {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = compositionAudioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(1, at: .zero)
                return parameters
            }
            exportSession.audioMix = audioMix
        }
        exportSession.shouldOptimizeForNetworkUse = true
        try await exportSession.export(to: outputURL, as: .mp4)

        return outputURL
    }

    private func startSegment(at pts: Double, videoSample: CMSampleBuffer) throws {
        guard let segmentDirectory else { return }
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)

        let fileName = "ReplayMac_LongBuffer_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString).mp4"
        let url = segmentDirectory.appendingPathComponent(fileName)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.metadata = ClipMetadata.makeMetadataItems()
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = true

        guard let formatDescription = videoSample.formatDescription else {
            return
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw LongBufferRecorderError.cannotAddInput
        }
        writer.add(videoInput)

        let systemAudioInput = Self.makeAudioInput()
        if writer.canAdd(systemAudioInput) {
            writer.add(systemAudioInput)
            self.systemAudioInput = systemAudioInput
        }

        let micInput = Self.makeAudioInput()
        if writer.canAdd(micInput) {
            writer.add(micInput)
            self.micInput = micInput
        }

        guard writer.startWriting() else {
            throw writer.error ?? LongBufferRecorderError.exportFailed
        }
        writer.startSession(atSourceTime: CMTime(seconds: pts, preferredTimescale: 600))

        self.writer = writer
        self.videoInput = videoInput
        activeSegmentURL = url
        activeSegmentStartPTS = pts
        activeSegmentEndPTS = pts
    }

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) -> Bool {
        guard isEnabled, sample.isValid else { return true }
        guard writer != nil else { return true }
        let appended = append(sample, to: input)
        let pts = presentationTimeStamp(sample)
        activeSegmentEndPTS = max(activeSegmentEndPTS ?? pts, pts)
        return appended
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) -> Bool {
        guard let writer, writer.status == .writing, let input, input.isReadyForMoreMediaData else {
            return false
        }
        if !input.append(sample) {
            print("Long buffer append failed: \(String(describing: writer.error))")
            return false
        }
        return true
    }

    private func logDropIfNeeded(label: String, count: Int) {
        if count == 1 || count % 300 == 0 {
            print("Long buffer dropped \(label) samples: \(count)")
        }
    }

    private func finishCurrentSegment() async throws {
        guard let writer else {
            return
        }

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()

        let writerBox = LongBufferWriterBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerBox.writer.finishWriting {
                if let error = writerBox.writer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        if let activeSegmentURL, let activeSegmentStartPTS {
            segments.append(
                Segment(
                    url: activeSegmentURL,
                    startPTS: activeSegmentStartPTS,
                    endPTS: activeSegmentEndPTS ?? activeSegmentStartPTS
                )
            )
        }

        self.writer = nil
        videoInput = nil
        systemAudioInput = nil
        micInput = nil
        activeSegmentURL = nil
        activeSegmentStartPTS = nil
        activeSegmentEndPTS = nil
    }

    private func pruneSegments(keepingNewestPTS newestPTS: Double) {
        let cutoff = newestPTS - maxDurationSeconds
        let expired = segments.filter { $0.endPTS < cutoff }
        segments.removeAll { $0.endPTS < cutoff }
        for segment in expired {
            try? FileManager.default.removeItem(at: segment.url)
        }
    }

    private func presentationTimeStamp(_ sample: CMSampleBuffer) -> Double {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        return pts.isValid ? pts.seconds : 0
    }

    private static func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }
}

private final class LongBufferWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}
