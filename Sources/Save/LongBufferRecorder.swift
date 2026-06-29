import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os.log

public enum LongBufferRecorderError: LocalizedError, Equatable {
    case noSegments
    case longBufferExportAlreadyInProgress
    case segmentMissing
    case cannotAddInput
    case cannotCreateExportSession
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .noSegments:
            return "No long-buffer segments are available yet."
        case .longBufferExportAlreadyInProgress:
            return "A long replay is already saving."
        case .segmentMissing:
            return "A long-buffer segment disappeared before it could be saved."
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

struct LongBufferExportSegment: Sendable {
    let id: String
    let url: URL
    let startPTS: Double
    let endPTS: Double
}

public actor LongBufferRecorder {
    typealias WriterFinisher = @Sendable (LongBufferWriterBox) async throws -> Void
    typealias WriterBuilder = @Sendable (URL, LongBufferSample, Double) throws -> LongBufferWriterComponents
    typealias ClipExporter = @Sendable (
        [LongBufferExportSegment],
        TimeInterval,
        URL,
        Bool,
        String?
    ) async throws -> URL

    private struct Segment: Sendable {
        let id: String
        let url: URL
        let startPTS: Double
        var endPTS: Double
    }

    private struct StagedExport: Sendable {
        let directory: URL
        let segments: [LongBufferExportSegment]
    }

    private let segmentSeconds: Double = 60
    private var isEnabled = false
    private var maxDurationSeconds: Double = 300
    private var segmentDirectory: URL?
    private var segments: [Segment] = []
    private var latestVideoPTS: Double?
    private var isExportInProgress = false
    private var segmentPinOwners: [URL: Set<String>] = [:]
    private var pendingDeletionURLs: Set<URL> = []
    private var cleanedSegmentDirectories: Set<URL> = []

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
    private let writerFinisher: WriterFinisher
    private let writerBuilder: WriterBuilder
    private let clipExporter: ClipExporter
    private let logger = Logger(subsystem: "com.replaymac", category: "LongBuffer")

    public init() {
        writerFinisher = Self.finishWriter
        writerBuilder = Self.makeWriter
        clipExporter = Self.exportClip
    }

    init(
        writerFinisher: @escaping WriterFinisher,
        writerBuilder: @escaping WriterBuilder,
        clipExporter: @escaping ClipExporter = LongBufferRecorder.exportClip
    ) {
        self.writerFinisher = writerFinisher
        self.writerBuilder = writerBuilder
        self.clipExporter = clipExporter
    }

    public func configure(
        enabled: Bool,
        maxDurationSeconds: TimeInterval,
        outputDirectory: URL
    ) async {
        isEnabled = enabled
        self.maxDurationSeconds = maxDurationSeconds
        let requestedSegmentDirectory = outputDirectory
            .appendingPathComponent(".ReplayMacLongBuffer", isDirectory: true)
        segmentDirectory = requestedSegmentDirectory
        droppedVideoSamples = 0
        droppedSystemAudioSamples = 0
        droppedMicSamples = 0
        latestVideoPTS = nil

        cleanupOrphanedSegmentsIfNeeded(in: requestedSegmentDirectory)

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
        latestVideoPTS = max(latestVideoPTS ?? pts, pts)

        do {
            discardFailedActiveSegmentIfNeeded()

            if writer == nil {
                try startSegment(at: pts, videoSample: sample)
            } else if let activeSegmentStartPTS, pts - activeSegmentStartPTS >= segmentSeconds {
                try await finishCurrentSegment()
                try startSegment(at: pts, videoSample: sample)
            }

            if !append(sample, to: videoInput) {
                droppedVideoSamples += 1
                logDropIfNeeded(label: "video", count: droppedVideoSamples)
                discardFailedActiveSegmentIfNeeded()
            }
            if writer != nil {
                activeSegmentEndPTS = max(activeSegmentEndPTS ?? pts, pts)
            }
            pruneSegments(keepingNewestPTS: pts)
        } catch {
            logger.error(
                "Long-buffer video append failed error=\(error.localizedDescription, privacy: .public) writerStatus=\(self.writerStatusDescription, privacy: .public)"
            )
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
            let urls = Set(segments.map(\.url))
            segments.removeAll()
            for url in urls {
                requestSegmentDeletion(url, reason: "recorder stopped")
            }
            removeEmptySegmentDirectoryIfPossible()
        }
    }

    public func saveClip(
        lastSeconds: TimeInterval,
        outputDirectory: URL,
        mergeAudioTracks: Bool = true,
        baseName: String? = nil
    ) async throws -> URL {
        let exportID = UUID().uuidString
        guard !isExportInProgress else {
            logger.notice(
                "Rejected overlapping long-buffer export id=\(exportID, privacy: .public)"
            )
            throw LongBufferRecorderError.longBufferExportAlreadyInProgress
        }
        isExportInProgress = true
        defer { isExportInProgress = false }

        try await finishCurrentSegment()

        let newestPTS = segments.map(\.endPTS).max() ?? 0
        let cutoffPTS = newestPTS - lastSeconds
        let selectedSegments = segments
            .filter { $0.endPTS >= cutoffPTS }
            .sorted { $0.startPTS < $1.startPTS }
        guard !selectedSegments.isEmpty else {
            logger.error(
                "Long-buffer export has no segments id=\(exportID, privacy: .public) totalSegments=\(self.segments.count, privacy: .public)"
            )
            throw LongBufferRecorderError.noSegments
        }

        let selectedURLs = Set(selectedSegments.map(\.url))
        let existingCount = selectedURLs.reduce(into: 0) { count, url in
            if FileManager.default.fileExists(atPath: url.path) {
                count += 1
            }
        }
        logger.info(
            "Starting long-buffer export id=\(exportID, privacy: .public) totalSegments=\(self.segments.count, privacy: .public) selectedSegments=\(selectedSegments.count, privacy: .public) existingSegments=\(existingCount, privacy: .public) requestedSeconds=\(lastSeconds, privacy: .public)"
        )
        for (index, segment) in selectedSegments.enumerated() {
            let exists = FileManager.default.fileExists(atPath: segment.url.path)
            logger.debug(
                "Selected segment exportID=\(exportID, privacy: .public) segmentID=\(segment.id, privacy: .public) index=\(index, privacy: .public) path=\(segment.url.path, privacy: .public) exists=\(exists, privacy: .public) startPTS=\(segment.startPTS, privacy: .public) endPTS=\(segment.endPTS, privacy: .public)"
            )
        }
        guard existingCount == selectedSegments.count else {
            logger.error(
                "Long-buffer export selection contains missing files id=\(exportID, privacy: .public) selected=\(selectedSegments.count, privacy: .public) existing=\(existingCount, privacy: .public)"
            )
            throw LongBufferRecorderError.segmentMissing
        }

        pinSegments(selectedURLs, exportID: exportID)
        defer { releasePinnedSegments(selectedURLs, exportID: exportID) }

        var stagingDirectory: URL?
        var didStartExporter = false
        do {
            let staged = try await Self.stageSegments(
                selectedSegments,
                outputDirectory: outputDirectory,
                exportID: exportID
            )
            stagingDirectory = staged.directory
            logger.info(
                "Staged long-buffer export id=\(exportID, privacy: .public) copiedSegments=\(staged.segments.count, privacy: .public) directory=\(staged.directory.path, privacy: .public)"
            )
            for segment in staged.segments {
                let exists = FileManager.default.fileExists(atPath: segment.url.path)
                logger.debug(
                    "Composition input exportID=\(exportID, privacy: .public) segmentID=\(segment.id, privacy: .public) path=\(segment.url.path, privacy: .public) exists=\(exists, privacy: .public) startPTS=\(segment.startPTS, privacy: .public) endPTS=\(segment.endPTS, privacy: .public)"
                )
            }

            didStartExporter = true
            let outputURL = try await clipExporter(
                staged.segments,
                lastSeconds,
                outputDirectory,
                mergeAudioTracks,
                baseName
            )

            await cleanupStagingDirectory(staged.directory, exportID: exportID)
            logger.info(
                "Completed long-buffer export id=\(exportID, privacy: .public) output=\(outputURL.path, privacy: .public)"
            )
            return outputURL
        } catch {
            if let stagingDirectory {
                await cleanupStagingDirectory(stagingDirectory, exportID: exportID)
            }
            if didStartExporter {
                resetActiveWriterAfterExportFailure(exportID: exportID)
            }
            logger.error(
                "Long-buffer export failed id=\(exportID, privacy: .public) error=\(Self.describeError(error), privacy: .public) writerStatus=\(self.writerStatusDescription, privacy: .public)"
            )
            throw error
        }
    }

    private static func exportClip(
        segments: [LongBufferExportSegment],
        lastSeconds: TimeInterval,
        outputDirectory: URL,
        mergeAudioTracks: Bool,
        baseName: String?
    ) async throws -> URL {
        let newestPTS = segments.map(\.endPTS).max() ?? 0
        let cutoffPTS = newestPTS - lastSeconds
        let composition = AVMutableComposition()
        var compositionVideoTrack: AVMutableCompositionTrack?
        var compositionAudioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero

        for segment in segments {
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

    private static func stageSegments(
        _ segments: [Segment],
        outputDirectory: URL,
        exportID: String
    ) async throws -> StagedExport {
        let stagingRoot = outputDirectory
            .appendingPathComponent(".ReplayMacLongBufferExports", isDirectory: true)
        let stagingDirectory = stagingRoot.appendingPathComponent(exportID, isDirectory: true)

        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(
                    at: stagingDirectory,
                    withIntermediateDirectories: true
                )

                var stagedSegments: [LongBufferExportSegment] = []
                stagedSegments.reserveCapacity(segments.count)
                for (index, segment) in segments.enumerated() {
                    guard fileManager.fileExists(atPath: segment.url.path) else {
                        throw LongBufferRecorderError.segmentMissing
                    }
                    let destination = stagingDirectory.appendingPathComponent(
                        String(format: "%03d_%@", index, segment.url.lastPathComponent)
                    )
                    try fileManager.copyItem(at: segment.url, to: destination)
                    stagedSegments.append(
                        LongBufferExportSegment(
                            id: segment.id,
                            url: destination,
                            startPTS: segment.startPTS,
                            endPTS: segment.endPTS
                        )
                    )
                }
                return StagedExport(directory: stagingDirectory, segments: stagedSegments)
            } catch {
                try? fileManager.removeItem(at: stagingDirectory)
                if let remaining = try? fileManager.contentsOfDirectory(atPath: stagingRoot.path),
                   remaining.isEmpty {
                    try? fileManager.removeItem(at: stagingRoot)
                }
                throw error
            }
        }.value
    }

    private func cleanupStagingDirectory(_ directory: URL, exportID: String) async {
        let stagingRoot = directory.deletingLastPathComponent()
        do {
            try await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
                if let remaining = try? fileManager.contentsOfDirectory(atPath: stagingRoot.path),
                   remaining.isEmpty {
                    try? fileManager.removeItem(at: stagingRoot)
                }
            }.value
            logger.debug("Cleaned long-buffer staging directory id=\(exportID, privacy: .public)")
        } catch {
            logger.error(
                "Failed to clean long-buffer staging directory id=\(exportID, privacy: .public) error=\(Self.describeError(error), privacy: .public)"
            )
        }
    }

    private func startSegment(at pts: Double, videoSample: CMSampleBuffer) throws {
        guard let segmentDirectory else { return }
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)

        let fileName = "ReplayMac_LongBuffer_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString).mp4"
        let url = segmentDirectory.appendingPathComponent(fileName)
        var installedWriter = false
        defer {
            if !installedWriter {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let components = try writerBuilder(url, LongBufferSample(videoSample), pts)
        self.writer = components.writer
        self.videoInput = components.videoInput
        self.systemAudioInput = components.systemAudioInput
        self.micInput = components.micInput
        activeSegmentURL = url
        activeSegmentStartPTS = pts
        activeSegmentEndPTS = pts
        installedWriter = true
    }

    private static func makeWriter(
        outputURL: URL,
        videoSample: LongBufferSample,
        pts: Double
    ) throws -> LongBufferWriterComponents {
        let sample = videoSample.buffer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.metadata = ClipMetadata.makeMetadataItems()
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = true

        guard let formatDescription = sample.formatDescription else {
            throw LongBufferRecorderError.cannotAddInput
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
        let addedSystemAudioInput: AVAssetWriterInput?
        if writer.canAdd(systemAudioInput) {
            writer.add(systemAudioInput)
            addedSystemAudioInput = systemAudioInput
        } else {
            addedSystemAudioInput = nil
        }

        let micInput = Self.makeAudioInput()
        let addedMicInput: AVAssetWriterInput?
        if writer.canAdd(micInput) {
            writer.add(micInput)
            addedMicInput = micInput
        } else {
            addedMicInput = nil
        }

        guard writer.startWriting() else {
            throw writer.error ?? LongBufferRecorderError.exportFailed
        }
        writer.startSession(atSourceTime: CMTime(seconds: pts, preferredTimescale: 600))

        return LongBufferWriterComponents(
            writer: writer,
            videoInput: videoInput,
            systemAudioInput: addedSystemAudioInput,
            micInput: addedMicInput
        )
    }

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) -> Bool {
        guard isEnabled, sample.isValid else { return true }
        guard writer != nil else { return true }
        let appended = append(sample, to: input)
        let pts = presentationTimeStamp(sample)
        activeSegmentEndPTS = max(activeSegmentEndPTS ?? pts, pts)
        if !appended {
            discardFailedActiveSegmentIfNeeded()
        }
        return appended
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) -> Bool {
        guard let writer, writer.status == .writing, let input, input.isReadyForMoreMediaData else {
            return false
        }
        if !input.append(sample) {
            logger.error(
                "Long-buffer sample append failed writerStatus=\(Self.describe(writer.status), privacy: .public) error=\(writer.error?.localizedDescription ?? "none", privacy: .public)"
            )
            return false
        }
        return true
    }

    private func logDropIfNeeded(label: String, count: Int) {
        if count == 1 || count % 300 == 0 {
            logger.notice(
                "Long-buffer dropped samples media=\(label, privacy: .public) count=\(count, privacy: .public) writerStatus=\(self.writerStatusDescription, privacy: .public)"
            )
        }
    }

    private func finishCurrentSegment() async throws {
        guard let writer else {
            return
        }

        let segmentURL = activeSegmentURL
        let segmentStartPTS = activeSegmentStartPTS
        let segmentEndPTS = activeSegmentEndPTS
        let videoInput = self.videoInput
        let systemAudioInput = self.systemAudioInput
        let micInput = self.micInput
        let statusBeforeFinish = Self.describe(writer.status)

        logger.debug(
            "Finishing long-buffer segment file=\(segmentURL?.lastPathComponent ?? "unknown", privacy: .public) writerStatus=\(statusBeforeFinish, privacy: .public)"
        )

        // Detach the writer before awaiting finishWriting. Actor methods are
        // re-entrant at suspension points, so incoming samples must never see a
        // writer whose inputs have already been marked as finished. Detaching
        // here also guarantees that a finish failure cannot poison every later
        // segment and save attempt.
        clearActiveSegment()

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()

        do {
            try await writerFinisher(LongBufferWriterBox(writer))
        } catch {
            if let segmentURL {
                try? FileManager.default.removeItem(at: segmentURL)
            }
            logger.error(
                "Long-buffer segment finish failed path=\(segmentURL?.path ?? "unknown", privacy: .public) writerStatus=\(Self.describe(writer.status), privacy: .public) error=\(Self.describeError(error), privacy: .public)"
            )
            throw error
        }

        if let segmentURL, let segmentStartPTS {
            segments.append(
                Segment(
                    id: UUID().uuidString,
                    url: segmentURL,
                    startPTS: segmentStartPTS,
                    endPTS: segmentEndPTS ?? segmentStartPTS
                )
            )
            let exists = FileManager.default.fileExists(atPath: segmentURL.path)
            logger.info(
                "Finished long-buffer segment file=\(segmentURL.lastPathComponent, privacy: .public) writerStatus=\(Self.describe(writer.status), privacy: .public) exists=\(exists, privacy: .public) segmentCount=\(self.segments.count, privacy: .public)"
            )
        }
    }

    private func clearActiveSegment() {
        self.writer = nil
        videoInput = nil
        systemAudioInput = nil
        micInput = nil
        activeSegmentURL = nil
        activeSegmentStartPTS = nil
        activeSegmentEndPTS = nil
    }

    /// Drops a writer that AVFoundation has moved into a terminal failure
    /// state. The next video sample will immediately create a fresh segment.
    /// Backpressure (`isReadyForMoreMediaData == false`) is intentionally not
    /// treated as terminal and continues to use the current writer.
    @discardableResult
    private func discardFailedActiveSegmentIfNeeded() -> Bool {
        guard let writer, writer.status == .failed || writer.status == .cancelled else {
            return false
        }

        let failedURL = activeSegmentURL
        let errorDescription = writer.error?.localizedDescription ?? "writer cancelled"
        clearActiveSegment()
        if let failedURL {
            try? FileManager.default.removeItem(at: failedURL)
        }
        logger.error(
            "Long-buffer writer reset after terminal failure status=\(Self.describe(writer.status), privacy: .public) error=\(errorDescription, privacy: .public)"
        )
        return true
    }

    private func resetActiveWriterAfterExportFailure(exportID: String) {
        guard let writer else {
            logger.notice(
                "Long-buffer export recovery needs no active writer reset id=\(exportID, privacy: .public)"
            )
            return
        }

        let status = Self.describe(writer.status)
        let errorDescription = writer.error?.localizedDescription ?? "none"
        let partialURL = activeSegmentURL
        clearActiveSegment()
        if writer.status == .writing || writer.status == .unknown {
            writer.cancelWriting()
        }
        if let partialURL {
            requestSegmentDeletion(partialURL, reason: "export recovery")
        }
        logger.error(
            "Reset active long-buffer writer after export failure id=\(exportID, privacy: .public) previousStatus=\(status, privacy: .public) writerError=\(errorDescription, privacy: .public)"
        )
    }

    private static func finishWriter(_ writerBox: LongBufferWriterBox) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerBox.writer.finishWriting {
                if writerBox.writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: writerBox.writer.error ?? LongBufferRecorderError.exportFailed
                    )
                }
            }
        }
    }

    private func pruneSegments(keepingNewestPTS newestPTS: Double) {
        let cutoff = newestPTS - maxDurationSeconds
        let expired = segments.filter { $0.endPTS < cutoff }
        segments.removeAll { $0.endPTS < cutoff }
        for segment in expired {
            let owners = segmentPinOwners[segment.url, default: []].sorted().joined(separator: ",")
            logger.info(
                "Prune attempt segmentID=\(segment.id, privacy: .public) path=\(segment.url.path, privacy: .public) pinnedByExportIDs=\(owners, privacy: .public) cutoffPTS=\(cutoff, privacy: .public)"
            )
            requestSegmentDeletion(segment.url, reason: "buffer pruning")
        }
        if !expired.isEmpty {
            logger.info(
                "Pruned long-buffer segments expired=\(expired.count, privacy: .public) remaining=\(self.segments.count, privacy: .public) cutoffPTS=\(cutoff, privacy: .public)"
            )
        }
    }

    private func requestSegmentDeletion(_ url: URL, reason: String) {
        let pinOwners = segmentPinOwners[url, default: []]
        if !pinOwners.isEmpty {
            pendingDeletionURLs.insert(url)
            let ownerDescription = pinOwners.sorted().joined(separator: ",")
            logger.notice(
                "Deferred long-buffer segment deletion path=\(url.path, privacy: .public) reason=\(reason, privacy: .public) pinCount=\(pinOwners.count, privacy: .public) exportIDs=\(ownerDescription, privacy: .public)"
            )
            return
        }

        let existed = FileManager.default.fileExists(atPath: url.path)
        do {
            if existed {
                try FileManager.default.removeItem(at: url)
            }
            logger.debug(
                "Deleted long-buffer segment path=\(url.path, privacy: .public) reason=\(reason, privacy: .public) existed=\(existed, privacy: .public)"
            )
        } catch {
            logger.error(
                "Failed deleting long-buffer segment path=\(url.path, privacy: .public) reason=\(reason, privacy: .public) error=\(Self.describeError(error), privacy: .public)"
            )
        }
        removeEmptyDirectoryIfPossible(url.deletingLastPathComponent())
    }

    private func pinSegments(_ urls: Set<URL>, exportID: String) {
        for url in urls {
            segmentPinOwners[url, default: []].insert(exportID)
        }
        logger.debug(
            "Pinned long-buffer segments exportID=\(exportID, privacy: .public) count=\(urls.count, privacy: .public)"
        )
    }

    private func releasePinnedSegments(_ urls: Set<URL>, exportID: String) {
        for url in urls {
            segmentPinOwners[url]?.remove(exportID)
            if segmentPinOwners[url]?.isEmpty == true {
                segmentPinOwners[url] = nil
            }
        }
        logger.debug(
            "Released long-buffer segment pins exportID=\(exportID, privacy: .public) count=\(urls.count, privacy: .public)"
        )

        let readyForDeletion = pendingDeletionURLs.filter {
            segmentPinOwners[$0, default: []].isEmpty
        }
        pendingDeletionURLs.subtract(readyForDeletion)
        for url in readyForDeletion {
            requestSegmentDeletion(url, reason: "deferred cleanup after export")
        }

        if let latestVideoPTS {
            pruneSegments(keepingNewestPTS: latestVideoPTS)
        }
    }

    private func cleanupOrphanedSegmentsIfNeeded(in directory: URL) {
        guard cleanedSegmentDirectories.insert(directory).inserted else {
            return
        }

        let knownURLs = Set(segments.map(\.url))
            .union(activeSegmentURL.map { [$0] } ?? [])
            .union(segmentPinOwners.keys)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return
        }

        var removedCount = 0
        for url in files where isReplayMacSegmentFile(url) && !knownURLs.contains(url) {
            do {
                try FileManager.default.removeItem(at: url)
                removedCount += 1
                logger.notice(
                    "Removed orphaned long-buffer segment path=\(url.path, privacy: .public)"
                )
            } catch {
                logger.error(
                    "Failed removing orphaned long-buffer segment path=\(url.path, privacy: .public) error=\(Self.describeError(error), privacy: .public)"
                )
            }
        }
        logger.info(
            "Completed orphaned long-buffer cleanup directory=\(directory.path, privacy: .public) removed=\(removedCount, privacy: .public)"
        )
        removeEmptyDirectoryIfPossible(directory)
    }

    private func isReplayMacSegmentFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "mp4",
              url.lastPathComponent.hasPrefix("ReplayMac_LongBuffer_") else {
            return false
        }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func removeEmptySegmentDirectoryIfPossible() {
        guard let segmentDirectory else { return }
        removeEmptyDirectoryIfPossible(segmentDirectory)
    }

    private func removeEmptyDirectoryIfPossible(_ directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private var writerStatusDescription: String {
        writer.map { Self.describe($0.status) } ?? "none"
    }

    private static func describe(_ status: AVAssetWriter.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .writing: "writing"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        @unknown default: "unrecognized"
        }
    }

    private static func describeError(_ error: Error) -> String {
        var descriptions: [String] = []
        var current: NSError? = error as NSError
        var visited: Set<ObjectIdentifier> = []

        while let error = current, visited.insert(ObjectIdentifier(error)).inserted {
            descriptions.append(
                "\(error.domain)(\(error.code)): \(error.localizedDescription)"
            )
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return descriptions.joined(separator: " <- ")
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

final class LongBufferWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

final class LongBufferWriterComponents: @unchecked Sendable {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput?
    let systemAudioInput: AVAssetWriterInput?
    let micInput: AVAssetWriterInput?

    init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput?,
        systemAudioInput: AVAssetWriterInput?,
        micInput: AVAssetWriterInput?
    ) {
        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.micInput = micInput
    }
}
