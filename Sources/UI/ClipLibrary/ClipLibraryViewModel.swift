import AppKit
import Save

enum ClipSortMode: String, CaseIterable, Identifiable {
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

struct ClipRow: Identifiable {
    let info: ClipInfo
    let thumbnail: NSImage?
    var userMetadata: ClipUserMetadata

    let id: String
    let fileName: String
    let fileNameWithoutExtension: String
    let durationLabel: String
    let sizeLabel: String
    let dateLabel: String
    let gridSubtitleLabel: String

    init(info: ClipInfo, thumbnail: NSImage?, userMetadata: ClipUserMetadata) {
        self.info = info
        self.thumbnail = thumbnail
        self.userMetadata = userMetadata
        self.id = info.fileURL.path
        self.fileName = info.fileURL.lastPathComponent
        self.fileNameWithoutExtension = info.fileURL.deletingPathExtension().lastPathComponent
        if info.duration.isFinite, info.duration > 0 {
            let total = Int(info.duration.rounded(.down))
            self.durationLabel = String(format: "%02d:%02d", total / 60, total % 60)
        } else {
            self.durationLabel = "--:--"
        }
        let sizeLabel = ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file)
        self.sizeLabel = sizeLabel
        self.dateLabel = DateFormatter.clipLibraryDate.string(from: info.creationDate)
        self.gridSubtitleLabel = "\(DateFormatter.clipGridDate.string(from: info.creationDate)) · \(sizeLabel)"
    }

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
}

@MainActor
final class ClipLibraryViewModel: ObservableObject {
    @Published var rows: [ClipRow] = []
    @Published var storageSummary = ClipLibraryStorageSummary(clipCount: 0, totalBytes: 0, oldestClipDate: nil)
    var isProtected: (URL) -> Bool = { _ in false }
    private var reloadGeneration = UUID()
    private var loadedDirectory: URL?
    private let outputDirectory: () -> URL?

    init(outputDirectory: @escaping () -> URL? = { AppSettings.outputDirectoryURL }) {
        self.outputDirectory = outputDirectory
    }
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
        let generation = UUID()
        reloadGeneration = generation
        let scannedDirectory = self.outputDirectory()
        if scannedDirectory != loadedDirectory {
            rows = []
            metadataByPath = [:]
            clipCache = [:]
            loadedDirectory = scannedDirectory
            updateStorageSummary()
        }
        OutputDirectoryAccess.ensureAccessIfNeeded()
        guard let outputDirectory = self.outputDirectory() else {
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

        // Enrich + generate pre-decoded thumbnails for new/changed clips in parallel.
        let computed: [(key: String, info: ClipInfo, thumbnail: PredecodedThumbnailBox)] = await withTaskGroup(
            of: (key: String, info: ClipInfo, thumbnail: PredecodedThumbnailBox).self
        ) { group in
            for info in misses {
                let key = Self.cacheKey(for: info)
                group.addTask {
                    let enriched = await ClipMetadata.enrichClipInfo(info)
                    let thumbnail = await Self.predecodedThumbnail(for: enriched.fileURL)
                    return (key: key, info: enriched, thumbnail: thumbnail)
                }
            }

            var collected: [(key: String, info: ClipInfo, thumbnail: PredecodedThumbnailBox)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        if Task.isCancelled || reloadGeneration != generation || self.outputDirectory() != scannedDirectory { return }

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
                thumbnail: entry.thumbnail.image.map {
                    NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                }
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
        guard !isProtected(row.info.fileURL) else { return }
        do {
            try FileManager.default.trashItem(at: row.info.fileURL, resultingItemURL: nil)
            rows.removeAll(where: { $0.id == row.id })
            metadataByPath.removeValue(forKey: ClipLibraryMetadataStore.key(for: row.info.fileURL))
            persistMetadata()
            updateStorageSummary()
        } catch {
            ClipLibraryMetadataStore.logger.error("Failed to delete clip: \(String(describing: error), privacy: .public)")
        }
    }

    func delete(_ rowsToDelete: [ClipRow]) async {
        let rowsToDelete = rowsToDelete.filter { !isProtected($0.info.fileURL) }
        let ids = Set(rowsToDelete.map(\.id))
        for row in rowsToDelete {
            do {
                try FileManager.default.trashItem(at: row.info.fileURL, resultingItemURL: nil)
                metadataByPath.removeValue(forKey: ClipLibraryMetadataStore.key(for: row.info.fileURL))
            } catch {
                ClipLibraryMetadataStore.logger.error("Failed to delete clip: \(String(describing: error), privacy: .public)")
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
        guard !isProtected(row.info.fileURL) else { return nil }
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
            ClipLibraryMetadataStore.logger.error("Failed to rename clip: \(String(describing: error), privacy: .public)")
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

        for row in candidates where !isProtected(row.info.fileURL) {
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
        OutputDirectoryAccess.ensureAccessIfNeeded()
        guard let outputDirectory = loadedDirectory, outputDirectory == self.outputDirectory() else { return }
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
}

private extension DateFormatter {
    static let clipLibraryDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let clipGridDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdhm")
        return formatter
    }()
}
