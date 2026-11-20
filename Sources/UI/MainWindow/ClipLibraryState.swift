import SwiftUI
import Combine

@MainActor
final class ClipLibraryState: ObservableObject {
    let model = ClipLibraryViewModel()
    @Published var selection = Set<String>()
    @Published var collapsedSections = Set<String>()
    @Published var searchText = ""
    @Published var viewOptionsPresented = false
    @Published var deleteCandidate: ClipRow?
    @Published var bulkDeletePresented = false
    @Published var bulkTagDraft = ""
    @Published var cleanupSheetPresented = false
    @Published var previewURL: URL?
    @Published var metadataDraft = ClipUserMetadata.empty
    @Published var renameDraft = ""
    @Published var copiedFilePath: String?
    @Published var isDetailsExpanded = false

    func isSectionCollapsed(_ sectionID: String) -> Bool {
        collapsedSections.contains(sectionID)
    }

    func toggleSection(_ sectionID: String) {
        if collapsedSections.contains(sectionID) {
            collapsedSections.remove(sectionID)
        } else {
            collapsedSections.insert(sectionID)
        }
    }

    func expandAllSections() {
        collapsedSections.removeAll()
    }

    func collapseSections(_ sectionIDs: [String]) {
        collapsedSections.formUnion(sectionIDs)
    }
}
