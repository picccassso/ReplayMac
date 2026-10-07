import Foundation

public enum SavedClipKind: Sendable {
    case replay
    case extendedReplay
    case session

    var title: String {
        switch self {
        case .replay: "Replay"
        case .extendedReplay: "Extended replay"
        case .session: "Session"
        }
    }
}

/// A clip saved since launch, shown in Home's session history. Details load
/// after the entry is added, so a new save appears immediately.
struct RecentClip: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let kind: SavedClipKind
    let savedAt: Date
    var duration: TimeInterval?
    var fileSize: Int64?
    var thumbnail: Data?
}
