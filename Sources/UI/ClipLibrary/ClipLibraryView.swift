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
        VStack(spacing: 10) {
            HStack {
                Picker("Sort", selection: $sortMode) {
                    ForEach(ClipSortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Spacer()

                Button("Refresh") {
                    Task { await model.reload() }
                }
            }

            if model.rows.isEmpty {
                ContentUnavailableView(
                    "No Clips Yet",
                    systemImage: "film",
                    description: Text("Saved clips will appear here.")
                )
            } else {
                Table(model.sortedRows(by: sortMode), selection: $selection) {
                    TableColumn("Clip") { row in
                        HStack(spacing: 10) {
                            ClipThumbnailView(image: row.thumbnail)
                            Text(row.fileName)
                                .lineLimit(1)
                        }
                    }
                    .width(min: 260, ideal: 360)

                    TableColumn("Duration") { row in
                        Text(row.durationLabel)
                    }
                    .width(90)

                    TableColumn("Size") { row in
                        Text(row.sizeLabel)
                    }
                    .width(90)

                    TableColumn("Created") { row in
                        Text(row.dateLabel)
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Actions") { row in
                        HStack(spacing: 10) {
                            Button("Play") {
                                NSWorkspace.shared.open(row.info.fileURL)
                            }
                            .buttonStyle(.link)

                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([row.info.fileURL])
                            }
                            .buttonStyle(.link)

                            Button("Delete", role: .destructive) {
                                deleteCandidate = row
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .width(min: 220, ideal: 280)
                }
            }

            if let selectedRow {
                HStack {
                    Button("Quick Preview") {
                        previewURL = selectedRow.info.fileURL
                    }
                    Text(selectedRow.info.fileURL.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
            }
        }
        .frame(minWidth: 860, minHeight: 500)
        .padding(16)
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
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.gray.opacity(0.18)
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 72, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ClipPreviewView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 12) {
            if let player {
                AVPlayerViewRepresentable(player: player)
                    .frame(minWidth: 640, minHeight: 360)
            } else {
                ProgressView("Loading preview…")
                    .frame(minWidth: 640, minHeight: 360)
            }

            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
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
