import AppKit
@preconcurrency import AVFoundation
import Save
import UniformTypeIdentifiers

/// Every value used by the asynchronous pipeline is captured before starting.
@MainActor
struct ClipExportRequest {
    let url: URL
    let trimStart: Double
    let trimEnd: Double
    let crop: NormalizedVideoCrop?
    let soloChoice: AudioTrackChoice?
    let exportResolution: TrimExportResolution
    let exportQuality: TrimExportQuality
    let exportOutputSize: CGSize
    let gifWidth: CGFloat

    func exportMP4(using coordinator: ClipExportCoordinator) async throws -> URL? {
        let asset = AVURLAsset(url: url)

        // A solo track selection carries over to the export: the other
        // audio tracks are dropped from the output file.
        let exportAsset: AVAsset
        if let soloChoice {
            exportAsset = try await ClipAudioTracks.soloComposition(from: asset, audioTrackID: soloChoice.id)
        } else {
            exportAsset = asset
        }

        var suffixParts = ["Trimmed"]
        if crop != nil {
            suffixParts.append("Cropped")
        }
        if let soloChoice {
            suffixParts.append(soloChoice.label.filter { !$0.isWhitespace })
        }
        if let resolutionLabel = exportResolution.filenameLabel {
            suffixParts.append(resolutionLabel)
        }
        if let qualityLabel = exportQuality.filenameLabel {
            suffixParts.append(qualityLabel)
        }
        let suffix = suffixParts.joined(separator: "_")
        let suggestedURL = try ClipMetadata.generateUniqueFileURL(
            in: url.deletingLastPathComponent(),
            suffix: suffix
        )
        guard let outputURL = await ExportDestinationPicker.chooseDestination(
            suggestedURL: suggestedURL,
            contentType: .mpeg4Movie,
            title: "Export Trimmed Clip"
        ) else {
            return nil
        }
        let start = CMTime(seconds: trimStart, preferredTimescale: 600)
        let end = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let range = CMTimeRangeFromTimeToTime(start: start, end: end)

        return try await ClipExportCoordinator.write(source: url, destination: outputURL) { stagedURL in
            let needsControlledTranscode = exportResolution != .source || exportQuality != .source
            if needsControlledTranscode {
                let outputSize = exportOutputSize
                let selectedQuality = exportQuality == .source ? TrimExportQuality.balanced : exportQuality
                guard let videoBitrateMbps = selectedQuality.videoBitrateMbps(for: outputSize) else {
                    throw TrimExportError.cannotCreateSession
                }
                let composition = try await VideoCropper.videoComposition(
                    for: exportAsset,
                    crop: crop ?? .fullFrame,
                    outputSize: outputSize
                )
                let exporter = TrimVideoTranscoder()
                coordinator.track(exporter)
                try await exporter.export(
                    asset: exportAsset,
                    timeRange: range,
                    videoComposition: composition,
                    outputSize: outputSize,
                    videoBitrateMbps: videoBitrateMbps,
                    to: stagedURL
                )
            } else {
                let preset: String
                if crop != nil {
                    preset = try await HDRVideoExport.transcodePreset(for: exportAsset)
                } else if await AVAssetExportSession.compatibility(
                    ofExportPreset: AVAssetExportPresetPassthrough,
                    with: exportAsset,
                    outputFileType: .mp4
                ) {
                    preset = AVAssetExportPresetPassthrough
                } else {
                    preset = try await HDRVideoExport.transcodePreset(for: exportAsset)
                }

                guard let exportSession = AVAssetExportSession(asset: exportAsset, presetName: preset) else {
                    throw TrimExportError.cannotCreateSession
                }

                exportSession.timeRange = range
                if let crop {
                    exportSession.videoComposition = try await VideoCropper.videoComposition(
                        for: exportAsset,
                        crop: crop
                    )
                }
                exportSession.shouldOptimizeForNetworkUse = true
                coordinator.track(exportSession)
                try await ExportWatchdog.runExport(exportSession, to: stagedURL, as: .mp4)
            }

        }
    }

    func exportGIF() async throws -> URL? {
        let suggestedURL = GIFExporter.uniqueOutputURL(basedOn: url)
        guard let outputURL = await ExportDestinationPicker.chooseDestination(
            suggestedURL: suggestedURL, contentType: .gif, title: "Export GIF"
        ) else { return nil }
        return try await ClipExportCoordinator.write(source: url, destination: outputURL) { stagedURL in
            try await GIFExporter.export(sourceURL: url, startSeconds: trimStart,
                endSeconds: trimEnd, maxWidth: gifWidth, crop: crop, to: stagedURL)
        }
    }
}
