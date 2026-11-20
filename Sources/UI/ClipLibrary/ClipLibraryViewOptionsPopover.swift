import SwiftUI
import Defaults

struct ClipLibraryViewOptionsPopover: View {
    @Default(.clipLibraryLayout) private var layout
    @Default(.clipLibraryGroupMode) private var groupMode
    @Default(.clipLibrarySortMode) private var sortMode
    @Default(.clipLibrarySortDirection) private var sortDirection
    @Default(.clipLibrarySortFavoritesFirst) private var favoritesFirst
    @Default(.clipLibraryDateFormat) private var dateFormat
    @Default(.clipLibraryGridCardWidth) private var gridCardWidth
    @Default(.clipLibraryGridShowTagBadges) private var showTagBadges
    @Default(.clipLibraryGridShowDurationBadge) private var showDurationBadge
    @Default(.clipLibraryGridShowFavoriteBadge) private var showFavoriteBadge
    @Default(.clipLibraryGridSubtitleFields) private var gridSubtitleFields
    @Default(.clipLibraryTableDensity) private var tableDensity
    @Default(.clipLibraryVisibleColumns) private var visibleColumns

    private let twoColumns = [
        GridItem(.flexible(), alignment: .leading),
        GridItem(.flexible(), alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("View Options")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button("Reset") {
                    ClipLibraryViewOptions.resetToDefaults()
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .help("Restore default view options")
            }

            Divider()

            sectionHeader("Organization")
            VStack(alignment: .leading, spacing: 8) {
                labeledPicker("Group by", selection: $groupMode) {
                    ForEach(ClipGroupMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                labeledPicker("Sort by", selection: sortModeBinding) {
                    ForEach(ClipSortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                labeledPicker("Order", selection: $sortDirection) {
                    Text(sortMode.directionLabel(for: .descending)).tag(ClipSortDirection.descending)
                    Text(sortMode.directionLabel(for: .ascending)).tag(ClipSortDirection.ascending)
                }

                Toggle("Keep favorites first", isOn: $favoritesFirst)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, design: .rounded))
            }

            Divider()

            sectionHeader("Dates")
            labeledPicker("Format", selection: $dateFormat) {
                ForEach(ClipDateFormatStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            Divider()

            if layout == .grid {
                gridOptionsSection
            } else {
                listOptionsSection
            }
        }
        .padding(14)
        .frame(width: 304, alignment: .leading)
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
    }

    private var gridOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Grid Display")

            HStack(spacing: 8) {
                Text("Card size")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 66, alignment: .leading)
                Slider(value: $gridCardWidth, in: ClipGridMetrics.cardWidthRange)
                    .controlSize(.small)
                Text("\(Int(gridCardWidth))pt")
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 36, alignment: .trailing)
            }

            Text("Thumbnail overlays")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)

            LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 6) {
                Toggle("Tags", isOn: $showTagBadges)
                Toggle("Duration", isOn: $showDurationBadge)
                Toggle("Favorite star", isOn: $showFavoriteBadge)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12, design: .rounded))

            Text("Card subtitle")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)

            LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 6) {
                ForEach(ClipGridSubtitleField.allCases) { field in
                    Toggle(field.title, isOn: subtitleFieldBinding(field))
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12, design: .rounded))
        }
    }

    private var listOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("List Display")

            labeledPicker("Density", selection: $tableDensity) {
                ForEach(ClipTableDensity.allCases) { density in
                    Text(density.title).tag(density)
                }
            }

            Text("Visible columns")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)

            LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 6) {
                ForEach(ClipTableColumn.allCases) { column in
                    Toggle(column.title, isOn: columnBinding(column))
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12, design: .rounded))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.textSecondary)
    }

    private func labeledPicker<SelectionValue: Hashable, Content: View>(
        _ label: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 66, alignment: .leading)
            Picker(label, selection: selection) {
                content()
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sortModeBinding: Binding<ClipSortMode> {
        Binding(
            get: { sortMode },
            set: { newMode in
                guard newMode != sortMode else { return }
                sortMode = newMode
                sortDirection = newMode.defaultDirection
            }
        )
    }

    private func subtitleFieldBinding(_ field: ClipGridSubtitleField) -> Binding<Bool> {
        Binding(
            get: { gridSubtitleFields.contains(field) },
            set: { enabled in
                if enabled {
                    gridSubtitleFields.insert(field)
                } else {
                    gridSubtitleFields.remove(field)
                }
            }
        )
    }

    private func columnBinding(_ column: ClipTableColumn) -> Binding<Bool> {
        Binding(
            get: { visibleColumns.contains(column) },
            set: { enabled in
                if enabled {
                    visibleColumns.insert(column)
                } else {
                    visibleColumns.remove(column)
                }
            }
        )
    }
}
