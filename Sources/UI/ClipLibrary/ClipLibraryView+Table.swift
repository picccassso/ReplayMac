import SwiftUI
import AppKit

extension ClipLibraryView {
    var tableView: some View {
        Table(visibleRows, selection: $state.selection) {
            TableColumn("") { row in
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
            .width(min: 200, ideal: 240)

            TableColumn("Tags") { row in
                Text(row.tagsLabel)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(row.userMetadata.tags.isEmpty ? AppTheme.textSecondary : AppTheme.accent)
            }
            .width(min: 70, ideal: 82)

            TableColumn("Duration") { row in
                Text(row.durationLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .width(64)

            TableColumn("Size") { row in
                Text(row.sizeLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .width(64)

            TableColumn("Created") { row in
                Text(row.dateLabel)
                    .lineLimit(1)
                    .help(row.dateLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .width(112)

            TableColumn("Actions") { row in
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
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(
            AppTheme.atmosphere == .native && AppTheme.surfaceStyle == .glass ? .automatic : .hidden
        )
        .contextMenu(forSelectionType: ClipRow.ID.self) { ids in
            clipContextMenu(for: rows(for: ids))
        } primaryAction: { ids in
            if let row = rows(for: ids).first {
                state.previewURL = row.info.fileURL
            }
        }
        .onDeleteCommand {
            requestDelete(selectedRows)
        }
    }

    private func rows(for ids: Set<ClipRow.ID>) -> [ClipRow] {
        model.rows.filter { ids.contains($0.id) }
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
