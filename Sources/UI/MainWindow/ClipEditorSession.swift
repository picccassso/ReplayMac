import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import AVKit
import Save
import UniformTypeIdentifiers

import Combine

@MainActor
final class ClipEditorSession: ObservableObject {
    let url: URL
    let exports: ClipExportCoordinator
    var isVisible = false
    @Published var player: AVPlayer?
    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var gifWidth: GIFWidth = .medium
    @Published var errorMessage: String?
    @Published var audioTrackChoices: [AudioTrackChoice] = []
    @Published var selectedAudioTrackID = AudioTrackChoice.allTracksID
    @Published var cropEnabled = false
    @Published var cropRect = NormalizedVideoCrop.fullFrame.rect
    @Published var cropAspect: CropAspectPreset = .free
    @Published var videoDisplaySize = CGSize(width: 16, height: 9)
    @Published var exportResolution: TrimExportResolution = .source
    @Published var exportQuality: TrimExportQuality = .source
    @Published var sourceTotalBitrateMbps: Double = 0
    @Published var sourceAudioTrackCount = 0
    @Published var previewSourceStart: Double = 0
    @Published var previewBuildID = UUID()
    @Published var editingRange = false
    @Published var gifExpanded = false
    @Published var gifEstimate: Int64?
    @Published var gifEstimateFailed = false
    @Published var gifEstimateGeneration = GIFEstimateGeneration()
    @Published var isClosed = false

    var isBusy: Bool { exports.isBusy }
    var activeCrop: NormalizedVideoCrop? {
        guard cropEnabled else { return nil }
        let crop = NormalizedVideoCrop(cropRect)
        return crop.isFullFrame ? nil : crop
    }
    var exportInputSize: CGSize {
        guard let crop = activeCrop else { return videoDisplaySize }
        return VideoCropper.pixelRect(for: crop, displaySize: videoDisplaySize).size
    }
    var exportOutputSize: CGSize {
        exportResolution.outputSize(for: exportInputSize)
    }
    var exportedAudioTrackCount: Int {
        selectedAudioTrackID == AudioTrackChoice.allTracksID
            ? sourceAudioTrackCount
            : min(1, sourceAudioTrackCount)
    }
    var estimatedExportBytes: Int64 {
        TrimExportEstimate.bytes(
            durationSeconds: max(0, trimEnd - trimStart),
            quality: exportQuality,
            outputSize: exportOutputSize,
            audioTrackCount: exportedAudioTrackCount,
            sourceTotalBitrateMbps: sourceTotalBitrateMbps
        )
    }

    var isExporting: Bool { exports.isBusy && exports.title == "Exporting MP4" }
    var isExportingGIF: Bool { exports.isBusy && exports.title == "Exporting GIF" }
    private var loadTask: Task<Void, Never>?

    init(url: URL, exports: ClipExportCoordinator) {
        self.url = url
        self.exports = exports
        loadTask = Task { await loadClip() }
    }

    func pause() {
        isVisible = false
        previewBuildID = UUID()
        gifEstimateGeneration.invalidate()
        player?.pause()
    }

    func dispose() {
        pause()
        isClosed = true
        loadTask?.cancel()
        player = nil
    }

    func loadClip() async {
        let asset = AVURLAsset(url: url)
        let loadedDuration = (try? await asset.load(.duration)) ?? .zero
        let loadedSeconds = CMTimeGetSeconds(loadedDuration)
        let seconds = loadedSeconds.isFinite ? max(loadedSeconds, 0) : 0
        let choices = await ClipAudioTracks.choices(for: asset)
        let audioTrackCount = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).count
        let displaySize = (try? await VideoCropper.geometry(for: asset).displaySize)
            ?? CGSize(width: 16, height: 9)
        let sourceBitrateMbps: Double
        if seconds > 0,
           let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > 0 {
            sourceBitrateMbps = Double(fileSize) * 8 / seconds / 1_000_000
        } else {
            sourceBitrateMbps = 0
        }

        await MainActor.run {
            guard !isClosed else { return }
            duration = seconds
            trimStart = 0
            trimEnd = seconds
            audioTrackChoices = choices
            sourceAudioTrackCount = audioTrackCount
            sourceTotalBitrateMbps = sourceBitrateMbps
            videoDisplaySize = displaySize
            previewSourceStart = 0
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            ClipAudioTracks.apply(selection: selectedAudioTrackID, choices: choices, to: newPlayer.currentItem)
            player = newPlayer
            if isVisible { newPlayer.play() }
        }
    }

    var exportRequest: ClipExportRequest {
        ClipExportRequest(url: url, trimStart: trimStart, trimEnd: trimEnd,
            crop: activeCrop, soloChoice: audioTrackChoices.first { $0.id == selectedAudioTrackID },
            exportResolution: exportResolution, exportQuality: exportQuality,
            exportOutputSize: exportOutputSize, gifWidth: gifWidth.points)
    }

    func exportTrimmedClip() {
        guard !isBusy, !isClosed, duration > 0, trimEnd > trimStart else { return }
        let request = exportRequest
        player?.pause()
        previewBuildID = UUID()
        gifEstimateGeneration.invalidate()
        exports.start(source: url, title: "Exporting MP4") { [exports] in
            try await request.exportMP4(using: exports)
        }
    }

    func exportGIF() {
        guard !isBusy, !isClosed, duration > 0, trimEnd > trimStart else { return }
        let request = exportRequest
        player?.pause()
        previewBuildID = UUID()
        gifEstimateGeneration.invalidate()
        exports.start(source: url, title: "Exporting GIF") {
            try await request.exportGIF()
        }
    }

    func seek(to seconds: Double) {
        let previewSeconds = TrimPreviewPosition.seconds(
            sourceSeconds: seconds, previewSourceStart: previewSourceStart
        )
        player?.seek(to: CMTime(seconds: previewSeconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func rangeEditingChanged(_ editing: Bool) {
        guard !isBusy else { return }
        editingRange = editing
        if editing {
            previewBuildID = UUID()
            if let player {
                TrimPreviewAsset.restoreSource(to: player, url: url)
                previewSourceStart = 0
                ClipAudioTracks.apply(selection: selectedAudioTrackID,
                                      choices: audioTrackChoices, to: player.currentItem)
            }
        } else {
            playSelectedRange()
        }
    }

    /// Replaces the full source item with a zero-based composition of exactly
    /// the cyan range. This makes AVPlayerView's own duration and scrubber agree
    /// with the selected length instead of continuing to show the full clip.
    func playSelectedRange() {
        guard trimEnd > trimStart else { return }
        let selectedStart = trimStart
        let selectedEnd = trimEnd
        let buildID = UUID()
        previewBuildID = buildID

        Task {
            do {
                let previewAsset = try await TrimPreviewAsset.make(
                    from: AVURLAsset(url: url),
                    startSeconds: selectedStart,
                    endSeconds: selectedEnd
                )
                guard !isClosed, isVisible, !isBusy, previewBuildID == buildID, let player else { return }

                let item = AVPlayerItem(asset: previewAsset)
                player.pause()
                player.replaceCurrentItem(with: item)
                previewSourceStart = selectedStart
                ClipAudioTracks.apply(
                    selection: selectedAudioTrackID,
                    choices: audioTrackChoices,
                    to: item
                )
                errorMessage = nil
                player.play()
            } catch {
                guard !isClosed, isVisible, !isBusy, previewBuildID == buildID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func loopSelectedPreview() {
        guard isVisible, !isBusy else { return }
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }

    var gifEstimateLabel: String {
        if let gifEstimate {
            return "Estimated size: ~" + ByteCountFormatter.string(fromByteCount: gifEstimate, countStyle: .decimal)
        }
        return gifEstimateFailed ? "Estimate unavailable" : "Estimating…"
    }

    var estimateRequest: GIFEstimateRequest {
        GIFEstimateRequest(sourceURL: url, start: trimStart, end: trimEnd,
                           width: gifWidth.points, crop: activeCrop,
                           enabled: gifExpanded && !isBusy && !isClosed && isVisible && duration > 0)
    }

    func updateGIFEstimate() async {
        let request = estimateRequest
        let generation = gifEstimateGeneration.begin()
        gifEstimate = nil
        gifEstimateFailed = false
        guard request.enabled else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let bytes = try await GIFExporter.estimateBytes(
                sourceURL: request.sourceURL, startSeconds: request.start,
                endSeconds: request.end, maxWidth: request.width, crop: request.crop
            )
            guard !Task.isCancelled, !isClosed, estimateRequest == request,
                  gifEstimateGeneration.accepts(generation) else { return }
            gifEstimate = bytes
        } catch is CancellationError {
            // A changed range, collapsed section or closed window invalidates this request.
        } catch {
            guard !Task.isCancelled, !isClosed, estimateRequest == request,
                  gifEstimateGeneration.accepts(generation) else { return }
            gifEstimateFailed = true
        }
    }
}
