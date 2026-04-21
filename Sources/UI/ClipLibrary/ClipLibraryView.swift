import SwiftUI
import AppKit
import AVFoundation
import AVKit
import Save

public struct ClipLibraryView: View {
    @StateObject private var model = ClipLibraryViewModel()
    @State private var selection: String?
    @State private var sortMode: ClipSortMode = .date
    @State private var deleteCandidate: ClipRow?
    @State private var previewURL: URL?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            toolbarView
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()
                .padding(.horizontal, 20)

            if model.rows.isEmpty {
                emptyStateView
                    .frame(maxHeight: .infinity)
            } else {
                tableView
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }

            if let selectedRow {
                bottomBarView(for: selectedRow)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(AppTheme.backgroundSecondary.opacity(0.5))
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .task {
            await model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .replayMacClipSaved)) { _ in
            Task { await model.reload() }
        }
        .alert("Delete Clip?", isPresented: deleteAlertBinding, presenting: deleteCandidate) { row in
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete(row)
                    if selection == row.id {
                        selection = nil
                    }
                    deleteCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) {
                deleteCandidate = nil
            }
        } message: { row in
            Text("Move \(row.fileName) to Trash?")
        }
        .sheet(isPresented: previewSheetBinding) {
            if let previewURL {
                ClipPreviewView(url: previewURL)
            }
        }
    }

    private var toolbarView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .foregroundStyle(AppTheme.accent)
                    .font(.system(size: 14))
                Picker("Sort", selection: $sortMode) {
                    ForEach(ClipSortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }

            Spacer()

            Button {
                Task { await model.reload() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.accent.opacity(0.15), AppTheme.accentSecondary.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: "film.stack")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
            }

            VStack(spacing: 6) {
                Text("No Clips Yet")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("Saved clips will appear here.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var tableView: some View {
        Table(model.sortedRows(by: sortMode), selection: $selection) {
            TableColumn("Clip") { row in
                HStack(spacing: 12) {
                    ClipThumbnailView(image: row.thumbnail)
                    Text(row.fileName)
                        .lineLimit(1)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                }
            }
            .width(min: 280, ideal: 380)

            TableColumn("Duration") { row in
                Text(row.durationLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .width(90)

            TableColumn("Size") { row in
                Text(row.sizeLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .width(90)

            TableColumn("Created") { row in
                Text(row.dateLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .width(min: 130, ideal: 180)

            TableColumn("Actions") { row in
                HStack(spacing: 14) {
                    IconActionButton(icon: "play.fill", color: AppTheme.accent) {
                        NSWorkspace.shared.open(row.info.fileURL)
                    }

                    IconActionButton(icon: "folder", color: AppTheme.textSecondary) {
                        NSWorkspace.shared.activateFileViewerSelecting([row.info.fileURL])
                    }

                    IconActionButton(icon: "trash", color: AppTheme.danger) {
                        deleteCandidate = row
                    }
                }
            }
            .width(min: 140, ideal: 180)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func bottomBarView(for row: ClipRow) -> some View {
        HStack(spacing: 12) {
            Button {
                previewURL = row.info.fileURL
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                    Text("Quick Preview")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .controlSize(.small)

            Text(row.info.fileURL.lastPathComponent)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)

            Spacer()
        }
    }

    private var selectedRow: ClipRow? {
        guard let selection else { return nil }
        return model.rows.first(where: { $0.id == selection })
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    deleteCandidate = nil
                }
            }
        )
    }

    private var previewSheetBinding: Binding<Bool> {
        Binding(
            get: { previewURL != nil },
            set: { isPresented in
                if !isPresented {
                    previewURL = nil
                }
            }
        )
    }
}

private enum ClipSortMode: String, CaseIterable, Identifiable {
    case date
    case name
    case duration
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return "Date"
        case .name: return "Name"
        case .duration: return "Duration"
        case .size: return "Size"
        }
    }
}

private struct ClipRow: Identifiable {
    let info: ClipInfo
    let thumbnail: NSImage?

    var id: String { info.fileURL.path }
    var fileName: String { info.fileURL.lastPathComponent }

    var durationLabel: String {
        guard info.duration.isFinite, info.duration > 0 else { return "--:--" }
        let total = Int(info.duration.rounded(.down))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file)
    }

    var dateLabel: String {
        DateFormatter.clipLibraryDate.string(from: info.creationDate)
    }
}

@MainActor
private final class ClipLibraryViewModel: ObservableObject {
    @Published var rows: [ClipRow] = []

    func reload() async {
        let base = ClipMetadata.scanClips(in: AppSettings.outputDirectoryURL)
        var loadedRows: [ClipRow] = []
        loadedRows.reserveCapacity(base.count)

        for info in base {
            if Task.isCancelled { return }
            let enriched = await ClipMetadata.enrichClipInfo(info)
            let thumbnail = await Self.thumbnail(for: enriched.fileURL)
            loadedRows.append(ClipRow(info: enriched, thumbnail: thumbnail))
        }

        rows = loadedRows
    }

    func delete(_ row: ClipRow) async {
        do {
            try FileManager.default.trashItem(at: row.info.fileURL, resultingItemURL: nil)
            rows.removeAll(where: { $0.id == row.id })
        } catch {
            print("Failed to delete clip: \(error)")
        }
    }

    func sortedRows(by mode: ClipSortMode) -> [ClipRow] {
        switch mode {
        case .date:
            return rows.sorted { $0.info.creationDate > $1.info.creationDate }
        case .name:
            return rows.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
        case .duration:
            return rows.sorted { $0.info.duration > $1.info.duration }
        case .size:
            return rows.sorted { $0.info.fileSize > $1.info.fileSize }
        }
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 220, height: 124)

        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                guard let image else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            }
        }
    }
}

private struct ClipThumbnailView: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            AppTheme.backgroundSecondary

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(width: 80, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    }
}

private struct IconActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color.opacity(isHovering ? 0.15 : 0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct ClipPreviewView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 14) {
            if let player {
                AVPlayerViewRepresentable(player: player)
                    .frame(minWidth: 640, minHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
            } else {
                ZStack {
                    AppTheme.backgroundSecondary
                    ProgressView("Loading preview…")
                }
                .frame(minWidth: 640, minHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
            }

            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(16)
        .onAppear {
            guard player == nil else { return }
            let newPlayer = AVPlayer(url: url)
            newPlayer.play()
            player = newPlayer
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private extension DateFormatter {
    static let clipLibraryDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
