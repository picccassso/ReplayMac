import Foundation
import Defaults

enum ClipLibraryLayout: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case list
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "List"
        case .grid: return "Grid"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

enum ClipGroupMode: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case none
    case date
    case favorites
    case tag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .date: return "Date"
        case .favorites: return "Favorites"
        case .tag: return "Tag"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "rectangle.stack"
        case .date: return "calendar"
        case .favorites: return "star"
        case .tag: return "tag"
        }
    }
}

enum ClipSortMode: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case date
    case name
    case duration
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return "Date"
        case .name: return "Name"
        case .duration: return "Duration"
        case .size: return "Size"
        }
    }

    var defaultDirection: ClipSortDirection {
        switch self {
        case .name: return .ascending
        case .date, .duration, .size: return .descending
        }
    }

    func directionLabel(for direction: ClipSortDirection) -> String {
        switch (self, direction) {
        case (.date, .descending): return "Newest First"
        case (.date, .ascending): return "Oldest First"
        case (.name, .ascending): return "A to Z"
        case (.name, .descending): return "Z to A"
        case (.duration, .descending): return "Longest First"
        case (.duration, .ascending): return "Shortest First"
        case (.size, .descending): return "Largest First"
        case (.size, .ascending): return "Smallest First"
        }
    }
}

enum ClipSortDirection: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case ascending
    case descending

    var id: String { rawValue }

    var toggled: ClipSortDirection {
        self == .ascending ? .descending : .ascending
    }
}

enum ClipDateFilter: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case all
    case today
    case last7Days
    case last30Days
    case thisMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Any Date"
        case .today: return "Today"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .thisMonth: return "This Month"
        }
    }
}

enum ClipDateFormatStyle: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case medium
    case relative
    case iso

    var id: String { rawValue }

    var title: String {
        switch self {
        case .medium: return "Date & Time"
        case .relative: return "Relative"
        case .iso: return "Numeric (YYYY-MM-DD)"
        }
    }
}

enum ClipTableDensity: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }

    var thumbnailSize: CGSize {
        switch self {
        case .compact: return CGSize(width: 56, height: 32)
        case .comfortable: return CGSize(width: 80, height: 45)
        case .spacious: return CGSize(width: 112, height: 63)
        }
    }

    var titleFontSize: CGFloat {
        switch self {
        case .compact: return 12
        case .comfortable: return 13
        case .spacious: return 14
        }
    }

    var subtitleFontSize: CGFloat {
        switch self {
        case .compact: return 10
        case .comfortable: return 11
        case .spacious: return 11.5
        }
    }

    var cellFontSize: CGFloat {
        switch self {
        case .compact: return 11.5
        case .comfortable: return 12
        case .spacious: return 12.5
        }
    }
}

enum ClipTableColumn: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case favorite
    case tags
    case duration
    case size
    case resolution
    case created
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorite: return "Favorite Star"
        case .tags: return "Tags"
        case .duration: return "Duration"
        case .size: return "Size"
        case .resolution: return "Resolution"
        case .created: return "Created"
        case .notes: return "Notes"
        }
    }

    static let defaultVisible: Set<ClipTableColumn> = [
        .favorite, .tags, .duration, .size, .created
    ]
}

enum ClipGridSubtitleField: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case date
    case size
    case duration
    case resolution

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return "Date"
        case .size: return "File Size"
        case .duration: return "Duration"
        case .resolution: return "Resolution"
        }
    }

    static let defaultFields: Set<ClipGridSubtitleField> = [.date, .size]
}

struct ClipGridDisplayOptions: Equatable, Sendable {
    var showTagBadges: Bool
    var showDurationBadge: Bool
    var showFavoriteBadge: Bool
    var subtitleFields: Set<ClipGridSubtitleField>
    var dateFormat: ClipDateFormatStyle

    static let `default` = ClipGridDisplayOptions(
        showTagBadges: true,
        showDurationBadge: true,
        showFavoriteBadge: true,
        subtitleFields: ClipGridSubtitleField.defaultFields,
        dateFormat: .medium
    )
}

struct ClipLibraryQueryOptions: Equatable, Sendable {
    var groupMode: ClipGroupMode = .date
    var sortMode: ClipSortMode = .date
    var sortDirection: ClipSortDirection = .descending
    var favoritesFirst: Bool = false
    var favoritesOnly: Bool = false
    var dateFilter: ClipDateFilter = .all
    var selectedTags: [String] = []
    var searchText: String = ""
}

enum ClipLibraryViewOptions {
    static func resetToDefaults() {
        Defaults.reset(
            .clipLibraryGroupMode,
            .clipLibrarySortMode,
            .clipLibrarySortDirection,
            .clipLibrarySortFavoritesFirst,
            .clipLibraryDateFormat,
            .clipLibraryGridCardWidth,
            .clipLibraryTableDensity,
            .clipLibraryVisibleColumns,
            .clipLibraryGridSubtitleFields,
            .clipLibraryGridShowTagBadges,
            .clipLibraryGridShowDurationBadge,
            .clipLibraryGridShowFavoriteBadge
        )
    }

    static func resetFilters() {
        Defaults.reset(
            .clipLibraryFavoritesOnly,
            .clipLibraryDateFilter,
            .clipLibrarySelectedTags
        )
    }
}

extension Defaults.Keys {
    static let clipLibraryLayout = Key<ClipLibraryLayout>("clipLibraryLayout", default: .list)
    /// Smallest width a grid card may shrink to; cards stretch to fill each row.
    static let clipLibraryGridCardWidth = Key<Double>("clipLibraryGridCardWidth", default: 240)
    static let clipLibraryGroupMode = Key<ClipGroupMode>("clipLibraryGroupMode", default: .date)
    static let clipLibrarySortMode = Key<ClipSortMode>("clipLibrarySortMode", default: .date)
    static let clipLibrarySortDirection = Key<ClipSortDirection>("clipLibrarySortDirection", default: .descending)
    static let clipLibrarySortFavoritesFirst = Key<Bool>("clipLibrarySortFavoritesFirst", default: false)
    static let clipLibraryFavoritesOnly = Key<Bool>("clipLibraryFavoritesOnly", default: false)
    static let clipLibraryDateFilter = Key<ClipDateFilter>("clipLibraryDateFilter", default: .all)
    static let clipLibrarySelectedTags = Key<[String]>("clipLibrarySelectedTags", default: [])
    static let clipLibraryDateFormat = Key<ClipDateFormatStyle>("clipLibraryDateFormat", default: .medium)
    static let clipLibraryTableDensity = Key<ClipTableDensity>("clipLibraryTableDensity", default: .comfortable)
    static let clipLibraryVisibleColumns = Key<Set<ClipTableColumn>>(
        "clipLibraryVisibleColumns",
        default: ClipTableColumn.defaultVisible
    )
    static let clipLibraryGridSubtitleFields = Key<Set<ClipGridSubtitleField>>(
        "clipLibraryGridSubtitleFields",
        default: ClipGridSubtitleField.defaultFields
    )
    static let clipLibraryGridShowTagBadges = Key<Bool>("clipLibraryGridShowTagBadges", default: true)
    static let clipLibraryGridShowDurationBadge = Key<Bool>("clipLibraryGridShowDurationBadge", default: true)
    static let clipLibraryGridShowFavoriteBadge = Key<Bool>("clipLibraryGridShowFavoriteBadge", default: true)
}
