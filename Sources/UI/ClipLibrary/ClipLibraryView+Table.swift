import SwiftUI
import AppKit

private extension ClipSectionItem {
    var sortTitle: String { row.displayTitle }
    var sortDuration: Double { row.info.duration.isFinite ? row.info.duration : -1 }
    var sortSize: Int64 { row.info.fileSize }
    var sortDate: Date { row.info.creationDate }
}

extension ClipLibraryView {
    var tableView: some View {
        let sections = visibleSections
        let allItems = sections.flatMap(\.items)
        let itemsByID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        let density = tableDensity
        let currentDateFormat = dateFormat

        return Table(
            of: ClipSectionItem.self,
            selection: tableSelectionBinding(allItems: allItems, itemsByID: itemsByID),
            sortOrder: tableSortOrderBinding
        ) {
            if visibleColumns.contains(.favorite) {
                TableColumn("") { item in
                    let row = item.row
                    Button {
                        model.toggleFavorite(row)
                        if state.selection.contains(row.id) {
                            syncDraftFromSelection()
                        }
                    } label: {
                        Image(systemName: row.userMetadata.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(row.userMetadata.isFavorite ? .yellow : AppTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(row.userMetadata.isFavorite ? "Remove favorite" : "Mark favorite")
                }
                .width(28)
            }

            TableColumn("Clip", value: \.sortTitle) { item in
                let row = item.row
                HStack(spacing: density == .compact ? 9 : 12) {
                    ClipThumbnailView(image: row.thumbnail, size: density.thumbnailSize)
                    VStack(alignment: .leading, spacing: density == .compact ? 1 : 3) {
                        Text(row.displayTitle)
                            .lineLimit(1)
                            .font(.system(size: density.titleFontSize, weight: .medium, design: .rounded))
                        Text(row.fileName)
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textSecondary)
                            .font(.system(size: density.subtitleFontSize, weight: .regular, design: .rounded))
                    }
                }
                .padding(.vertical, density == .compact ? 1 : (density == .spacious ? 4 : 2))
            }
            .width(min: 200, ideal: 250)

            if visibleColumns.contains(.tags) {
                TableColumn("Tags") { item in
                    let row = item.row
                    Text(row.tagsLabel)
                        .lineLimit(1)
                        .font(.system(size: density.cellFontSize, weight: .medium, design: .rounded))
                        .foregroundStyle(row.userMetadata.tags.isEmpty ? AppTheme.textSecondary : AppTheme.accent)
                }
                .width(min: 70, ideal: 96)
            }

            if visibleColumns.contains(.duration) {
                TableColumn("Duration", value: \.sortDuration) { item in
                    Text(item.row.durationLabel)
                        .font(.system(size: density.cellFontSize, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .width(68)
            }

            if visibleColumns.contains(.size) {
                TableColumn("Size", value: \.sortSize) { item in
                    Text(item.row.sizeLabel)
                        .font(.system(size: density.cellFontSize, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .width(68)
            }

            if visibleColumns.contains(.resolution) {
                TableColumn("Resolution") { item in
                    Text(item.row.resolutionLabel ?? "—")
                        .font(.system(size: density.cellFontSize, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .width(86)
            }

            if visibleColumns.contains(.created) {
                TableColumn("Created", value: \.sortDate) { item in
                    let dateText = ClipLibraryFormatter.formatDate(
                        item.row.info.creationDate,
                        style: currentDateFormat,
                        compact: false
                    )
                    Text(dateText)
                        .lineLimit(1)
                        .help(item.row.dateLabel)
                        .font(.system(size: density.cellFontSize, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .width(min: 112, ideal: 132)
            }

            if visibleColumns.contains(.notes) {
                TableColumn("Notes") { item in
                    let notes = item.row.userMetadata.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(notes.isEmpty ? "—" : notes)
                        .lineLimit(1)
                        .help(notes)
                        .font(.system(size: density.cellFontSize, weight: .regular, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .width(min: 90, ideal: 150)
            }

            TableColumn("Actions") { item in
                let row = item.row
                HStack(spacing: 10) {
                    IconActionButton(icon: "play.fill", color: AppTheme.accent) {
                        state.previewURL = row.info.fileURL
                    }
                    .help("Quick preview")

                    IconActionButton(icon: "scissors", color: AppTheme.accentSecondary) {
                        openTrim(row.info.fileURL)
                    }
                    .help("Trim & Export")

                    ClipShareLink(url: row.info.fileURL)

                    Menu {
                        Button("Edit Info…", systemImage: "info.circle") { editInfo(for: row) }
                        Button("Copy File", systemImage: "doc.on.doc") { copyFile(row.info.fileURL) }
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([row.info.fileURL])
                        }
                        Divider()
                        Button("Delete Clip", systemImage: "trash", role: .destructive) { requestDelete([row]) }
                            .disabled(windowState.isProtected(row.info.fileURL))
                    } label: {
                        IconActionLabel(icon: "ellipsis", color: AppTheme.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More clip actions")
                    .accessibilityLabel("More actions for \(row.displayTitle)")
                }
            }
            .width(164)
        } rows: {
            if groupMode == .none {
                ForEach(sections.first?.items ?? []) { item in
                    TableRow(item)
                }
            } else {
                ForEach(sections) { section in
                    Section(isExpanded: sectionExpandedBinding(for: section.id)) {
                        ForEach(section.items) { item in
                            TableRow(item)
                        }
                    } header: {
                        tableSectionHeader(for: section)
                    }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(
            AppTheme.atmosphere == .native && AppTheme.surfaceStyle == .glass ? .automatic : .hidden
        )
        .contextMenu(forSelectionType: ClipSectionItem.ID.self) { ids in
            clipContextMenu(for: uniqueRows(for: ids, itemsByID: itemsByID))
        } primaryAction: { ids in
            if let row = uniqueRows(for: ids, itemsByID: itemsByID).first {
                state.previewURL = row.info.fileURL
            }
        }
        .onDeleteCommand {
            requestDelete(selectedRows)
        }
    }

    private func tableSectionHeader(for section: ClipSection) -> some View {
        let countLabel = section.clipCount == 1 ? "1 clip" : "\(section.clipCount) clips"
        let sizeLabel = ByteCountFormatter.string(fromByteCount: section.totalBytes, countStyle: .file)
        return HStack(spacing: 6) {
            if let icon = section.systemImage {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(section.id == "fav:yes" ? .yellow : AppTheme.accent)
            }
            Text(section.title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
            Text("· \(countLabel) · \(sizeLabel)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func sectionExpandedBinding(for sectionID: String) -> Binding<Bool> {
        Binding(
            get: { !state.isSectionCollapsed(sectionID) },
            set: { expanded in
                if expanded {
                    state.collapsedSections.remove(sectionID)
                } else {
                    state.collapsedSections.insert(sectionID)
                }
            }
        )
    }

    private func tableSelectionBinding(
        allItems: [ClipSectionItem],
        itemsByID: [String: ClipSectionItem]
    ) -> Binding<Set<ClipSectionItem.ID>> {
        Binding(
            get: {
                Set(allItems.filter { state.selection.contains($0.clipID) }.map(\.id))
            },
            set: { newItemIDs in
                let oldItemIDs = Set(allItems.filter { state.selection.contains($0.clipID) }.map(\.id))
                let addedClips = Set(newItemIDs.subtracting(oldItemIDs).compactMap { itemsByID[$0]?.clipID })
                let removedClips = Set(oldItemIDs.subtracting(newItemIDs).compactMap { itemsByID[$0]?.clipID })
                var updated = state.selection
                updated.subtract(removedClips)
                updated.formUnion(addedClips)
                state.selection = updated
            }
        )
    }

    private var tableSortOrderBinding: Binding<[KeyPathComparator<ClipSectionItem>]> {
        Binding(
            get: {
                let order: SortOrder = sortDirection == .ascending ? .forward : .reverse
                switch sortMode {
                case .date:
                    return [KeyPathComparator(\ClipSectionItem.sortDate, order: order)]
                case .name:
                    return [KeyPathComparator(\ClipSectionItem.sortTitle, comparator: .localizedStandard, order: order)]
                case .duration:
                    return [KeyPathComparator(\ClipSectionItem.sortDuration, order: order)]
                case .size:
                    return [KeyPathComparator(\ClipSectionItem.sortSize, order: order)]
                }
            },
            set: { newOrder in
                guard let comparator = newOrder.first else { return }
                let newDirection: ClipSortDirection = comparator.order == .forward ? .ascending : .descending
                switch comparator.keyPath {
                case \ClipSectionItem.sortDate:
                    sortMode = .date
                case \ClipSectionItem.sortTitle:
                    sortMode = .name
                case \ClipSectionItem.sortDuration:
                    sortMode = .duration
                case \ClipSectionItem.sortSize:
                    sortMode = .size
                default:
                    return
                }
                sortDirection = newDirection
            }
        )
    }

    private func uniqueRows(
        for itemIDs: Set<ClipSectionItem.ID>,
        itemsByID: [String: ClipSectionItem]
    ) -> [ClipRow] {
        var seen = Set<String>()
        var result: [ClipRow] = []
        for id in itemIDs {
            guard let item = itemsByID[id], seen.insert(item.clipID).inserted else { continue }
            result.append(item.row)
        }
        return result
    }
}

private struct ClipThumbnailView: View {
    let image: NSImage?
    let size: CGSize

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
        .frame(width: size.width, height: size.height)
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

    @Environment(\.accessibilityShowBorders) private var showBorders
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
            .overlay {
                if showBorders {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
