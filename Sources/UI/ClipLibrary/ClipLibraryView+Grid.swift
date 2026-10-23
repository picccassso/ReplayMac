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
        let rows = visibleRows
        let columnCount = gridColumnCount
        let thumbnailWidth = gridThumbnailWidth
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: ClipGridMetrics.spacing, alignment: .top),
            count: columnCount
        )
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: ClipGridMetrics.spacing) {
                    ForEach(rows) { row in
                        gridCard(for: row, in: rows, thumbnailWidth: thumbnailWidth)
                    }
                }
                .padding(ClipGridMetrics.padding)
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
                handleGridKey(press, rows: rows, columnCount: columnCount, proxy: proxy)
            }
            .onDeleteCommand {
                requestDelete(selectedRows)
            }
        }
    }

    private func gridCard(for row: ClipRow, in rows: [ClipRow], thumbnailWidth: CGFloat) -> some View {
        ClipGridCard(
            row: row,
            isSelected: state.selection.contains(row.id),
            isProtected: windowState.isProtected(row.info.fileURL),
            thumbnailWidth: thumbnailWidth,
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
        .id(row.id)
        .onTapGesture { handleGridClick(on: row, in: rows) }
        .contextMenu { clipContextMenu(for: contextTargets(for: row)) }
        // Drag a clip straight into Finder, Messages, Discord, and so on.
        .onDrag { NSItemProvider(contentsOf: row.info.fileURL) ?? NSItemProvider() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.displayTitle)
        .accessibilityValue("\(row.durationLabel), \(row.sizeLabel), \(row.dateLabel)\(row.userMetadata.isFavorite ? ", favorite" : "")")
        .accessibilityAddTraits(state.selection.contains(row.id) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectOnly(row) }
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
        gridAnchorID = row.id
        gridCursorID = row.id
    }

    /// Finder-style clicks: plain selects one, Command toggles, Shift extends
    /// from the anchor, and a double-click opens Quick Preview.
    private func handleGridClick(on row: ClipRow, in rows: [ClipRow]) {
        gridFocused = true
        if NSApp.currentEvent?.clickCount == 2 {
            selectOnly(row)
            state.previewURL = row.info.fileURL
            return
        }

        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if state.selection.contains(row.id) {
                state.selection.remove(row.id)
            } else {
                state.selection.insert(row.id)
            }
            gridAnchorID = row.id
            gridCursorID = row.id
        } else if modifiers.contains(.shift), let anchorID = gridAnchorID, state.selection.contains(anchorID) {
            selectRange(from: anchorID, to: row.id, in: rows)
            gridCursorID = row.id
        } else {
            selectOnly(row)
        }
    }

    private func selectRange(from anchorID: ClipRow.ID, to targetID: ClipRow.ID, in rows: [ClipRow]) {
        guard let start = rows.firstIndex(where: { $0.id == anchorID }),
              let end = rows.firstIndex(where: { $0.id == targetID }) else { return }
        state.selection = Set(rows[min(start, end)...max(start, end)].map(\.id))
    }

    private func handleGridKey(
        _ press: KeyPress,
        rows: [ClipRow],
        columnCount: Int,
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let extend = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow:
            moveGridCursor(by: -1, extend: extend, rows: rows, proxy: proxy)
        case .rightArrow:
            moveGridCursor(by: 1, extend: extend, rows: rows, proxy: proxy)
        case .upArrow:
            moveGridCursor(by: -columnCount, extend: extend, rows: rows, proxy: proxy)
        case .downArrow:
            moveGridCursor(by: columnCount, extend: extend, rows: rows, proxy: proxy)
        case .space, .return:
            guard let row = singleSelectedRow else { return .ignored }
            state.previewURL = row.info.fileURL
        case .escape:
            guard !state.selection.isEmpty else { return .ignored }
            state.selection = []
        default:
            guard press.modifiers.contains(.command), press.characters == "a" else { return .ignored }
            state.selection = Set(rows.map(\.id))
        }
        return .handled
    }

    private func moveGridCursor(by offset: Int, extend: Bool, rows: [ClipRow], proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let target: Int
        if let cursorID = gridCursorID, state.selection.contains(cursorID),
           let current = rows.firstIndex(where: { $0.id == cursorID }) {
            target = min(max(current + offset, 0), rows.count - 1)
        } else {
            target = offset < 0 ? rows.count - 1 : 0
        }

        let row = rows[target]
        if extend, let anchorID = gridAnchorID, state.selection.contains(anchorID) {
            selectRange(from: anchorID, to: row.id, in: rows)
            gridCursorID = row.id
        } else {
            selectOnly(row)
        }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(row.id)
        }
    }
}
