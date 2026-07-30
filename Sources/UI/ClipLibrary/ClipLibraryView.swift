import SwiftUI
import AppKit
// @preconcurrency: Swift 6.1 (still served by GitHub's macos-latest runners)
// rejects loadTracks' non-Sendable [AVAssetTrack] result; 6.3 accepts it.
@preconcurrency import AVFoundation
import AVKit
import Save
import UniformTypeIdentifiers

public struct ClipLibraryView: View {
    @StateObject private var model = ClipLibraryViewModel()
    @State private var selection = Set<String>()
    @State private var sortMode: ClipSortMode = .date
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var deleteCandidate: ClipRow?
    @State private var bulkDeletePresented = false
    @State private var bulkTagDraft = ""
    @State private var cleanupSheetPresented = false
    @State private var previewURL: URL?
    @State private var trimURL: URL?
    @State private var metadataDraft = ClipUserMetadata.empty
    @State private var renameDraft = ""
    @State private var copiedFilePath: String?
    @State private var gifExportingPath: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            toolbarView
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            storageSummaryView
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 20)

            if visibleRows.isEmpty {
                emptyStateView
                    .frame(maxHeight: .infinity)
            } else {
                tableView
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }

            if selection.count > 1 {
                batchBarView(for: selectedRows)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(AppTheme.backgroundSecondary.opacity(0.5))
            } else if let row = singleSelectedRow {
                bottomBarView(for: row)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(AppTheme.backgroundSecondary.opacity(0.5))
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .task {
            await model.reload()
        }
        .onChange(of: selection) { _, _ in
            syncDraftFromSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .replayCapClipSaved)) { _ in
            Task { await model.reload() }
        }
        .alert("Delete Clip?", isPresented: deleteAlertBinding, presenting: deleteCandidate) { row in
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete(row)
                    selection.remove(row.id)
                    deleteCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) {
                deleteCandidate = nil
            }
        } message: { row in
            Text("Move \(row.fileName) to Trash?")
        }
        .alert("Delete \(selectedRows.count) Clips?", isPresented: $bulkDeletePresented) {
            Button("Delete", role: .destructive) {
                let targets = selectedRows
                Task {
                    await model.delete(targets)
                    pruneSelectionToExistingRows()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Move \(selectedRows.count) clips to Trash? Favorites are included.")
        }
        .sheet(isPresented: previewSheetBinding) {
            if let previewURL {
                ClipPreviewView(url: previewURL)
            }
        }
        .sheet(isPresented: trimSheetBinding) {
            if let trimURL {
                ClipTrimView(url: trimURL) {
                    Task { await model.reload() }
                }
            }
        }
        .sheet(isPresented: $cleanupSheetPresented) {
            ClipCleanupView(summary: model.storageSummary) { action in
                Task {
                    await model.cleanup(action)
                    pruneSelectionToExistingRows()
                    cleanupSheetPresented = false
                }
            }
        }
    }

    private var toolbarView: some View {
        HStack(spacing: 12) {
            TextField("Search clips, tags, notes", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Toggle(isOn: $favoritesOnly) {
                Image(systemName: "star.fill")
                    .foregroundStyle(favoritesOnly ? .yellow : AppTheme.textSecondary)
            }
            .toggleStyle(.button)
            .help("Show favorites only")

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
                cleanupSheetPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.minus")
                    Text("Clean Up")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.rows.isEmpty)

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

    private var storageSummaryView: some View {
        HStack(spacing: 14) {
            Label("\(model.storageSummary.clipCount) clips", systemImage: "film.stack")
            Label(ByteCountFormatter.string(fromByteCount: model.storageSummary.totalBytes, countStyle: .file), systemImage: "internaldrive")
            if let oldest = model.storageSummary.oldestClipDate {
                Label("Oldest \(DateFormatter.clipLibraryDate.string(from: oldest))", systemImage: "clock")
            }
            Spacer()
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(AppTheme.textSecondary)
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
        Table(visibleRows, selection: $selection) {
            TableColumn("") { row in
                Button {
                    model.toggleFavorite(row)
                    if selection.contains(row.id) {
                        syncDraftFromSelection()
                    }
                } label: {
                    Image(systemName: row.userMetadata.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(row.userMetadata.isFavorite ? .yellow : AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(row.userMetadata.isFavorite ? "Remove favorite" : "Mark favorite")
            }
            .width(32)

            TableColumn("Clip") { row in
                HStack(spacing: 12) {
                    ClipThumbnailView(image: row.thumbnail)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayTitle)
                            .lineLimit(1)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        Text(row.fileName)
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textSecondary)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                    }
                }
            }
            .width(min: 280, ideal: 360)

            TableColumn("Tags") { row in
                Text(row.tagsLabel)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(row.userMetadata.tags.isEmpty ? AppTheme.textSecondary : AppTheme.accent)
            }
            .width(min: 110, ideal: 150)

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
                        previewURL = row.info.fileURL
                    }
                    .help("Quick preview")

                    IconActionButton(icon: "scissors", color: AppTheme.accentSecondary) {
                        trimURL = row.info.fileURL
                    }
                    .help("Trim & Export")

                    ClipShareLink(url: row.info.fileURL)

                    IconActionButton(
                        icon: copiedFilePath == row.info.fileURL.path ? "checkmark" : "doc.on.doc",
                        color: copiedFilePath == row.info.fileURL.path ? AppTheme.success : AppTheme.textSecondary
                    ) {
                        copyFile(row.info.fileURL)
                    }
                    .help("Copy file to clipboard")

                    IconActionButton(icon: "folder", color: AppTheme.textSecondary) {
                        NSWorkspace.shared.activateFileViewerSelecting([row.info.fileURL])
                    }
                    .help("Reveal in Finder")

                    IconActionButton(icon: "trash", color: AppTheme.danger) {
                        requestDelete([row])
                    }
                    .help("Delete clip (moves it to Trash)")
                }
            }
            .width(min: 240, ideal: 260)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ClipRow.ID.self) { ids in
            let targets = rows(for: ids)
            if !targets.isEmpty {
                if let row = targets.first, targets.count == 1 {
                    Button("Quick Preview") { previewURL = row.info.fileURL }
                    Button("Trim & Export…") { trimURL = row.info.fileURL }
                    Button("Copy File") { copyFile(row.info.fileURL) }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.info.fileURL))
                }
                Divider()
                Button(targets.count == 1 ? "Delete Clip" : "Delete \(targets.count) Clips", role: .destructive) {
                    requestDelete(targets)
                }
            }
        } primaryAction: { ids in
            if let row = rows(for: ids).first {
                previewURL = row.info.fileURL
            }
        }
        .onDeleteCommand {
            requestDelete(selectedRows)
        }
    }

    private func rows(for ids: Set<ClipRow.ID>) -> [ClipRow] {
        model.rows.filter { ids.contains($0.id) }
    }

    /// Routes a delete request to the single- or bulk-confirmation alert.
    /// Selection is synced first so the bulk alert (which reads `selectedRows`)
    /// targets exactly what was right-clicked.
    private func requestDelete(_ targets: [ClipRow]) {
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            deleteCandidate = targets[0]
        } else {
            selection = Set(targets.map(\.id))
            bulkDeletePresented = true
        }
    }

    private func bottomBarView(for row: ClipRow) -> some View {
        VStack(spacing: 10) {
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

                Button {
                    trimURL = row.info.fileURL
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "scissors")
                        Text("Trim & Export")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Trim or crop the clip, choose an audio track, and export as MP4 or GIF")

                ShareLink(item: row.info.fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    copyFile(row.info.fileURL)
                } label: {
                    Label(
                        copiedFilePath == row.info.fileURL.path ? "Copied" : "Copy File",
                        systemImage: copiedFilePath == row.info.fileURL.path ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task { await exportWholeClipGIF(for: row) }
                } label: {
                    HStack(spacing: 6) {
                        if gifExportingPath == row.info.fileURL.path {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "photo.stack")
                        }
                        Text("Export GIF")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(gifExportingPath != nil)
                .help("Export the whole clip as a looping GIF (no audio). Use Trim to choose a range or size.")

                Text(row.info.fileURL.lastPathComponent)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)

                Spacer()

                Button(role: .destructive) {
                    requestDelete([row])
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(AppTheme.danger)
                .help("Move this clip to Trash")
            }

            HStack(alignment: .top, spacing: 12) {
                Toggle("Favorite", isOn: Binding(
                    get: { metadataDraft.isFavorite },
                    set: { metadataDraft.isFavorite = $0 }
                ))
                .toggleStyle(.checkbox)
                .frame(width: 90, alignment: .leading)

                TextField("Display name", text: $metadataDraft.displayName)
                    .textFieldStyle(.roundedBorder)

                TextField("File name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)

                Button("Rename File") {
                    applyRename(for: row)
                }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Save Details") {
                    saveDraft(for: row)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
            }

            HStack(spacing: 12) {
                TextField("Tags, comma separated", text: Binding(
                    get: { metadataDraft.tags.joined(separator: ", ") },
                    set: { metadataDraft.tags = Self.parseTags($0) }
                ))
                .textFieldStyle(.roundedBorder)

                TextField("Notes", text: $metadataDraft.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
            }
            .font(.system(size: 12, weight: .regular, design: .rounded))
        }
    }

    private func batchBarView(for rows: [ClipRow]) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("\(rows.count) clips selected")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Button {
                    model.setFavorite(rows, to: true)
                } label: {
                    Label("Favorite", systemImage: "star.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    model.setFavorite(rows, to: false)
                } label: {
                    Label("Unfavorite", systemImage: "star.slash")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                ShareLink(items: rows.map(\.info.fileURL)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(role: .destructive) {
                    bulkDeletePresented = true
                } label: {
                    Label("Delete \(rows.count)", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(AppTheme.danger)
            }

            HStack(spacing: 12) {
                TextField("Add tag to all selected", text: $bulkTagDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyBulkTag(to: rows) }

                Button("Add Tag") {
                    applyBulkTag(to: rows)
                }
                .disabled(bulkTagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 12, weight: .regular, design: .rounded))
        }
    }

    private func applyBulkTag(to rows: [ClipRow]) {
        let tag = bulkTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        model.addTag(tag, to: rows)
        bulkTagDraft = ""
    }

    private var selectedRows: [ClipRow] {
        model.rows.filter { selection.contains($0.id) }
    }

    private var singleSelectedRow: ClipRow? {
        guard selection.count == 1 else { return nil }
        return model.rows.first(where: { selection.contains($0.id) })
    }

    private func pruneSelectionToExistingRows() {
        selection = selection.filter { id in model.rows.contains(where: { $0.id == id }) }
    }

    private var visibleRows: [ClipRow] {
        model.sortedRows(by: sortMode).filter { row in
            let matchesFavorite = !favoritesOnly || row.userMetadata.isFavorite
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard matchesFavorite, !query.isEmpty else {
                return matchesFavorite
            }
            return row.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    private func syncDraftFromSelection() {
        guard let row = singleSelectedRow else {
            metadataDraft = .empty
            renameDraft = ""
            return
        }
        metadataDraft = row.userMetadata
        renameDraft = row.fileNameWithoutExtension
    }

    private func saveDraft(for row: ClipRow) {
        model.updateMetadata(for: row, metadata: metadataDraft)
    }

    private func applyRename(for row: ClipRow) {
        let oldID = row.id
        if let newID = model.rename(row, to: renameDraft, metadata: metadataDraft) {
            selection = [newID]
        } else {
            selection = [oldID]
        }
        syncDraftFromSelection()
    }

    private func exportWholeClipGIF(for row: ClipRow) async {
        let sourceURL = row.info.fileURL
        let end = row.info.duration.isFinite && row.info.duration > 0 ? row.info.duration : 0
        guard end > 0 else { return }

        let suggestedURL = GIFExporter.uniqueOutputURL(basedOn: sourceURL)
        guard let outputURL = await ExportDestinationPicker.chooseDestination(
            suggestedURL: suggestedURL,
            contentType: .gif,
            title: "Export GIF"
        ) else {
            return
        }

        gifExportingPath = sourceURL.path
        defer { gifExportingPath = nil }

        do {
            try await GIFExporter.export(
                sourceURL: sourceURL,
                startSeconds: 0,
                endSeconds: end,
                to: outputURL
            )
            // GIFs aren't listed in the library (MP4s only), so reveal in Finder.
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        } catch {
            print("Failed to export GIF: \(error)")
        }
    }

    private func copyFile(_ url: URL) {
        guard ClipSharing.copyFileToPasteboard(url) else {
            return
        }

        let copiedPath = url.path
        copiedFilePath = copiedPath
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard copiedFilePath == copiedPath else { return }
            copiedFilePath = nil
        }
    }

    private static func parseTags(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniquedCaseInsensitive()
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

    private var trimSheetBinding: Binding<Bool> {
        Binding(
            get: { trimURL != nil },
            set: { isPresented in
                if !isPresented {
                    trimURL = nil
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
    var userMetadata: ClipUserMetadata

    var id: String { info.fileURL.path }
    var fileName: String { info.fileURL.lastPathComponent }
    var fileNameWithoutExtension: String { info.fileURL.deletingPathExtension().lastPathComponent }
    var displayTitle: String {
        userMetadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fileNameWithoutExtension
            : userMetadata.displayName
    }
    var tagsLabel: String {
        userMetadata.tags.isEmpty ? "No tags" : userMetadata.tags.joined(separator: ", ")
    }
    var searchText: String {
        ([displayTitle, fileName, userMetadata.notes] + userMetadata.tags).joined(separator: " ")
    }

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
    @Published var storageSummary = ClipLibraryStorageSummary(clipCount: 0, totalBytes: 0, oldestClipDate: nil)
    private var metadataByPath: [String: ClipUserMetadata] = [:]

    /// Enriched info + thumbnail for a clip, keyed by ``cacheKey(for:)``.
    /// Lets repeated reloads (which fire on every save and on Refresh) skip
    /// re-reading AV assets and regenerating thumbnails for unchanged files.
    private struct CachedClip {
        let info: ClipInfo
        let thumbnail: NSImage?
    }
    private var clipCache: [String: CachedClip] = [:]

    func reload() async {
        guard let outputDirectory = AppSettings.outputDirectoryURL else {
            rows = []
            metadataByPath = [:]
            clipCache = [:]
            updateStorageSummary()
            return
        }

        let base = ClipMetadata.scanClips(in: outputDirectory)
        metadataByPath = ClipLibraryMetadataStore.load(in: outputDirectory)

        let cache = clipCache
        let misses = base.filter { cache[Self.cacheKey(for: $0)] == nil }

        // Enrich + generate thumbnails for new/changed clips in parallel.
        // Thumbnails cross the task boundary as PNG `Data` (Sendable) and are
        // decoded back into `NSImage` on the main actor below.
        let computed: [(key: String, info: ClipInfo, thumbnail: Data?)] = await withTaskGroup(
            of: (key: String, info: ClipInfo, thumbnail: Data?).self
        ) { group in
            for info in misses {
                let key = Self.cacheKey(for: info)
                group.addTask {
                    let enriched = await ClipMetadata.enrichClipInfo(info)
                    let thumbnail = await Self.thumbnailData(for: enriched.fileURL)
                    return (key: key, info: enriched, thumbnail: thumbnail)
                }
            }

            var collected: [(key: String, info: ClipInfo, thumbnail: Data?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        if Task.isCancelled { return }

        // Rebuild the cache to current files only (reusing hits, prunes stale).
        var refreshedCache: [String: CachedClip] = [:]
        for info in base {
            let key = Self.cacheKey(for: info)
            if let hit = cache[key] {
                refreshedCache[key] = hit
            }
        }
        for entry in computed {
            refreshedCache[entry.key] = CachedClip(
                info: entry.info,
                thumbnail: entry.thumbnail.flatMap { NSImage(data: $0) }
            )
        }
        clipCache = refreshedCache

        rows = base.compactMap { info in
            guard let cached = refreshedCache[Self.cacheKey(for: info)] else { return nil }
            let key = ClipLibraryMetadataStore.key(for: cached.info.fileURL)
            return ClipRow(info: cached.info, thumbnail: cached.thumbnail, userMetadata: metadataByPath[key] ?? .empty)
        }
        pruneMissingMetadata()
        updateStorageSummary()
    }

    /// Identifies a clip's cached render by path, size, and creation date so a
    /// moved, replaced, or re-encoded file misses the cache and regenerates.
    private static func cacheKey(for info: ClipInfo) -> String {
        "\(info.fileURL.path)|\(info.fileSize)|\(info.creationDate.timeIntervalSince1970)"
    }

    func delete(_ row: ClipRow) async {
        do {
            try FileManager.default.trashItem(at: row.info.fileURL, resultingItemURL: nil)
            rows.removeAll(where: { $0.id == row.id })
            metadataByPath.removeValue(forKey: ClipLibraryMetadataStore.key(for: row.info.fileURL))
            persistMetadata()
            updateStorageSummary()
        } catch {
            print("Failed to delete clip: \(error)")
        }
    }

    func delete(_ rowsToDelete: [ClipRow]) async {
        let ids = Set(rowsToDelete.map(\.id))
        for row in rowsToDelete {
            do {
                try FileManager.default.trashItem(at: row.info.fileURL, resultingItemURL: nil)
                metadataByPath.removeValue(forKey: ClipLibraryMetadataStore.key(for: row.info.fileURL))
            } catch {
                print("Failed to delete clip: \(error)")
            }
        }
        rows.removeAll { ids.contains($0.id) }
        persistMetadata()
        updateStorageSummary()
    }

    func setFavorite(_ targetRows: [ClipRow], to isFavorite: Bool) {
        for row in targetRows {
            var metadata = row.userMetadata
            metadata.isFavorite = isFavorite
            applyMetadataInPlace(metadata, for: row)
        }
        persistMetadata()
    }

    func addTag(_ tag: String, to targetRows: [ClipRow]) {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        for row in targetRows {
            var metadata = row.userMetadata
            if !metadata.tags.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                metadata.tags.append(clean)
            }
            applyMetadataInPlace(metadata, for: row)
        }
        persistMetadata()
    }

    /// Updates a clip's metadata in the cache and live rows without writing to
    /// disk, so batch operations can persist once at the end.
    private func applyMetadataInPlace(_ metadata: ClipUserMetadata, for row: ClipRow) {
        metadataByPath[ClipLibraryMetadataStore.key(for: row.info.fileURL)] = metadata
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index].userMetadata = metadata
        }
    }

    func updateMetadata(for row: ClipRow, metadata: ClipUserMetadata) {
        let key = ClipLibraryMetadataStore.key(for: row.info.fileURL)
        metadataByPath[key] = metadata
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index].userMetadata = metadata
        }
        persistMetadata()
    }

    func toggleFavorite(_ row: ClipRow) {
        var metadata = row.userMetadata
        metadata.isFavorite.toggle()
        updateMetadata(for: row, metadata: metadata)
    }

    func rename(_ row: ClipRow, to requestedName: String, metadata: ClipUserMetadata) -> String? {
        let cleanName = sanitizedFileBaseName(requestedName)
        guard !cleanName.isEmpty else { return nil }

        let oldURL = row.info.fileURL
        if cleanName == oldURL.deletingPathExtension().lastPathComponent {
            updateMetadata(for: row, metadata: metadata)
            return row.id
        }

        let newURL = uniqueURL(
            directory: oldURL.deletingLastPathComponent(),
            baseName: cleanName,
            extensionName: oldURL.pathExtension
        )

        guard oldURL.standardizedFileURL != newURL.standardizedFileURL else {
            updateMetadata(for: row, metadata: metadata)
            return row.id
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            let oldKey = ClipLibraryMetadataStore.key(for: oldURL)
            metadataByPath.removeValue(forKey: oldKey)
            metadataByPath[ClipLibraryMetadataStore.key(for: newURL)] = metadata
            persistMetadata()
            Task { await reload() }
            return newURL.path(percentEncoded: false)
        } catch {
            print("Failed to rename clip: \(error)")
            return nil
        }
    }

    func cleanup(_ action: ClipCleanupAction) async {
        let now = Date()
        let candidates: [ClipRow]
        switch action {
        case .nonFavoritesOlderThanDays(let days):
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
            candidates = rows.filter { !$0.userMetadata.isFavorite && $0.info.creationDate < cutoff }
        case .allNonFavorites:
            candidates = rows.filter { !$0.userMetadata.isFavorite }
        }

        for row in candidates {
            try? FileManager.default.trashItem(at: row.info.fileURL, resultingItemURL: nil)
            metadataByPath.removeValue(forKey: ClipLibraryMetadataStore.key(for: row.info.fileURL))
        }

        persistMetadata()
        await reload()
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

    private func updateStorageSummary() {
        storageSummary = ClipLibraryStorageSummary(
            clipCount: rows.count,
            totalBytes: rows.reduce(0) { $0 + $1.info.fileSize },
            oldestClipDate: rows.map(\.info.creationDate).min()
        )
    }

    private func pruneMissingMetadata() {
        let liveKeys = Set(rows.map { ClipLibraryMetadataStore.key(for: $0.info.fileURL) })
        metadataByPath = metadataByPath.filter { liveKeys.contains($0.key) }
        persistMetadata()
    }

    private func persistMetadata() {
        guard let outputDirectory = AppSettings.outputDirectoryURL else {
            return
        }
        ClipLibraryMetadataStore.save(metadataByPath, in: outputDirectory)
    }

    private func sanitizedFileBaseName(_ requestedName: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return requestedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: illegal)
            .joined(separator: "-")
    }

    private func uniqueURL(directory: URL, baseName: String, extensionName: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(extensionName)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)_\(counter)").appendingPathExtension(extensionName)
            counter += 1
        }
        return candidate
    }

    private static func thumbnailData(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 220, height: 124)

        // Encode to PNG inside the callback so only `Data` (Sendable) crosses
        // the continuation and task-group boundaries.
        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                guard let image else {
                    continuation.resume(returning: nil)
                    return
                }
                let rep = NSBitmapImageRep(cgImage: image)
                continuation.resume(returning: rep.representation(using: .png, properties: [:]))
            }
        }
    }
}

private enum ClipCleanupAction {
    case nonFavoritesOlderThanDays(Int)
    case allNonFavorites
}

private struct ClipCleanupView: View {
    let summary: ClipLibraryStorageSummary
    let onRun: (ClipCleanupAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var days = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Storage Cleanup", systemImage: "externaldrive.badge.minus")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
            }

            HStack(spacing: 14) {
                Label("\(summary.clipCount) clips", systemImage: "film.stack")
                Label(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file), systemImage: "internaldrive")
            }
            .foregroundStyle(AppTheme.textSecondary)

            Stepper(value: $days, in: 1...365) {
                Text("Delete non-favorites older than \(days) days")
            }

            Text("Cleanup moves matching clips to Trash and keeps favorites. Clip notes and tags for deleted files are removed.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Delete All Non-Favorites", role: .destructive) {
                    onRun(.allNonFavorites)
                }
                .disabled(summary.clipCount == 0)

                Button("Run Cleanup") {
                    onRun(.nonFavoritesOlderThanDays(days))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.danger)
                .disabled(summary.clipCount == 0)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private extension Array where Element == String {
    func uniquedCaseInsensitive() -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in self {
            let key = value.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(value)
        }
        return result
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

    var body: some View {
        Button(action: action) {
            IconActionLabel(icon: icon, color: color)
        }
        .buttonStyle(.plain)
    }
}

private struct ClipShareLink: View {
    let url: URL

    var body: some View {
        ShareLink(item: url) {
            IconActionLabel(icon: "square.and.arrow.up", color: AppTheme.accent)
        }
        .buttonStyle(.plain)
        .help("Share clip")
    }
}

private struct IconActionLabel: View {
    let icon: String
    let color: Color

    @State private var isHovering = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(isHovering ? 0.15 : 0.08))
            )
            .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

private enum ClipSharing {
    static func copyFileToPasteboard(_ url: URL) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([url as NSURL])
    }
}

/// An audio track a clip player can solo, identified by its persistent track
/// ID in the file. `allTracksID` is a sentinel for "play every track".
private struct AudioTrackChoice: Identifiable, Hashable {
    static let allTracksID: CMPersistentTrackID = -1

    let id: CMPersistentTrackID
    let label: String
}

private enum ClipAudioTracks {
    /// Returns selectable audio tracks for the clip, or `[]` when the clip has
    /// zero or one audio track (nothing to choose between).
    ///
    /// The save pipeline writes system audio before the microphone when
    /// "Merge audio tracks" is off, so labels are assigned by track order.
    static func choices(for asset: AVURLAsset) async -> [AudioTrackChoice] {
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard tracks.count > 1 else { return [] }
        return tracks.enumerated().map { index, track in
            AudioTrackChoice(id: track.trackID, label: label(forTrackAt: index))
        }
    }

    private static func label(forTrackAt index: Int) -> String {
        switch index {
        case 0: return "System Audio"
        case 1: return "Microphone"
        default: return "Track \(index + 1)"
        }
    }

    /// Mutes every audio track except the selected one (or unmutes all when
    /// `selection` is `allTracksID`). Playback-only; the file is untouched.
    @MainActor
    static func apply(
        selection: CMPersistentTrackID,
        choices: [AudioTrackChoice],
        to item: AVPlayerItem?
    ) {
        guard let item, !choices.isEmpty else { return }
        let mix = AVMutableAudioMix()
        mix.inputParameters = choices.map { choice in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = choice.id
            let isAudible = selection == AudioTrackChoice.allTracksID || selection == choice.id
            parameters.setVolume(isAudible ? 1 : 0, at: .zero)
            return parameters
        }
        item.audioMix = mix
    }

    /// Builds a composition with the clip's video and only the selected audio
    /// track, so an export drops the other tracks entirely. Falls back to the
    /// original asset if the track is no longer present in the file.
    ///
    /// Deliberately not main-actor isolated: `insertTimeRange` is synchronous
    /// and can take real time on a long clip, which has no business blocking
    /// the main thread.
    nonisolated static func soloComposition(
        from asset: AVURLAsset,
        audioTrackID: CMPersistentTrackID
    ) async throws -> AVAsset {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let soloTrack = audioTracks.first(where: { $0.trackID == audioTrackID }) else {
            return asset
        }

        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: duration)

        for videoTrack in try await asset.loadTracks(withMediaType: .video) {
            guard let target = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw TrimExportError.cannotBuildComposition
            }
            try target.insertTimeRange(fullRange, of: videoTrack, at: .zero)
            target.preferredTransform = try await videoTrack.load(.preferredTransform)
        }

        guard let target = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TrimExportError.cannotBuildComposition
        }
        try target.insertTimeRange(fullRange, of: soloTrack, at: .zero)

        return composition
    }
}

private struct AudioTrackPickerView: View {
    let choices: [AudioTrackChoice]
    @Binding var selection: CMPersistentTrackID
    var help = "Choose which audio track you hear. Playback only — the file keeps all tracks."

    var body: some View {
        HStack(spacing: 8) {
            Label("Audio", systemImage: "speaker.wave.2")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
            Picker("Audio track", selection: $selection) {
                Text("All Tracks").tag(AudioTrackChoice.allTracksID)
                ForEach(choices) { choice in
                    Text(choice.label).tag(choice.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            .help(help)
            Spacer()
        }
    }
}

private struct ClipPreviewView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var audioTrackChoices: [AudioTrackChoice] = []
    @State private var selectedAudioTrackID = AudioTrackChoice.allTracksID

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

            if !audioTrackChoices.isEmpty {
                AudioTrackPickerView(choices: audioTrackChoices, selection: $selectedAudioTrackID)
            }

            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(16)
        .task {
            await loadPlayer()
        }
        .onChange(of: selectedAudioTrackID) { _, newValue in
            ClipAudioTracks.apply(selection: newValue, choices: audioTrackChoices, to: player?.currentItem)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadPlayer() async {
        guard player == nil else { return }
        let asset = AVURLAsset(url: url)
        audioTrackChoices = await ClipAudioTracks.choices(for: asset)
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        ClipAudioTracks.apply(selection: selectedAudioTrackID, choices: audioTrackChoices, to: newPlayer.currentItem)
        newPlayer.play()
        player = newPlayer
    }
}

private struct ClipTrimView: View {
    let url: URL
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var isExporting = false
    @State private var isExportingGIF = false
    @State private var gifWidth: GIFWidth = .medium
    @State private var errorMessage: String?
    @State private var audioTrackChoices: [AudioTrackChoice] = []
    @State private var selectedAudioTrackID = AudioTrackChoice.allTracksID
    @State private var cropEnabled = false
    @State private var cropRect = NormalizedVideoCrop.fullFrame.rect
    @State private var cropAspect: CropAspectPreset = .free
    @State private var videoDisplaySize = CGSize(width: 16, height: 9)
    @State private var activeExportSession: AVAssetExportSession?

    private var isBusy: Bool { isExporting || isExportingGIF }
    private var activeCrop: NormalizedVideoCrop? {
        guard cropEnabled else { return nil }
        let crop = NormalizedVideoCrop(cropRect)
        return crop.isFullFrame ? nil : crop
    }

    var body: some View {
        VStack(spacing: 14) {
            if let player {
                ZStack {
                    AVPlayerViewRepresentable(player: player)
                    if cropEnabled {
                        VideoCropSelectionView(
                            selection: $cropRect,
                            videoSize: videoDisplaySize,
                            onManualChange: { cropAspect = .free }
                        )
                    }
                }
                    .frame(minWidth: 720, minHeight: 405)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
            } else {
                ZStack {
                    AppTheme.backgroundSecondary
                    ProgressView("Loading clip…")
                }
                .frame(minWidth: 720, minHeight: 405)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
            }

            VStack(spacing: 10) {
                HStack {
                    Text("Start")
                    Slider(value: $trimStart, in: 0...max(duration, 0.1), step: 0.1)
                        .onChange(of: trimStart) { _, newValue in
                            if newValue >= trimEnd {
                                trimEnd = min(duration, newValue + 0.1)
                            }
                            seek(to: newValue)
                        }
                    Text(timeLabel(trimStart))
                        .frame(width: 52, alignment: .trailing)
                }

                HStack {
                    Text("End")
                    Slider(value: $trimEnd, in: 0...max(duration, 0.1), step: 0.1)
                        .onChange(of: trimEnd) { _, newValue in
                            if newValue <= trimStart {
                                trimStart = max(0, newValue - 0.1)
                            }
                            seek(to: newValue)
                        }
                    Text(timeLabel(trimEnd))
                        .frame(width: 52, alignment: .trailing)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))

            cropControls

            if !audioTrackChoices.isEmpty {
                AudioTrackPickerView(
                    choices: audioTrackChoices,
                    selection: $selectedAudioTrackID,
                    help: "Choose which audio track you hear. Export Trim keeps only the selected track (All Tracks keeps every track)."
                )
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12, design: .rounded))
            }

            HStack(spacing: 8) {
                Text("GIF size")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                Picker("GIF size", selection: $gifWidth) {
                    ForEach(GIFWidth.allCases) { width in
                        Text(width.title).tag(width)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(isBusy)
                Spacer()
            }

            HStack {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)

                Spacer()

                if isExporting, let session = activeExportSession {
                    // An escape hatch while an export is running, so a wedged
                    // export never leaves the sheet with no way out.
                    Button("Cancel Export", role: .cancel) {
                        session.cancelExport()
                    }
                    .help("Stop the export in progress")
                }

                Button("Cancel") {
                    dismiss()
                }
                .disabled(isBusy)

                Button {
                    Task { await exportGIF() }
                } label: {
                    if isExportingGIF {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Export GIF", systemImage: "photo.stack")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isBusy || trimEnd <= trimStart)
                .help("Export the selected range as a looping GIF (no audio)")

                Button {
                    Task { await exportTrimmedClip() }
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(
                            activeCrop == nil ? "Export Trim" : "Export Trim & Crop",
                            systemImage: "square.and.arrow.down"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(isBusy || trimEnd <= trimStart)
            }
        }
        .padding(16)
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
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadClip() async {
        let asset = AVURLAsset(url: url)
        let loadedDuration = (try? await asset.load(.duration)) ?? .zero
        let seconds = max(CMTimeGetSeconds(loadedDuration), 0)
        let choices = await ClipAudioTracks.choices(for: asset)
        let displaySize = (try? await VideoCropper.geometry(for: asset).displaySize)
            ?? CGSize(width: 16, height: 9)

        await MainActor.run {
            duration = seconds
            trimStart = 0
            trimEnd = seconds
            audioTrackChoices = choices
            videoDisplaySize = displaySize
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            ClipAudioTracks.apply(selection: selectedAudioTrackID, choices: choices, to: newPlayer.currentItem)
            player = newPlayer
            newPlayer.play()
        }
    }

    private func exportTrimmedClip() async {
        isExporting = true
        errorMessage = nil
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

            let preset: String
            if crop != nil {
                preset = AVAssetExportPresetHighestQuality
            } else if await AVAssetExportSession.compatibility(
                ofExportPreset: AVAssetExportPresetPassthrough,
                with: exportAsset,
                outputFileType: .mp4
            ) {
                preset = AVAssetExportPresetPassthrough
            } else {
                preset = AVAssetExportPresetHighestQuality
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

            onExport()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

    }

    private func exportGIF() async {
        isExportingGIF = true
        errorMessage = nil
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
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

    }

    private func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private var cropControls: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $cropEnabled) {
                Label("Crop", systemImage: "crop")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(isBusy)
            .help("Crop both MP4 and GIF exports to the selected area")

            if cropEnabled {
                Picker("Crop aspect ratio", selection: $cropAspect) {
                    ForEach(CropAspectPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 310)
                .disabled(isBusy)

                Button("Reset") {
                    cropAspect = .free
                    cropRect = NormalizedVideoCrop.fullFrame.rect
                }
                .controlSize(.small)
                .disabled(isBusy)

                Text("\(Int((cropRect.width * 100).rounded()))% × \(Int((cropRect.height * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private enum TrimExportError: LocalizedError {
    case cannotCreateSession
    case cannotBuildComposition
    case exportFailed
    case stalled

    var errorDescription: String? {
        switch self {
        case .cannotCreateSession:
            return "Unable to create a trim export session."
        case .cannotBuildComposition:
            return "Unable to prepare the selected audio track for export."
        case .exportFailed:
            return "Trim export did not complete."
        case .stalled:
            return "The export stopped making progress and was cancelled. Please try again."
        }
    }
}

/// Carries an export session to the stall watchdog, which deliberately runs
/// off the main actor so it still fires if the main actor is starved.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

private enum ExportWatchdog {
    /// Seconds of zero progress before an export is treated as wedged.
    static let stallTimeout = 90

    /// Runs an export, cancelling it if `progress` stops advancing entirely.
    ///
    /// Without this a stuck export leaves the sheet spinning forever with no
    /// way out but force-quitting. Progress-based rather than a flat deadline,
    /// so a slow-but-advancing export of a long clip is never killed. The
    /// watchdog is detached on purpose: a main-actor watchdog cannot fire in
    /// exactly the situation it exists to catch.
    @MainActor
    static func runExport(
        _ session: AVAssetExportSession,
        to outputURL: URL,
        as fileType: AVFileType
    ) async throws {
        let box = ExportSessionBox(session)
        let watchdog = Task.detached(priority: .utility) {
            var lastProgress: Float = -1
            var stalledSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                let progress = box.session.progress
                if progress > lastProgress {
                    lastProgress = progress
                    stalledSeconds = 0
                } else {
                    stalledSeconds += 2
                    if stalledSeconds >= stallTimeout {
                        box.session.cancelExport()
                        return
                    }
                }
            }
        }
        defer { watchdog.cancel() }

        try await session.export(to: outputURL, as: fileType)
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
