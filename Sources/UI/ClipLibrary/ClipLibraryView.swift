import SwiftUI
import AppKit
import Save
import UniformTypeIdentifiers
import Defaults

public struct ClipLibraryView: View {
    @Default(.outputDirectoryPath) private var outputDirectoryPath
    @Default(.clipLibraryLayout) private var layout
    @Default(.clipLibraryGridCardWidth) var gridCardWidth
    @ObservedObject var state: ClipLibraryState
    @ObservedObject var model: ClipLibraryViewModel
    @ObservedObject var windowState: MainWindowState

    @State var gridWidth: CGFloat = 0
    /// Where shift-click and shift-arrow ranges start in the grid.
    @State var gridAnchorID: ClipRow.ID?
    /// The card arrow keys move from.
    @State var gridCursorID: ClipRow.ID?
    @FocusState var gridFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panelAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.26)
    }

    public init(windowState: MainWindowState) {
        self.windowState = windowState
        self.state = windowState.library
        self.model = windowState.library.model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !model.rows.isEmpty {
                librarySummaryHeader
                Divider()
            }
            if visibleRows.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layout == .grid {
                gridView
            } else {
                tableView
            }
        }
        // Thumbnails read fine under the glass bar, so the grid skips the
        // system's dimmed band behind it; the table keeps it for its text rows.
        .floatingBottomBar(scrollEdgeEffect: layout != .grid) { selectionPanel }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .replayCapLibraryShouldReload)) { _ in
            Task { await model.reload() }
        }
        .onChange(of: outputDirectoryPath) { _, _ in
            state.selection = []
            state.isDetailsExpanded = false
            state.metadataDraft = .empty
            state.renameDraft = ""
            Task { await model.reload() }
        }
        .onChange(of: windowState.page) { _, page in
            if page == .library { Task { await model.reload() } }
        }
        .onChange(of: model.rows.map(\.id)) { _, _ in pruneSelectionToExistingRows() }
        .onChange(of: state.selection) { _, selection in
            if selection.isEmpty {
                state.isDetailsExpanded = false
            }
            syncDraftFromSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .replayCapClipSaved)) { _ in
            Task { await model.reload() }
        }
        .alert("Delete Clip?", isPresented: deleteAlertBinding, presenting: state.deleteCandidate) { row in
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete(row)
                    state.selection.remove(row.id)
                    state.deleteCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) {
                state.deleteCandidate = nil
            }
        } message: { row in
            Text("Move \(row.fileName) to Trash?")
        }
        .alert("Delete \(selectedRows.count) Clips?", isPresented: $state.bulkDeletePresented) {
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
            if let previewURL = state.previewURL {
                ClipPreviewView(url: previewURL) {
                    state.previewURL = nil
                }
            }
        }
        .sheet(isPresented: $state.cleanupSheetPresented) {
            VStack(spacing: 0) {
                if !windowState.editors.isEmpty || windowState.exports.isBusy {
                    Text("Clips currently being edited or exported are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 16)
                }
                ClipCleanupView(summary: model.storageSummary) { action in
                    Task {
                        await model.cleanup(action)
                        pruneSelectionToExistingRows()
                        state.cleanupSheetPresented = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectionPanel: some View {
        Group {
            if state.selection.count > 1 {
                panel { batchBarView(for: selectedRows) }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else if let row = singleSelectedRow {
                panel { bottomBarView(for: row) }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(panelAnimation, value: state.selection.isEmpty)
        .animation(panelAnimation, value: state.selection.count > 1)
        .animation(panelAnimation, value: state.isDetailsExpanded)
    }

    /// Selection details float over the library as a compact glass bar. Its own
    /// buttons stay bordered, since glass controls on glass lose contrast.
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 820)
            .glassPanel()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .buttonStyle(.bordered)
    }

    private var librarySummaryHeader: some View {
        HStack(spacing: 8) {
            let summary = model.storageSummary
            let clips = summary.clipCount == 1 ? "1 clip" : "\(summary.clipCount) clips"
            let size = ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)

            if state.favoritesOnly {
                let filteredCount = visibleRows.count
                let filteredBytes = visibleRows.reduce(Int64(0)) { $0 + $1.info.fileSize }
                let filteredSize = ByteCountFormatter.string(fromByteCount: filteredBytes, countStyle: .file)
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow)
                Text("\(filteredCount) favorites · \(filteredSize)")
                    .foregroundStyle(AppTheme.textPrimary)
                Text("(\(clips) · \(size) total)")
                    .foregroundStyle(AppTheme.textSecondary)
            } else if !state.searchText.isEmpty {
                let filteredCount = visibleRows.count
                let filteredBytes = visibleRows.reduce(Int64(0)) { $0 + $1.info.fileSize }
                let filteredSize = ByteCountFormatter.string(fromByteCount: filteredBytes, countStyle: .file)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.accent)
                Text("\(filteredCount) matching · \(filteredSize)")
                    .foregroundStyle(AppTheme.textPrimary)
                Text("(\(clips) · \(size) total)")
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.accent)
                Text("\(clips) · \(size)")
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            if layout == .grid {
                gridSizeSlider
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(AppTheme.backgroundSecondary.opacity(0.35))
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
                    .foregroundStyle(AppTheme.accentGradient)
            }

            VStack(spacing: 6) {
                Text(model.rows.isEmpty ? "No Clips Yet" : "No Matching Clips")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(model.rows.isEmpty ? "Saved clips will appear here." : "Try another search or turn off the favorites filter.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }


    @ViewBuilder
    func clipContextMenu(for targets: [ClipRow]) -> some View {
        if !targets.isEmpty {
            if let row = targets.first, targets.count == 1 {
                Button("Quick Preview") { state.previewURL = row.info.fileURL }
                Button("Trim & Export…") { openTrim(row.info.fileURL) }
                Button("Edit Info…") { editInfo(for: row) }
                Button("Copy File") { copyFile(row.info.fileURL) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.info.fileURL))
            }
            Divider()
            Button(targets.count == 1 ? "Delete Clip" : "Delete \(targets.count) Clips", role: .destructive) {
                requestDelete(targets)
            }
            .disabled(targets.contains { windowState.isProtected($0.info.fileURL) })
        }
    }


    /// Routes a delete request to the single- or bulk-confirmation alert.
    /// Selection is synced first so the bulk alert (which reads `selectedRows`)
    /// targets exactly what was right-clicked.
    func requestDelete(_ targets: [ClipRow]) {
        guard windowState.isLibraryFrontmost, !targets.isEmpty, !targets.contains(where: { windowState.isProtected($0.info.fileURL) }) else { return }
        if targets.count == 1 {
            state.deleteCandidate = targets[0]
        } else {
            state.selection = Set(targets.map(\.id))
            state.bulkDeletePresented = true
        }
    }

    func editInfo(for row: ClipRow) {
        selectOnly(row)
        state.isDetailsExpanded = true
    }

    private func bottomBarView(for row: ClipRow) -> some View {
        let isProtected = windowState.isProtected(row.info.fileURL)
        let isCopied = state.copiedFilePath == row.info.fileURL.path
        let hasMetadataBadge = !row.userMetadata.tags.isEmpty || !row.userMetadata.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    model.toggleFavorite(row)
                    syncDraftFromSelection()
                } label: {
                    Image(systemName: row.userMetadata.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(row.userMetadata.isFavorite ? .yellow : AppTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.userMetadata.isFavorite ? "Remove favorite" : "Mark favorite")
                .accessibilityLabel(row.userMetadata.isFavorite ? "Remove favorite" : "Mark favorite")

                HStack(spacing: 6) {
                    Text(row.displayTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !state.isDetailsExpanded, !row.userMetadata.tags.isEmpty {
                        Text(row.userMetadata.tags.count == 1 ? "1 tag" : "\(row.userMetadata.tags.count) tags")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.accent.opacity(0.12), in: Capsule())
                            .fixedSize()
                    }
                }

                Spacer(minLength: 8)

                Button {
                    state.previewURL = row.info.fileURL
                } label: {
                    Label("Preview", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .controlSize(.small)
                .help("Quick preview")

                Button {
                    openTrim(row.info.fileURL)
                } label: {
                    Label("Trim", systemImage: "scissors")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .controlSize(.small)
                .help("Trim or crop the clip, choose an audio track, and export as MP4 or GIF")

                Button {
                    exportWholeClipGIF(for: row)
                } label: {
                    HStack(spacing: 5) {
                        if windowState.exports.isBusy && windowState.exports.sourceURL == row.info.fileURL.standardizedFileURL {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "photo.stack")
                        }
                        Text("GIF")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .controlSize(.small)
                .disabled(windowState.exports.isBusy)
                .help("Export the whole clip as a looping GIF (no audio). Use Trim to choose a range or size.")

                Button {
                    copyFile(row.info.fileURL)
                } label: {
                    Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .controlSize(.small)
                .help(isCopied ? "Copied to clipboard" : "Copy file to clipboard")
                .accessibilityLabel(isCopied ? "Copied file" : "Copy file")

                ShareLink(item: row.info.fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .controlSize(.small)
                .help("Share clip")
                .accessibilityLabel("Share clip")

                Button {
                    state.isDetailsExpanded.toggle()
                } label: {
                    Label("Info", systemImage: state.isDetailsExpanded || hasMetadataBadge ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .controlSize(.small)
                .tint(state.isDetailsExpanded ? AppTheme.accent : nil)
                .help(state.isDetailsExpanded ? "Hide clip details" : "Rename clip or edit tags and notes")

                Button(role: .destructive) {
                    requestDelete([row])
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .controlSize(.small)
                .tint(AppTheme.danger)
                .disabled(isProtected)
                .help("Move this clip to Trash")
                .accessibilityLabel("Delete clip")

                Button {
                    state.selection = []
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear selection")
                .accessibilityLabel("Clear selection")
            }

            if state.isDetailsExpanded {
                Divider()

                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        TextField("Display title", text: $state.metadataDraft.displayName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveChanges(for: row) }

                        TextField("File name", text: $state.renameDraft)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isProtected)
                            .onSubmit { saveChanges(for: row) }
                    }

                    HStack(spacing: 10) {
                        TextField("Tags, comma separated", text: Binding(
                            get: { state.metadataDraft.tags.joined(separator: ", ") },
                            set: { state.metadataDraft.tags = Self.parseTags($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveChanges(for: row) }

                        TextField("Notes", text: $state.metadataDraft.notes)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveChanges(for: row) }

                        Button("Save") {
                            saveChanges(for: row)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .controlSize(.small)
                        .disabled(!hasUnsavedChanges(for: row))
                    }
                }
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
        }
    }

    private func batchBarView(for rows: [ClipRow]) -> some View {
        HStack(spacing: 8) {
            Text("\(rows.count) selected")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize()

            Button {
                model.setFavorite(rows, to: true)
            } label: {
                Label("Favorite", systemImage: "star.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .controlSize(.small)

            Button {
                model.setFavorite(rows, to: false)
            } label: {
                Label("Unfavorite", systemImage: "star.slash")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .controlSize(.small)

            ShareLink(items: rows.map(\.info.fileURL)) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .controlSize(.small)

            TextField("Add tag…", text: $state.bulkTagDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .frame(minWidth: 110, maxWidth: 180)
                .onSubmit { applyBulkTag(to: rows) }

            Button("Add") {
                applyBulkTag(to: rows)
            }
            .controlSize(.small)
            .disabled(state.bulkTagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer(minLength: 4)

            Button(role: .destructive) {
                requestDelete(rows)
            } label: {
                Label("Delete \(rows.count)", systemImage: "trash")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .controlSize(.small)
            .tint(AppTheme.danger)
            .disabled(rows.contains { windowState.isProtected($0.info.fileURL) })

            Button {
                state.selection = []
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clear selection")
            .accessibilityLabel("Clear selection")
        }
    }

    private func applyBulkTag(to rows: [ClipRow]) {
        let tag = state.bulkTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        model.addTag(tag, to: rows)
        state.bulkTagDraft = ""
    }

    var selectedRows: [ClipRow] {
        model.rows.filter { state.selection.contains($0.id) }
    }

    var singleSelectedRow: ClipRow? {
        guard state.selection.count == 1 else { return nil }
        return model.rows.first(where: { state.selection.contains($0.id) })
    }

    private func pruneSelectionToExistingRows() {
        state.selection = state.selection.filter { id in model.rows.contains(where: { $0.id == id }) }
    }

    var visibleRows: [ClipRow] {
        model.sortedRows(by: state.sortMode).filter { row in
            let matchesFavorite = !state.favoritesOnly || row.userMetadata.isFavorite
            let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard matchesFavorite, !query.isEmpty else {
                return matchesFavorite
            }
            return row.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    func syncDraftFromSelection() {
        guard let row = singleSelectedRow else {
            state.metadataDraft = .empty
            state.renameDraft = ""
            return
        }
        state.metadataDraft = row.userMetadata
        state.renameDraft = row.fileNameWithoutExtension
    }

    private func hasUnsavedChanges(for row: ClipRow) -> Bool {
        var draft = state.metadataDraft
        draft.isFavorite = row.userMetadata.isFavorite
        let metadataChanged = draft != row.userMetadata
        let trimmedRename = state.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let renameChanged = !windowState.isProtected(row.info.fileURL)
            && !trimmedRename.isEmpty
            && trimmedRename != row.fileNameWithoutExtension
        return metadataChanged || renameChanged
    }

    private func saveChanges(for row: ClipRow) {
        var metadata = state.metadataDraft
        metadata.isFavorite = row.userMetadata.isFavorite
        state.metadataDraft = metadata

        let trimmedRename = state.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let canRename = !windowState.isProtected(row.info.fileURL) && !trimmedRename.isEmpty
        if canRename, trimmedRename != row.fileNameWithoutExtension {
            let oldID = row.id
            if let newID = model.rename(row, to: trimmedRename, metadata: metadata) {
                state.selection = [newID]
            } else {
                state.selection = [oldID]
            }
            syncDraftFromSelection()
        } else {
            model.updateMetadata(for: row, metadata: metadata)
            syncDraftFromSelection()
        }
    }

    private func exportWholeClipGIF(for row: ClipRow) {
        let sourceURL = row.info.fileURL
        let end = row.info.duration.isFinite ? row.info.duration : 0
        guard end > 0 else { return }
        windowState.exports.start(source: sourceURL, title: "Exporting GIF") {
            let suggestedURL = GIFExporter.uniqueOutputURL(basedOn: sourceURL)
            guard let outputURL = await ExportDestinationPicker.chooseDestination(
                suggestedURL: suggestedURL, contentType: .gif, title: "Export GIF"
            ) else { return nil }
            return try await ClipExportCoordinator.write(source: sourceURL, destination: outputURL) { staged in
                try await GIFExporter.export(sourceURL: sourceURL, startSeconds: 0, endSeconds: end, to: staged)
            }
        }
    }

    func copyFile(_ url: URL) {
        guard ClipSharing.copyFileToPasteboard(url) else {
            return
        }

        let copiedPath = url.path
        state.copiedFilePath = copiedPath
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard state.copiedFilePath == copiedPath else { return }
            state.copiedFilePath = nil
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
            get: { state.deleteCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    state.deleteCandidate = nil
                }
            }
        )
    }

    private var previewSheetBinding: Binding<Bool> {
        Binding(
            get: { state.previewURL != nil },
            set: { isPresented in
                if !isPresented {
                    state.previewURL = nil
                }
            }
        )
    }

    func openTrim(_ url: URL) {
        windowState.openEditor(url)
    }

}

private enum ClipSharing {
    static func copyFileToPasteboard(_ url: URL) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([url as NSURL])
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
