import Foundation

struct ClipSectionItem: Identifiable {
    let id: String
    let clipID: String
    let row: ClipRow

    init(sectionID: String, row: ClipRow) {
        self.id = "\(sectionID)|\(row.id)"
        self.clipID = row.id
        self.row = row
    }
}

struct ClipSection: Identifiable {
    let id: String
    let title: String
    let systemImage: String?
    let totalBytes: Int64
    let items: [ClipSectionItem]

    var clipCount: Int { items.count }
}

@MainActor
enum ClipLibraryFormatter {
    private static let tableMediumDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let gridMediumDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdhm")
        return formatter
    }()

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static let relativeFullFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static let relativeAbbreviatedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter
    }()

    private static let monthKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    static func formatDate(
        _ date: Date,
        style: ClipDateFormatStyle,
        compact: Bool,
        now: Date = Date()
    ) -> String {
        switch style {
        case .medium:
            return compact
                ? gridMediumDate.string(from: date)
                : tableMediumDate.string(from: date)
        case .relative:
            let formatter = compact ? relativeAbbreviatedFormatter : relativeFullFormatter
            return formatter.localizedString(for: date, relativeTo: now)
        case .iso:
            return isoDateFormatter.string(from: date)
        }
    }

    static func formatMonthYear(_ date: Date) -> String {
        monthYearFormatter.string(from: date)
    }

    static func formatMonthKey(_ date: Date) -> String {
        monthKeyFormatter.string(from: date)
    }

    static func formatResolution(_ resolution: CGSize?) -> String? {
        guard let resolution, resolution.width > 0, resolution.height > 0 else {
            return nil
        }
        return "\(Int(resolution.width.rounded()))×\(Int(resolution.height.rounded()))"
    }

    static func gridSubtitle(
        for row: ClipRow,
        fields: Set<ClipGridSubtitleField>,
        dateFormat: ClipDateFormatStyle,
        now: Date = Date()
    ) -> String {
        var parts: [String] = []
        if fields.contains(.date) {
            parts.append(formatDate(row.info.creationDate, style: dateFormat, compact: true, now: now))
        }
        if fields.contains(.duration) {
            parts.append(row.durationLabel)
        }
        if fields.contains(.size) {
            parts.append(row.sizeLabel)
        }
        if fields.contains(.resolution), let res = row.resolutionLabel {
            parts.append(res)
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
enum ClipLibraryQuery {
    static func filteredAndSortedRows(
        from rows: [ClipRow],
        options: ClipLibraryQueryOptions,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ClipRow] {
        let query = options.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedTagsLowercased = Set(
            options.selectedTags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        let filtered = rows.filter { row in
            if options.favoritesOnly, !row.userMetadata.isFavorite {
                return false
            }
            if !matchesDateFilter(row.info.creationDate, filter: options.dateFilter, now: now, calendar: calendar) {
                return false
            }
            if !selectedTagsLowercased.isEmpty {
                let rowTags = row.userMetadata.tags.map { $0.lowercased() }
                guard rowTags.contains(where: { selectedTagsLowercased.contains($0) }) else {
                    return false
                }
            }
            if !query.isEmpty, !row.searchText.localizedCaseInsensitiveContains(query) {
                return false
            }
            return true
        }

        return sortRows(filtered, options: options)
    }

    static func sections(
        from rows: [ClipRow],
        options: ClipLibraryQueryOptions,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ClipSection] {
        let sorted = filteredAndSortedRows(from: rows, options: options, now: now, calendar: calendar)
        guard !sorted.isEmpty else { return [] }

        switch options.groupMode {
        case .none:
            return [
                makeSection(
                    id: "all",
                    title: "",
                    systemImage: nil,
                    rows: sorted
                )
            ]

        case .date:
            return dateSections(from: sorted, options: options, now: now, calendar: calendar)

        case .favorites:
            let favorites = sorted.filter(\.userMetadata.isFavorite)
            let others = sorted.filter { !$0.userMetadata.isFavorite }
            var sections: [ClipSection] = []
            if !favorites.isEmpty {
                sections.append(makeSection(id: "fav:yes", title: "Favorites", systemImage: "star.fill", rows: favorites))
            }
            if !others.isEmpty {
                sections.append(makeSection(id: "fav:no", title: "Other Clips", systemImage: "film.stack", rows: others))
            }
            return sections

        case .tag:
            return tagSections(from: sorted)
        }
    }

    static func matchesDateFilter(
        _ date: Date,
        filter: ClipDateFilter,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let startOfToday = calendar.startOfDay(for: now)
        switch filter {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .last7Days:
            let cutoff = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            return date >= cutoff
        case .last30Days:
            let cutoff = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            return date >= cutoff
        case .thisMonth:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        }
    }

    // MARK: - Sorting

    private static func sortRows(_ rows: [ClipRow], options: ClipLibraryQueryOptions) -> [ClipRow] {
        rows.sorted { lhs, rhs in
            if options.favoritesFirst, lhs.userMetadata.isFavorite != rhs.userMetadata.isFavorite {
                return lhs.userMetadata.isFavorite
            }

            let comparison = comparePrimary(lhs, rhs, mode: options.sortMode)
            if comparison != .orderedSame {
                return options.sortDirection == .ascending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }

            if lhs.info.creationDate != rhs.info.creationDate {
                return lhs.info.creationDate > rhs.info.creationDate
            }
            return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
        }
    }

    private static func comparePrimary(_ lhs: ClipRow, _ rhs: ClipRow, mode: ClipSortMode) -> ComparisonResult {
        switch mode {
        case .date:
            if lhs.info.creationDate < rhs.info.creationDate { return .orderedAscending }
            if lhs.info.creationDate > rhs.info.creationDate { return .orderedDescending }
            return .orderedSame
        case .name:
            return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
        case .duration:
            let l = lhs.info.duration.isFinite ? lhs.info.duration : -1
            let r = rhs.info.duration.isFinite ? rhs.info.duration : -1
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        case .size:
            if lhs.info.fileSize < rhs.info.fileSize { return .orderedAscending }
            if lhs.info.fileSize > rhs.info.fileSize { return .orderedDescending }
            return .orderedSame
        }
    }

    // MARK: - Date Grouping

    private struct DateBucketKey: Hashable {
        let id: String
        let title: String
        let rank: Int
        let sortDate: Date
    }

    private static func dateSections(
        from rows: [ClipRow],
        options: ClipLibraryQueryOptions,
        now: Date,
        calendar: Calendar
    ) -> [ClipSection] {
        var buckets: [DateBucketKey: [ClipRow]] = [:]
        for row in rows {
            let key = dateBucket(for: row.info.creationDate, now: now, calendar: calendar)
            buckets[key, default: []].append(row)
        }

        let ascendingSections = options.sortMode == .date && options.sortDirection == .ascending
        let sortedKeys = buckets.keys.sorted { lhs, rhs in
            if lhs.rank != rhs.rank {
                return ascendingSections ? lhs.rank > rhs.rank : lhs.rank < rhs.rank
            }
            if lhs.sortDate != rhs.sortDate {
                return ascendingSections ? lhs.sortDate < rhs.sortDate : lhs.sortDate > rhs.sortDate
            }
            return lhs.id < rhs.id
        }

        return sortedKeys.compactMap { key in
            guard let bucketRows = buckets[key], !bucketRows.isEmpty else { return nil }
            return makeSection(
                id: key.id,
                title: key.title,
                systemImage: "calendar",
                rows: bucketRows
            )
        }
    }

    private static func dateBucket(for date: Date, now: Date, calendar: Calendar) -> DateBucketKey {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday || calendar.isDate(date, inSameDayAs: now) {
            return DateBucketKey(id: "date:today", title: "Today", rank: 0, sortDate: startOfToday)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return DateBucketKey(id: "date:yesterday", title: "Yesterday", rank: 1, sortDate: yesterday)
        }
        if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
           thisWeek.contains(date) {
            return DateBucketKey(id: "date:thisWeek", title: "This Week", rank: 2, sortDate: thisWeek.start)
        }
        if let lastWeekAnchor = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfToday),
           let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastWeekAnchor),
           lastWeek.contains(date) {
            return DateBucketKey(id: "date:lastWeek", title: "Last Week", rank: 3, sortDate: lastWeek.start)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) {
            let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? startOfToday
            return DateBucketKey(id: "date:earlierThisMonth", title: "Earlier This Month", rank: 4, sortDate: monthStart)
        }

        let monthStart = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let monthKey = ClipLibraryFormatter.formatMonthKey(date)
        let title = ClipLibraryFormatter.formatMonthYear(date)
        return DateBucketKey(id: "date:month:\(monthKey)", title: title, rank: 5, sortDate: monthStart)
    }

    // MARK: - Tag Grouping

    private static func tagSections(from rows: [ClipRow]) -> [ClipSection] {
        var displayNameByKey: [String: String] = [:]
        var rowsByTagKey: [String: [ClipRow]] = [:]
        var untagged: [ClipRow] = []

        for row in rows {
            if row.userMetadata.tags.isEmpty {
                untagged.append(row)
                continue
            }
            var seenInRow = Set<String>()
            for rawTag in row.userMetadata.tags {
                let clean = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                let key = clean.lowercased()
                guard seenInRow.insert(key).inserted else { continue }
                if displayNameByKey[key] == nil {
                    displayNameByKey[key] = clean
                }
                rowsByTagKey[key, default: []].append(row)
            }
        }

        let sortedTagKeys = rowsByTagKey.keys.sorted { lhs, rhs in
            let leftName = displayNameByKey[lhs] ?? lhs
            let rightName = displayNameByKey[rhs] ?? rhs
            return leftName.localizedStandardCompare(rightName) == .orderedAscending
        }

        var sections: [ClipSection] = sortedTagKeys.compactMap { key in
            guard let tagRows = rowsByTagKey[key], !tagRows.isEmpty else { return nil }
            let title = displayNameByKey[key] ?? key
            return makeSection(
                id: "tag:\(key)",
                title: title,
                systemImage: "tag.fill",
                rows: tagRows
            )
        }

        if !untagged.isEmpty {
            sections.append(
                makeSection(
                    id: "tag:__untagged",
                    title: "Untagged",
                    systemImage: "tag.slash",
                    rows: untagged
                )
            )
        }

        return sections
    }

    private static func makeSection(
        id: String,
        title: String,
        systemImage: String?,
        rows: [ClipRow]
    ) -> ClipSection {
        let totalBytes = rows.reduce(Int64(0)) { $0 + $1.info.fileSize }
        let items = rows.map { ClipSectionItem(sectionID: id, row: $0) }
        return ClipSection(
            id: id,
            title: title,
            systemImage: systemImage,
            totalBytes: totalBytes,
            items: items
        )
    }
}
