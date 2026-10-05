import SwiftUI
import Combine

@MainActor
final class ClipLibraryState: ObservableObject {
    let model = ClipLibraryViewModel()
    @Published var selection = Set<String>()
    @Published var sortMode: ClipSortMode = .date
    @Published var searchText = ""
    @Published var favoritesOnly = false
    @Published var deleteCandidate: ClipRow?
    @Published var bulkDeletePresented = false
    @Published var bulkTagDraft = ""
    @Published var cleanupSheetPresented = false
    @Published var previewURL: URL?
    @Published var metadataDraft = ClipUserMetadata.empty
    @Published var renameDraft = ""
    @Published var copiedFilePath: String?

}
