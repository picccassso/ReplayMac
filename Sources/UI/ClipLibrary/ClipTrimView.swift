import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import AVKit
import Save
import UniformTypeIdentifiers

struct ClipTrimView: View {
    let url: URL
    let onExport: () -> Void

    let onClose: () -> Void
    @ObservedObject var activity: TrimEditorActivity
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    private var isExporting: Bool {
        get { activity.isExporting }
        nonmutating set { activity.isExporting = newValue }
    }
    private var isExportingGIF: Bool {
        get { activity.isExportingGIF }
        nonmutating set { activity.isExportingGIF = newValue }
    }
    @State private var gifWidth: GIFWidth = .medium
    @State private var errorMessage: String?
    @State private var audioTrackChoices: [AudioTrackChoice] = []
    @State private var selectedAudioTrackID = AudioTrackChoice.allTracksID
    @State private var cropEnabled = false
    @State private var cropRect = NormalizedVideoCrop.fullFrame.rect
    @State private var cropAspect: CropAspectPreset = .free
    @State private var videoDisplaySize = CGSize(width: 16, height: 9)
    @State private var activeExportSession: AVAssetExportSession?
    @State private var activeCustomExporter: TrimVideoTranscoder?
    @State private var exportResolution: TrimExportResolution = .source
    @State private var exportQuality: TrimExportQuality = .source
    @State private var sourceTotalBitrateMbps: Double = 0
    @State private var sourceAudioTrackCount = 0
    @State private var previewSourceStart: Double = 0
    @State private var previewBuildID = UUID()
    @State private var editingRange = false
    @State private var gifExpanded = false
    @State private var gifEstimate: Int64?
    @State private var gifEstimateFailed = false
    @State private var gifEstimateGeneration = GIFEstimateGeneration()
    @State private var isClosed = false

    private var isBusy: Bool { isExporting || isExportingGIF }
    private var activeCrop: NormalizedVideoCrop? {
        guard cropEnabled else { return nil }
        let crop = NormalizedVideoCrop(cropRect)
        return crop.isFullFrame ? nil : crop
    }
    private var exportInputSize: CGSize {
        guard let crop = activeCrop else { return videoDisplaySize }
        return VideoCropper.pixelRect(for: crop, displaySize: videoDisplaySize).size
    }
    private var exportOutputSize: CGSize {
        exportResolution.outputSize(for: exportInputSize)
    }
    private var exportedAudioTrackCount: Int {
        selectedAudioTrackID == AudioTrackChoice.allTracksID
            ? sourceAudioTrackCount
            : min(1, sourceAudioTrackCount)
    }
    private var estimatedExportBytes: Int64 {
        TrimExportEstimate.bytes(
            durationSeconds: max(0, trimEnd - trimStart),
            quality: exportQuality,
            outputSize: exportOutputSize,
            audioTrackCount: exportedAudioTrackCount,
            sourceTotalBitrateMbps: sourceTotalBitrateMbps
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            workspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            sidebar
                .frame(width: 300)
                .background(AppTheme.backgroundSecondary)
        }
        .background(AppTheme.backgroundPrimary)
        .tint(AppTheme.accent)
        .task {
            await loadClip()
        }
        .onChange(of: selectedAudioTrackID) { _, newValue in
            ClipAudioTracks.apply(selection: newValue, choices: audioTrackChoices, to: player?.currentItem)
        }
        .onChange(of: cropAspect) { _, newValue in
            guard newValue != .free else { return }
            cropRect = newValue.cropRect(for: videoDisplaySize)
        }
        .onChange(of: exportResolution) { _, newValue in
            if newValue != .source && exportQuality == .source {
                exportQuality = .balanced
            }
        }
        .onChange(of: exportQuality) { _, newValue in
            if newValue == .source && exportResolution != .source {
                exportResolution = .source
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let endedItem = notification.object as? AVPlayerItem,
                  endedItem === player?.currentItem else {
                return
            }
            if !editingRange { loopSelectedPreview() }
        }
        .task(id: estimateRequest) {
            await updateGIFEstimate()
        }
        .onChange(of: isBusy) { _, busy in
            if busy { gifEstimateGeneration.invalidate() }
        }
        .onDisappear {
            isClosed = true
            gifEstimateGeneration.invalidate()
            previewBuildID = UUID()
            player?.pause()
            player = nil
        }
    }

    private func loadClip() async {
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
            newPlayer.play()
        }
    }

    private func exportTrimmedClip() async {
        guard !isBusy, !isClosed, trimEnd > trimStart else { return }
        isExporting = true
        errorMessage = nil
        previewBuildID = UUID()
        // Stop the preview so the export isn't decoding the same file as the
        // player, and so playback isn't left running under the save panel.
        player?.pause()
        defer { isExporting = false }

        do {
            let asset = AVURLAsset(url: url)
            let crop = activeCrop

            // A solo track selection carries over to the export: the other
            // audio tracks are dropped from the output file.
            let soloChoice = audioTrackChoices.first { $0.id == selectedAudioTrackID }
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
                return
            }
            let start = CMTime(seconds: trimStart, preferredTimescale: 600)
            let end = CMTime(seconds: trimEnd, preferredTimescale: 600)
            let range = CMTimeRangeFromTimeToTime(start: start, end: end)

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
                activeCustomExporter = exporter
                defer { activeCustomExporter = nil }
                try await exporter.export(
                    asset: exportAsset,
                    timeRange: range,
                    videoComposition: composition,
                    outputSize: outputSize,
                    videoBitrateMbps: videoBitrateMbps,
                    to: outputURL
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
                activeExportSession = exportSession
                defer { activeExportSession = nil }
                try await ExportWatchdog.runExport(exportSession, to: outputURL, as: .mp4)
            }

            onExport()
            onClose()
        } catch is CancellationError {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

    }

    private func exportGIF() async {
        guard !isBusy, !isClosed, trimEnd > trimStart else { return }
        isExportingGIF = true
        errorMessage = nil
        previewBuildID = UUID()
        player?.pause()
        defer { isExportingGIF = false }

        do {
            let crop = activeCrop
            let suggestedURL = GIFExporter.uniqueOutputURL(basedOn: url)
            guard let outputURL = await ExportDestinationPicker.chooseDestination(
                suggestedURL: suggestedURL,
                contentType: .gif,
                title: "Export GIF"
            ) else {
                return
            }
            try await GIFExporter.export(
                sourceURL: url,
                startSeconds: trimStart,
                endSeconds: trimEnd,
                maxWidth: gifWidth.points,
                crop: crop,
                to: outputURL
            )

            // GIFs aren't shown in the library (it lists MP4s only), so reveal
            // the exported file in Finder instead of reloading the list.
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }

    }

    private func seek(to seconds: Double) {
        let previewSeconds = TrimPreviewPosition.seconds(
            sourceSeconds: seconds, previewSourceStart: previewSourceStart
        )
        player?.seek(to: CMTime(seconds: previewSeconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func rangeEditingChanged(_ editing: Bool) {
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
    private func playSelectedRange() {
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
                guard !isClosed, !isBusy, previewBuildID == buildID, let player else { return }

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
                guard !isClosed, !isBusy, previewBuildID == buildID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loopSelectedPreview() {
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }

    private var workspace: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Label("Trim and Export", systemImage: "film")
                    .font(.system(size: 14, weight: .semibold))
                TrimHelpButton(text: "Crop the picture, select a time range, then choose your export settings. Save exports an MP4; Export GIF creates a looping image without audio.")
                Spacer(minLength: 16)
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.lastPathComponent)
            }
            cropControls
            GeometryReader { proxy in
                ZStack {
                    Color.black
                    if let player {
                        TrimPlayerView(player: player, cropEnabled: cropEnabled,
                                       cropRect: $cropRect, videoSize: videoDisplaySize,
                                       isBusy: isBusy, onManualChange: { cropAspect = .free })
                    } else {
                        ProgressView("Loading clip…")
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium))
            }
            TrimRangeSelector(start: $trimStart, end: $trimEnd,
                              bounds: 0...max(duration, 0.1),
                              onSeek: seek, onEditingChanged: rangeEditingChanged,
                              editableTimes: true)
                .padding(12)
                .background(AppTheme.backgroundSecondary,
                            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium))
                .disabled(isBusy || duration <= 0)
        }
        .padding(16)
    }

    private var cropControls: some View {
        HStack(spacing: 8) {
            Toggle("Crop", isOn: $cropEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
            TrimHelpButton(text: "Crop both MP4 and GIF exports to the selected area. Drag the centre to move it and the edges to resize it. Turning Crop off retains your selection.")
            if cropEnabled {
                Text("\(Int((cropRect.width * 100).rounded()))% × \(Int((cropRect.height * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker("Crop aspect ratio", selection: $cropAspect) {
                    ForEach(CropAspectPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Button("Reset", systemImage: "arrow.counterclockwise") {
                    cropAspect = .free
                    cropRect = NormalizedVideoCrop.fullFrame.rect
                }
                .controlSize(.small)
                .fixedSize()
                .help("Reset the crop to the full picture")
            } else {
                Spacer()
            }
        }
        .font(.system(size: 12))
        .disabled(isBusy || duration <= 0)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeading("Resolution", icon: "rectangle.arrowtriangle.2.outward",
                                       detail: "\(Int(exportOutputSize.width)) × \(Int(exportOutputSize.height))",
                                       help: "Fit the video or crop within the selected resolution, preserving its aspect ratio. Smaller videos are never upscaled. Original retains the crop’s original dimensions.")
                        Picker("Export resolution", selection: $exportResolution) {
                            ForEach(TrimExportResolution.allCases) { resolution in
                                Text(resolution.title).tag(resolution)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeading("Quality", icon: "slider.horizontal.3", detail: bitrateLabel,
                                       help: "Source uses fast passthrough when possible. Cropping may require re-encoding. Compact, Balanced, and High export HEVC with increasing target bitrates. Choosing a smaller resolution selects Balanced when Source was selected.")
                        Picker("Export quality", selection: $exportQuality) {
                            ForEach(TrimExportQuality.allCases) { quality in
                                Text(quality.title).tag(quality)
                                    .disabled(quality == .source && exportResolution != .source)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if !audioTrackChoices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeading("Audio", icon: "speaker.wave.2",
                                           help: "Choose the tracks you hear in the preview and keep in the MP4. All Tracks retains every track. GIFs have no audio.")
                            Picker("Audio track", selection: $selectedAudioTrackID) {
                                Text("All Tracks").tag(AudioTrackChoice.allTracksID)
                                ForEach(audioTrackChoices) { choice in
                                    Text(choice.label).tag(choice.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Divider()
                    gifControls
                }
                .padding(16)
                .disabled(isBusy || duration <= 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                estimateSummary
                Divider()
                HStack {
                    if isExporting && (activeExportSession != nil || activeCustomExporter != nil) {
                        Button("Cancel Export") {
                            activeExportSession?.cancelExport()
                            activeCustomExporter?.cancel()
                        }
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    Button("Cancel", action: onClose)
                        .disabled(isBusy)
                        .keyboardShortcut("w", modifiers: .command)
                    Button {
                        Task { await exportTrimmedClip() }
                    } label: {
                        if isExporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(isBusy || duration <= 0 || trimEnd <= trimStart)
                    .keyboardShortcut(.defaultAction)
                    .help("Save the selected range as an MP4")
                }
            }
            .padding(16)
        }
        .tint(AppTheme.accent)
    }

    private var bitrateLabel: String? {
        exportQuality.videoBitrateMbps(for: exportOutputSize)
            .map { "HEVC | \(String(format: "%.3g", $0)) Mbps" }
    }

    private func sectionHeading(_ title: String, icon: String, detail: String? = nil,
                                help: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(AppTheme.accent)
            Text(title).fontWeight(.medium)
            if let detail {
                Text(detail).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            TrimHelpButton(text: help)
        }
        .font(.system(size: 11))
    }

    private var estimateSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading("Estimated size", icon: "externaldrive",
                           help: "This approximate MP4 size includes retained audio and container headroom. Source uses the original file’s average bitrate and may differ after cropping or selecting audio. The 100 MB marker is a reference, not a guaranteed upload limit.")
            if estimatedExportBytes > 0 {
                let fits = estimatedExportBytes <= TrimExportEstimate.discordLimitBytes
                Label(fits ? "At or below 100 MB" : "Over 100 MB",
                      systemImage: fits ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(fits ? Color.green : Color.orange)
                Text("~" + ByteCountFormatter.string(fromByteCount: estimatedExportBytes, countStyle: .decimal))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(fits ? AppTheme.accent : .orange)
            } else {
                Text("Estimate unavailable").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var gifControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    gifExpanded.toggle()
                } label: {
                    HStack {
                        Label("Export a GIF", systemImage: "photo.stack")
                        Spacer()
                        Image(systemName: gifExpanded ? "chevron.up" : "chevron.down")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Export a GIF")
                .accessibilityValue(gifExpanded ? "Expanded" : "Collapsed")
                TrimHelpButton(text: "Export the selected range and crop as a looping GIF without audio. GIF size is independent of MP4 resolution and quality. The approximate estimate samples image content; the final file size can differ.")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(gifExpanded ? AppTheme.textPrimary : AppTheme.textSecondary)
            if gifExpanded {
                Picker("GIF size", selection: $gifWidth) {
                    ForEach(GIFWidth.allCases) { width in Text(width.title).tag(width) }
                }
                .labelsHidden()
                Text(gifEstimateLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(gifEstimateLabel)
                Button {
                    Task { await exportGIF() }
                } label: {
                    HStack {
                        Spacer()
                        if isExportingGIF {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Export GIF", systemImage: "photo.stack")
                        }
                        Spacer()
                    }
                }
                .disabled(isBusy || trimEnd <= trimStart)
            }
        }
    }

    private var gifEstimateLabel: String {
        if let gifEstimate {
            return "Estimated size: ~" + ByteCountFormatter.string(fromByteCount: gifEstimate, countStyle: .decimal)
        }
        return gifEstimateFailed ? "Estimate unavailable" : "Estimating…"
    }

    private var estimateRequest: GIFEstimateRequest {
        GIFEstimateRequest(sourceURL: url, start: trimStart, end: trimEnd,
                           width: gifWidth.points, crop: activeCrop,
                           enabled: gifExpanded && !isBusy && !isClosed && duration > 0)
    }

    private func updateGIFEstimate() async {
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

struct TrimHelpButton: View {
    let text: String
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("Help")
        .accessibilityHint(text)
        .popover(isPresented: $presented) {
            Text(text).font(.system(size: 12)).padding(14).frame(width: 280)
        }
    }
}
