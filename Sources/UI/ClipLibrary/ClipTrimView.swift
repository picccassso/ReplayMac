import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import AVKit
import Save
import UniformTypeIdentifiers

struct ClipTrimView: View {
    @ObservedObject var session: ClipEditorSession
    @ObservedObject var exports: ClipExportCoordinator
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            workspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            sidebar
                .frame(width: 300)
                .background(AppTheme.backgroundSecondary)
        }
        .tint(AppTheme.accent)
        .onAppear { session.isVisible = true }
        .onChange(of: session.selectedAudioTrackID) { _, newValue in
            ClipAudioTracks.apply(selection: newValue, choices: session.audioTrackChoices, to: session.player?.currentItem)
        }
        .onChange(of: session.cropAspect) { _, newValue in
            guard newValue != .free else { return }
            session.cropRect = newValue.cropRect(for: session.videoDisplaySize)
        }
        .onChange(of: session.exportResolution) { _, newValue in
            if newValue != .source && session.exportQuality == .source {
                session.exportQuality = .balanced
            }
        }
        .onChange(of: session.exportQuality) { _, newValue in
            if newValue == .source && session.exportResolution != .source {
                session.exportResolution = .source
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let endedItem = notification.object as? AVPlayerItem,
                  endedItem === session.player?.currentItem else {
                return
            }
            if !session.editingRange { session.loopSelectedPreview() }
        }
        .task(id: session.estimateRequest) {
            await session.updateGIFEstimate()
        }
        .onChange(of: session.isBusy) { _, busy in
            if busy { session.gifEstimateGeneration.invalidate() }
        }
        .onDisappear { session.pause() }
    }

    private var workspace: some View {
        // The window title and subtitle already name the editor and clip.
        VStack(spacing: 12) {
            cropControls
            GeometryReader { proxy in
                ZStack {
                    Color.black
                    if let player = session.player {
                        TrimPlayerView(player: player, cropEnabled: session.cropEnabled,
                                       cropRect: $session.cropRect, videoSize: session.videoDisplaySize,
                                       isBusy: session.isBusy, onManualChange: { session.cropAspect = .free })
                    } else {
                        ProgressView("Loading clip…")
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium))
            }
            TrimRangeSelector(start: $session.trimStart, end: $session.trimEnd,
                              bounds: 0...max(session.duration, 0.1),
                              onSeek: session.seek, onEditingChanged: session.rangeEditingChanged,
                              editableTimes: true)
                .padding(12)
                .background(AppTheme.backgroundSecondary,
                            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium))
                .disabled(session.isBusy || session.duration <= 0)
        }
        .padding(16)
    }

    private var cropControls: some View {
        HStack(spacing: 8) {
            Toggle("Crop", isOn: $session.cropEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
            TrimHelpButton(text: "Crop both MP4 and GIF exports to the selected area. Drag the centre to move it and the edges to resize it. Turning Crop off retains your selection.")
            if session.cropEnabled {
                Text("\(Int((session.cropRect.width * 100).rounded()))% × \(Int((session.cropRect.height * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker("Crop aspect ratio", selection: $session.cropAspect) {
                    ForEach(CropAspectPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Button("Reset", systemImage: "arrow.counterclockwise") {
                    session.cropAspect = .free
                    session.cropRect = NormalizedVideoCrop.fullFrame.rect
                }
                .controlSize(.small)
                .fixedSize()
                .help("Reset the crop to the full picture")
            } else {
                Spacer()
            }
            TrimHelpButton(text: "Crop the picture, select a time range, then choose your export settings. Save exports an MP4; Export GIF creates a looping image without audio.")
        }
        .font(.system(size: 12))
        .disabled(session.isBusy || session.duration <= 0)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeading("Resolution", icon: "rectangle.arrowtriangle.2.outward",
                                       detail: "\(Int(session.exportOutputSize.width)) × \(Int(session.exportOutputSize.height))",
                                       help: "Fit the video or crop within the selected resolution, preserving its aspect ratio. Smaller videos are never upscaled. Original retains the crop’s original dimensions.")
                        Picker("Export resolution", selection: $session.exportResolution) {
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
                        Picker("Export quality", selection: $session.exportQuality) {
                            ForEach(TrimExportQuality.allCases) { quality in
                                Text(quality.title).tag(quality)
                                    .disabled(quality == .source && session.exportResolution != .source)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if !session.audioTrackChoices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeading("Audio", icon: "speaker.wave.2",
                                           help: "Choose the tracks you hear in the preview and keep in the MP4. All Tracks retains every track. GIFs have no audio.")
                            Picker("Audio track", selection: $session.selectedAudioTrackID) {
                                Text("All Tracks").tag(AudioTrackChoice.allTracksID)
                                ForEach(session.audioTrackChoices) { choice in
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
                .disabled(session.isBusy || session.duration <= 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage = session.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                estimateSummary
                Divider()
                HStack {
                    if session.isBusy {
                        Button("Cancel Export") {
                            exports.cancel()
                        }
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    Button("Done", action: onClose)
                        .disabled(session.isBusy)
                    Button {
                        session.exportTrimmedClip()
                    } label: {
                        if session.isExporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .tint(AppTheme.accent)
                    .disabled(session.isBusy || session.duration <= 0 || session.trimEnd <= session.trimStart)
                    .keyboardShortcut(.defaultAction)
                    .help("Save the selected range as an MP4")
                }
            }
            .padding(16)
        }
        .tint(AppTheme.accent)
    }

    private var bitrateLabel: String? {
        session.exportQuality.videoBitrateMbps(for: session.exportOutputSize)
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
            if session.estimatedExportBytes > 0 {
                let fits = session.estimatedExportBytes <= TrimExportEstimate.discordLimitBytes
                Label(fits ? "At or below 100 MB" : "Over 100 MB",
                      systemImage: fits ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(fits ? Color.green : Color.orange)
                Text("~" + ByteCountFormatter.string(fromByteCount: session.estimatedExportBytes, countStyle: .decimal))
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
                    session.gifExpanded.toggle()
                } label: {
                    HStack {
                        Label("Export a GIF", systemImage: "photo.stack")
                        Spacer()
                        Image(systemName: session.gifExpanded ? "chevron.up" : "chevron.down")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Export a GIF")
                .accessibilityValue(session.gifExpanded ? "Expanded" : "Collapsed")
                TrimHelpButton(text: "Export the selected range and crop as a looping GIF without audio. GIF size is independent of MP4 resolution and quality. The approximate estimate samples image content; the final file size can differ.")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(session.gifExpanded ? AppTheme.textPrimary : AppTheme.textSecondary)
            if session.gifExpanded {
                Picker("GIF size", selection: $session.gifWidth) {
                    ForEach(GIFWidth.allCases) { width in Text(width.title).tag(width) }
                }
                .labelsHidden()
                Text(session.gifEstimateLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(session.gifEstimateLabel)
                Button {
                    session.exportGIF()
                } label: {
                    HStack {
                        Spacer()
                        if session.isExportingGIF {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Export GIF", systemImage: "photo.stack")
                        }
                        Spacer()
                    }
                }
                .disabled(session.isBusy || session.trimEnd <= session.trimStart)
            }
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
