import SwiftUI
import AppKit

extension ClipLibraryView {
    // MARK: Grid

    var gridSizeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 9))
            Slider(value: $gridCardWidth, in: ClipGridMetrics.cardWidthRange)
                .controlSize(.mini)
                .frame(width: 96)
                .accessibilityLabel("Thumbnail size")
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 12))
        }
        .foregroundStyle(AppTheme.textSecondary)
        .help("Thumbnail size")
    }

    /// As many columns as fit at the chosen card width; flexible items then
    /// stretch the cards so each row fills the window edge to edge.
    private var gridColumnCount: Int {
        let cardWidth = CGFloat(gridCardWidth)
        let available = max(gridWidth - ClipGridMetrics.padding * 2, cardWidth)
        return max(1, Int((available + ClipGridMetrics.spacing) / (cardWidth + ClipGridMetrics.spacing)))
    }

    /// Width of each card's 16:9 thumbnail, computed once from the grid's width
    /// so individual cards don't need their own geometry observers while scrolling.
    private var gridThumbnailWidth: CGFloat {
        let columns = CGFloat(gridColumnCount)
        let available = max(gridWidth - ClipGridMetrics.padding * 2, CGFloat(gridCardWidth))
        let cardWidth = (available - ClipGridMetrics.spacing * (columns - 1)) / columns
        return max(cardWidth - 12, 1)
    }

    var gridView: some View {
        let sections = visibleSections
        let expandedItems = sections.flatMap { state.isSectionCollapsed($0.id) ? [] : $0.items }
        let columnCount = gridColumnCount
        let thumbnailWidth = gridThumbnailWidth
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: ClipGridMetrics.spacing, alignment: .top),
            count: columnCount
        )
        let displayOptions = gridDisplayOptions

        return ScrollViewReader { proxy in
            ScrollView {
                if groupMode == .none {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: ClipGridMetrics.spacing) {
                        ForEach(sections.first?.items ?? []) { item in
                            gridCard(
                                for: item,
                                in: expandedItems,
                                thumbnailWidth: thumbnailWidth,
                                displayOptions: displayOptions
                            )
                        }
                    }
                    .padding(ClipGridMetrics.padding)
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(sections) { section in
                            let isCollapsed = state.isSectionCollapsed(section.id)
                            VStack(alignment: .leading, spacing: 10) {
                                gridSectionHeader(for: section, isCollapsed: isCollapsed)
                                if !isCollapsed {
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: ClipGridMetrics.spacing) {
                                        ForEach(section.items) { item in
                                            gridCard(
                                                for: item,
                                                in: expandedItems,
                                                thumbnailWidth: thumbnailWidth,
                                                displayOptions: displayOptions
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(ClipGridMetrics.padding)
                }
            }
            .background {
                // Clicking between cards clears the selection, as in Finder.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.selection = []
                        gridFocused = true
                    }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(phases: .down) { press in
                handleGridKey(press, items: expandedItems, columnCount: columnCount, proxy: proxy)
            }
            .onDeleteCommand {
                requestDelete(selectedRows)
            }
        }
    }

    private func gridSectionHeader(for section: ClipSection, isCollapsed: Bool) -> some View {
        let countLabel = section.clipCount == 1 ? "1 clip" : "\(section.clipCount) clips"
        let sizeLabel = ByteCountFormatter.string(fromByteCount: section.totalBytes, countStyle: .file)

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                state.toggleSection(section.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 12)

                if let icon = section.systemImage {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(section.id == "fav:yes" ? .yellow : AppTheme.accent)
                }

                Text(section.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("\(countLabel) · \(sizeLabel)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppTheme.backgroundSecondary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.title), \(countLabel), \(isCollapsed ? "collapsed" : "expanded")")
    }

    private func gridCard(
        for item: ClipSectionItem,
        in expandedItems: [ClipSectionItem],
        thumbnailWidth: CGFloat,
        displayOptions: ClipGridDisplayOptions
    ) -> some View {
        let row = item.row
        return ClipGridCard(
            row: row,
            isSelected: state.selection.contains(item.clipID),
            isProtected: windowState.isProtected(row.info.fileURL),
            thumbnailWidth: thumbnailWidth,
            displayOptions: displayOptions,
            actions: ClipGridCardActions(
                toggleFavorite: {
                    model.toggleFavorite(row)
                    if state.selection.contains(row.id) {
                        syncDraftFromSelection()
                    }
                },
                preview: { state.previewURL = row.info.fileURL },
                trim: { openTrim(row.info.fileURL) },
                editInfo: { editInfo(for: row) },
                copyFile: { copyFile(row.info.fileURL) },
                delete: { requestDelete([row]) }
            )
        )
        .id(item.id)
        .onTapGesture { handleGridClick(on: item, in: expandedItems) }
        .contextMenu { clipContextMenu(for: contextTargets(for: row)) }
        // Drag a clip straight into Finder, Messages, Discord, and so on.
        .onDrag { NSItemProvider(contentsOf: row.info.fileURL) ?? NSItemProvider() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.displayTitle)
        .accessibilityValue("\(row.durationLabel), \(row.sizeLabel), \(row.dateLabel)\(row.userMetadata.isFavorite ? ", favorite" : "")")
        .accessibilityAddTraits(state.selection.contains(row.id) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectOnly(item) }
        .accessibilityAction(named: "Quick Preview") { state.previewURL = row.info.fileURL }
        .accessibilityAction(named: "Trim & Export") { openTrim(row.info.fileURL) }
        .accessibilityAction(named: row.userMetadata.isFavorite ? "Remove Favorite" : "Mark Favorite") {
            model.toggleFavorite(row)
        }
    }

    /// Right-clicking inside the selection acts on all of it; anywhere else
    /// acts on just that clip.
    private func contextTargets(for row: ClipRow) -> [ClipRow] {
        state.selection.contains(row.id) ? selectedRows : [row]
    }

    func selectOnly(_ row: ClipRow) {
        state.selection = [row.id]
        if let firstItem = visibleSections.flatMap(\.items).first(where: { $0.clipID == row.id }) {
            gridAnchorID = firstItem.id
            gridCursorID = firstItem.id
        } else {
            gridAnchorID = nil
            gridCursorID = nil
        }
    }

    private func selectOnly(_ item: ClipSectionItem) {
        state.selection = [item.clipID]
        gridAnchorID = item.id
        gridCursorID = item.id
    }

    /// Finder-style clicks: plain selects one, Command toggles, Shift extends
    /// from the anchor, and a double-click opens Quick Preview.
    private func handleGridClick(on item: ClipSectionItem, in items: [ClipSectionItem]) {
        gridFocused = true
        if NSApp.currentEvent?.clickCount == 2 {
            selectOnly(item)
            state.previewURL = item.row.info.fileURL
            return
        }

        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if state.selection.contains(item.clipID) {
                state.selection.remove(item.clipID)
            } else {
                state.selection.insert(item.clipID)
            }
            gridAnchorID = item.id
            gridCursorID = item.id
        } else if modifiers.contains(.shift),
                  let anchorID = gridAnchorID,
                  let anchorItem = items.first(where: { $0.id == anchorID }),
                  state.selection.contains(anchorItem.clipID) {
            selectRange(from: anchorID, to: item.id, in: items)
            gridCursorID = item.id
        } else {
            selectOnly(item)
        }
    }

    private func selectRange(from anchorID: ClipSectionItem.ID, to targetID: ClipSectionItem.ID, in items: [ClipSectionItem]) {
        guard let start = items.firstIndex(where: { $0.id == anchorID }),
              let end = items.firstIndex(where: { $0.id == targetID }) else { return }
        state.selection = Set(items[min(start, end)...max(start, end)].map(\.clipID))
    }

    private func handleGridKey(
        _ press: KeyPress,
        items: [ClipSectionItem],
        columnCount: Int,
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let extend = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow:
            moveGridCursor(by: -1, extend: extend, items: items, proxy: proxy)
        case .rightArrow:
            moveGridCursor(by: 1, extend: extend, items: items, proxy: proxy)
        case .upArrow:
            moveGridCursor(by: -columnCount, extend: extend, items: items, proxy: proxy)
        case .downArrow:
            moveGridCursor(by: columnCount, extend: extend, items: items, proxy: proxy)
        case .space, .return:
            guard let row = singleSelectedRow else { return .ignored }
            state.previewURL = row.info.fileURL
        case .escape:
            guard !state.selection.isEmpty else { return .ignored }
            state.selection = []
        default:
            guard press.modifiers.contains(.command), press.characters == "a" else { return .ignored }
            state.selection = Set(items.map(\.clipID))
        }
        return .handled
    }

    private func moveGridCursor(by offset: Int, extend: Bool, items: [ClipSectionItem], proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        let target: Int
        if let cursorID = gridCursorID,
           let current = items.firstIndex(where: { $0.id == cursorID }),
           state.selection.contains(items[current].clipID) {
            target = min(max(current + offset, 0), items.count - 1)
        } else {
            target = offset < 0 ? items.count - 1 : 0
        }

        let item = items[target]
        if extend,
           let anchorID = gridAnchorID,
           let anchorItem = items.first(where: { $0.id == anchorID }),
           state.selection.contains(anchorItem.clipID) {
            selectRange(from: anchorID, to: item.id, in: items)
            gridCursorID = item.id
        } else {
            selectOnly(item)
        }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(item.id)
        }
    }
}
