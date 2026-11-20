import SwiftUI
import Defaults

/// Supplies the library's search field and actions to the window toolbar.
/// The library view itself stays alive behind other pages to keep its state,
/// so its toolbar comes from this separate view, which exists only while the
/// library is frontmost.
struct ClipLibraryToolbarHost: View {
    @ObservedObject var state: ClipLibraryState
    @ObservedObject var model: ClipLibraryViewModel
    @Default(.clipLibraryLayout) private var layout
    @Default(.clipLibraryGroupMode) private var groupMode
    @Default(.clipLibrarySortMode) private var sortMode
    @Default(.clipLibrarySortDirection) private var sortDirection
    @Default(.clipLibrarySortFavoritesFirst) private var favoritesFirst
    @Default(.clipLibraryFavoritesOnly) private var favoritesOnly
    @Default(.clipLibraryDateFilter) private var dateFilter
    @Default(.clipLibrarySelectedTags) private var selectedTags

    init(state: ClipLibraryState) {
        self.state = state
        self.model = state.model
    }

    private var hasActiveFilters: Bool {
        favoritesOnly || dateFilter != .all || !selectedTags.isEmpty
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search clips, tags, notes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: $layout) {
                        ForEach(ClipLibraryLayout.allCases) { layout in
                            Label(layout.title, systemImage: layout.systemImage).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Show clips as a list or a grid")
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Picker("Group By", selection: $groupMode) {
                            ForEach(ClipGroupMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.systemImage).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)

                        Divider()

                        Picker("Sort By", selection: sortModeBinding) {
                            ForEach(ClipSortMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)

                        Picker("Order", selection: $sortDirection) {
                            Text(sortMode.directionLabel(for: .descending)).tag(ClipSortDirection.descending)
                            Text(sortMode.directionLabel(for: .ascending)).tag(ClipSortDirection.ascending)
                        }
                        .pickerStyle(.inline)

                        Divider()

                        Toggle("Favorites First", isOn: $favoritesFirst)
                    } label: {
                        Label("Group & Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Group and sort clips")

                    Menu {
                        Toggle("Favorites Only", isOn: $favoritesOnly)

                        Divider()

                        Picker("Date Range", selection: $dateFilter) {
                            ForEach(ClipDateFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.inline)

                        Divider()

                        Menu("Tags") {
                            let tags = model.availableTags
                            if tags.isEmpty {
                                Text("No tags yet")
                            } else {
                                ForEach(tags, id: \.self) { tag in
                                    Toggle(tag, isOn: tagBinding(tag))
                                }
                                if !selectedTags.isEmpty {
                                    Divider()
                                    Button("Clear Selected Tags") {
                                        selectedTags = []
                                    }
                                }
                            }
                        }

                        if hasActiveFilters {
                            Divider()
                            Button("Clear All Filters") {
                                ClipLibraryViewOptions.resetFilters()
                            }
                        }
                    } label: {
                        Label(
                            "Filter",
                            systemImage: hasActiveFilters
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle"
                        )
                    }
                    .help(hasActiveFilters ? "Filter clips (active)" : "Filter clips")

                    Button {
                        state.viewOptionsPresented.toggle()
                    } label: {
                        Label("View Options", systemImage: "slider.horizontal.3")
                    }
                    .keyboardShortcut("j", modifiers: .command)
                    .help("Show View Options (⌘J)")
                    .popover(isPresented: $state.viewOptionsPresented, arrowEdge: .bottom) {
                        ClipLibraryViewOptionsPopover()
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Clean Up", systemImage: "externaldrive.badge.minus") {
                        state.cleanupSheetPresented = true
                    }
                    .disabled(model.rows.isEmpty)
                    .help("Move old clips to Trash")

                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.reload() }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Reload the clip folder")
                }
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

    private func tagBinding(_ tag: String) -> Binding<Bool> {
        Binding(
            get: { selectedTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) },
            set: { enabled in
                if enabled {
                    if !selectedTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                        selectedTags.append(tag)
                    }
                } else {
                    selectedTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
                }
            }
        )
    }
}
