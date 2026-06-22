import SwiftUI
import AppKit
import AVFoundation
import AVKit
import Save

public struct ClipLibraryView: View {
    @StateObject private var model = ClipLibraryViewModel()
    @State private var selection: String?
    @State private var sortMode: ClipSortMode = .date
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var deleteCandidate: ClipRow?
    @State private var cleanupSheetPresented = false
    @State private var previewURL: URL?
    @State private var trimURL: URL?
    @State private var metadataDraft = ClipUserMetadata.empty
    @State private var renameDraft = ""
    @State private var copiedFilePath: String?

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
        .onChange(of: selection) { _, _ in
            syncDraftFromSelection()
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
                    if let selection, !model.rows.contains(where: { $0.id == selection }) {
                        self.selection = nil
                    }
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
                    if selection == row.id {
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
                        NSWorkspace.shared.open(row.info.fileURL)
                    }

                    IconActionButton(icon: "scissors", color: AppTheme.accentSecondary) {
                        trimURL = row.info.fileURL
                    }

                    ClipShareLink(url: row.info.fileURL)

                    IconActionButton(
                        icon: copiedFilePath == row.info.fileURL.path ? "checkmark" : "doc.on.doc",
                        color: copiedFilePath == row.info.fileURL.path ? AppTheme.success : AppTheme.textSecondary
                    ) {
                        copyFile(row.info.fileURL)
                    }

                    IconActionButton(icon: "folder", color: AppTheme.textSecondary) {
                        NSWorkspace.shared.activateFileViewerSelecting([row.info.fileURL])
                    }

                    IconActionButton(icon: "trash", color: AppTheme.danger) {
                        deleteCandidate = row
                    }
                }
            }
            .width(min: 210, ideal: 240)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
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
                        Text("Trim")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

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

                Text(row.info.fileURL.lastPathComponent)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)

                Spacer()
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

    private var selectedRow: ClipRow? {
        guard let selection else { return nil }
        return model.rows.first(where: { $0.id == selection })
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
        guard let selectedRow else {
            metadataDraft = .empty
            renameDraft = ""
            return
        }
        metadataDraft = selectedRow.userMetadata
        renameDraft = selectedRow.fileNameWithoutExtension
    }

    private func saveDraft(for row: ClipRow) {
        model.updateMetadata(for: row, metadata: metadataDraft)
    }

    private func applyRename(for row: ClipRow) {
        let oldID = row.id
        if let newID = model.rename(row, to: renameDraft, metadata: metadataDraft) {
            selection = newID
        } else {
            selection = oldID
        }
        syncDraftFromSelection()
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
        let base = ClipMetadata.scanClips(in: AppSettings.outputDirectoryURL)
        metadataByPath = ClipLibraryMetadataStore.load(in: AppSettings.outputDirectoryURL)

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
        ClipLibraryMetadataStore.save(metadataByPath, in: AppSettings.outputDirectoryURL)
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

private struct ClipTrimView: View {
    let url: URL
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            if let player {
                AVPlayerViewRepresentable(player: player)
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

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12, design: .rounded))
            }

            HStack {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .disabled(isExporting)

                Button {
                    Task { await exportTrimmedClip() }
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Export Trim", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(isExporting || trimEnd <= trimStart)
            }
        }
        .padding(16)
        .task {
            await loadClip()
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

        await MainActor.run {
            duration = seconds
            trimStart = 0
            trimEnd = seconds
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            newPlayer.play()
        }
    }

    private func exportTrimmedClip() async {
        isExporting = true
        errorMessage = nil

        do {
            let asset = AVURLAsset(url: url)
            let outputURL = try ClipMetadata.generateUniqueFileURL(
                in: url.deletingLastPathComponent(),
                suffix: "Trimmed"
            )
            let start = CMTime(seconds: trimStart, preferredTimescale: 600)
            let end = CMTime(seconds: trimEnd, preferredTimescale: 600)
            let range = CMTimeRangeFromTimeToTime(start: start, end: end)

            let preset: String
            if await AVAssetExportSession.compatibility(
                ofExportPreset: AVAssetExportPresetPassthrough,
                with: asset,
                outputFileType: .mp4
            ) {
                preset = AVAssetExportPresetPassthrough
            } else {
                preset = AVAssetExportPresetHighestQuality
            }

            guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw TrimExportError.cannotCreateSession
            }

            exportSession.timeRange = range
            exportSession.shouldOptimizeForNetworkUse = true
            try await exportSession.export(to: outputURL, as: .mp4)

            onExport()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isExporting = false
    }

    private func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private enum TrimExportError: LocalizedError {
    case cannotCreateSession
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .cannotCreateSession:
            return "Unable to create a trim export session."
        case .exportFailed:
            return "Trim export did not complete."
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
