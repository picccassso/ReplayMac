import Foundation

public enum SavedClipKind: Sendable {
    case replay
    case extendedReplay
    case session

    public var title: String {
        switch self {
        case .replay: "Replay"
        case .extendedReplay: "Extended replay"
        case .session: "Session"
        }
    }
}

/// A clip saved since launch, shown in Home's session history. Details load
/// after the entry is added, so a new save appears immediately.
public struct RecentClip: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let kind: SavedClipKind
    public let savedAt: Date
    public var duration: TimeInterval?
    public var fileSize: Int64?
    public var thumbnail: Data?

    public init(
        id: UUID = UUID(),
        url: URL,
        kind: SavedClipKind,
        savedAt: Date,
        duration: TimeInterval? = nil,
        fileSize: Int64? = nil,
        thumbnail: Data? = nil
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.savedAt = savedAt
        self.duration = duration
        self.fileSize = fileSize
        self.thumbnail = thumbnail
    }
}
