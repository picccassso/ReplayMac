import SwiftUI

/// Supplies the library's search field and actions to the window toolbar.
/// The library view itself stays alive behind other pages to keep its state,
/// so its toolbar comes from this separate view, which exists only while the
/// library is frontmost.
struct ClipLibraryToolbarHost: View {
    @ObservedObject var state: ClipLibraryState
    @ObservedObject var model: ClipLibraryViewModel

    init(state: ClipLibraryState) {
        self.state = state
        self.model = state.model
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search clips, tags, notes")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Picker("Sort By", selection: $state.sortMode) {
                            ForEach(ClipSortMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort clips")

                    Toggle(isOn: $state.favoritesOnly) {
                        Label("Favorites Only", systemImage: state.favoritesOnly ? "star.fill" : "star")
                    }
                    .help(state.favoritesOnly ? "Show all clips" : "Show favorites only")
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
}
