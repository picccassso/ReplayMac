import XCTest
import Defaults
import Save
@testable import UI

@MainActor
final class ClipLibraryQueryTests: XCTestCase {
    private var referenceCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.firstWeekday = 1 // Sunday
        return calendar
    }()

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        let components = DateComponents(
            calendar: referenceCalendar,
            timeZone: referenceCalendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return components.date ?? Date()
    }

    private func makeRow(
        name: String,
        date: Date,
        duration: TimeInterval = 15,
        fileSize: Int64 = 1_000_000,
        resolution: CGSize? = CGSize(width: 1920, height: 1080),
        displayName: String = "",
        isFavorite: Bool = false,
        tags: [String] = [],
        notes: String = ""
    ) -> ClipRow {
        let url = URL(fileURLWithPath: "/tmp/\(name).mp4")
        let info = ClipInfo(
            fileURL: url,
            creationDate: date,
            duration: duration,
            fileSize: fileSize,
            resolution: resolution
        )
        let metadata = ClipUserMetadata(
            displayName: displayName,
            isFavorite: isFavorite,
            tags: tags,
            notes: notes
        )
        return ClipRow(info: info, thumbnail: nil, userMetadata: metadata)
    }

    func testDateGroupingBucketsAndSectionOrdering() {
        // Friday, Nov 20, 2026
        let now = makeDate(year: 2026, month: 11, day: 20, hour: 15)
        let today = makeRow(name: "today", date: makeDate(year: 2026, month: 11, day: 20, hour: 9))
        let yesterday = makeRow(name: "yesterday", date: makeDate(year: 2026, month: 11, day: 19, hour: 18))
        let thisWeek = makeRow(name: "this_week", date: makeDate(year: 2026, month: 11, day: 16, hour: 12)) // Monday of same week
        let lastWeek = makeRow(name: "last_week", date: makeDate(year: 2026, month: 11, day: 10, hour: 12))
        let earlierMonth = makeRow(name: "earlier_month", date: makeDate(year: 2026, month: 11, day: 2, hour: 12))
        let oct = makeRow(name: "october", date: makeDate(year: 2026, month: 10, day: 25, hour: 12))

        let rows = [oct, earlierMonth, lastWeek, thisWeek, yesterday, today]

        let descOptions = ClipLibraryQueryOptions(groupMode: .date, sortMode: .date, sortDirection: .descending)
        let descSections = ClipLibraryQuery.sections(from: rows, options: descOptions, now: now, calendar: referenceCalendar)
        XCTAssertEqual(
            descSections.map(\.id),
            ["date:today", "date:yesterday", "date:thisWeek", "date:lastWeek", "date:earlierThisMonth", "date:month:2026-10"]
        )
        XCTAssertEqual(descSections.first?.title, "Today")

        // Sorting by date ascending reverses section order (oldest first).
        let ascOptions = ClipLibraryQueryOptions(groupMode: .date, sortMode: .date, sortDirection: .ascending)
        let ascSections = ClipLibraryQuery.sections(from: rows, options: ascOptions, now: now, calendar: referenceCalendar)
        XCTAssertEqual(
            ascSections.map(\.id),
            ["date:month:2026-10", "date:earlierThisMonth", "date:lastWeek", "date:thisWeek", "date:yesterday", "date:today"]
        )

        // Sorting by name ascending keeps date sections newest-first.
        let nameAscOptions = ClipLibraryQueryOptions(groupMode: .date, sortMode: .name, sortDirection: .ascending)
        let nameAscSections = ClipLibraryQuery.sections(from: rows, options: nameAscOptions, now: now, calendar: referenceCalendar)
        XCTAssertEqual(
            nameAscSections.map(\.id),
            ["date:today", "date:yesterday", "date:thisWeek", "date:lastWeek", "date:earlierThisMonth", "date:month:2026-10"]
        )
    }

    func testTagGroupingPlacesMultiTagClipsInEveryMatchingSection() {
        let now = makeDate(year: 2026, month: 11, day: 20)
        let clutchAce = makeRow(name: "clip_1", date: now, tags: ["Clutch", "Ace"])
        let aceOnly = makeRow(name: "clip_2", date: now.addingTimeInterval(-60), tags: ["ace"])
        let untagged = makeRow(name: "clip_3", date: now.addingTimeInterval(-120), tags: [])

        let options = ClipLibraryQueryOptions(groupMode: .tag, sortMode: .date, sortDirection: .descending)
        let sections = ClipLibraryQuery.sections(from: [clutchAce, aceOnly, untagged], options: options, now: now, calendar: referenceCalendar)

        XCTAssertEqual(sections.map(\.title), ["Ace", "Clutch", "Untagged"])
        XCTAssertEqual(sections[0].items.map(\.clipID), [clutchAce.id, aceOnly.id])
        XCTAssertEqual(sections[1].items.map(\.clipID), [clutchAce.id])
        XCTAssertEqual(sections[2].items.map(\.clipID), [untagged.id])

        // View item IDs must be distinct across sections even for the same clip.
        let allItemIDs = sections.flatMap(\.items).map(\.id)
        XCTAssertEqual(Set(allItemIDs).count, allItemIDs.count)
    }

    func testFavoritesGroupingAndFavoritesFirstSorting() {
        let now = makeDate(year: 2026, month: 11, day: 20)
        let favSmall = makeRow(name: "fav_small", date: now.addingTimeInterval(-120), fileSize: 100, isFavorite: true)
        let nonFavBig = makeRow(name: "non_fav_big", date: now, fileSize: 9_000, isFavorite: false)

        let grouped = ClipLibraryQuery.sections(
            from: [nonFavBig, favSmall],
            options: ClipLibraryQueryOptions(groupMode: .favorites),
            now: now,
            calendar: referenceCalendar
        )
        XCTAssertEqual(grouped.map(\.title), ["Favorites", "Other Clips"])

        let flatFavFirst = ClipLibraryQuery.filteredAndSortedRows(
            from: [nonFavBig, favSmall],
            options: ClipLibraryQueryOptions(groupMode: .none, sortMode: .size, sortDirection: .descending, favoritesFirst: true),
            now: now,
            calendar: referenceCalendar
        )
        XCTAssertEqual(flatFavFirst.map(\.id), [favSmall.id, nonFavBig.id])
    }

    func testSortingModesAndNaturalNameOrder() {
        let now = makeDate(year: 2026, month: 11, day: 20)
        let c10 = makeRow(name: "Clip 10", date: now, duration: 5, fileSize: 300)
        let c2 = makeRow(name: "Clip 2", date: now.addingTimeInterval(-60), duration: 30, fileSize: 100)
        let c1 = makeRow(name: "Clip 1", date: now.addingTimeInterval(-120), duration: 15, fileSize: 200)

        let byNameAsc = ClipLibraryQuery.filteredAndSortedRows(
            from: [c10, c2, c1],
            options: ClipLibraryQueryOptions(groupMode: .none, sortMode: .name, sortDirection: .ascending)
        )
        XCTAssertEqual(byNameAsc.map(\.fileNameWithoutExtension), ["Clip 1", "Clip 2", "Clip 10"])

        let byDurationAsc = ClipLibraryQuery.filteredAndSortedRows(
            from: [c10, c2, c1],
            options: ClipLibraryQueryOptions(groupMode: .none, sortMode: .duration, sortDirection: .ascending)
        )
        XCTAssertEqual(byDurationAsc.map(\.id), [c10.id, c1.id, c2.id])

        let bySizeDesc = ClipLibraryQuery.filteredAndSortedRows(
            from: [c10, c2, c1],
            options: ClipLibraryQueryOptions(groupMode: .none, sortMode: .size, sortDirection: .descending)
        )
        XCTAssertEqual(bySizeDesc.map(\.id), [c10.id, c1.id, c2.id])
    }

    func testDateTagFavoritesAndSearchFiltersCompose() {
        let now = makeDate(year: 2026, month: 11, day: 20, hour: 15)
        let match = makeRow(
            name: "rocket",
            date: makeDate(year: 2026, month: 11, day: 18),
            displayName: "Overtime Goal",
            isFavorite: true,
            tags: ["RL", "Goal"],
            notes: "Nice pass"
        )
        let tooOld = makeRow(
            name: "old",
            date: makeDate(year: 2026, month: 10, day: 1),
            displayName: "Old Goal",
            isFavorite: true,
            tags: ["RL"]
        )
        let wrongTag = makeRow(
            name: "wrong_tag",
            date: makeDate(year: 2026, month: 11, day: 19),
            displayName: "Overtime Save",
            isFavorite: true,
            tags: ["Valorant"]
        )

        let options = ClipLibraryQueryOptions(
            groupMode: .none,
            favoritesOnly: true,
            dateFilter: .last7Days,
            selectedTags: ["rl"],
            searchText: "overtime"
        )
        let result = ClipLibraryQuery.filteredAndSortedRows(
            from: [match, tooOld, wrongTag],
            options: options,
            now: now,
            calendar: referenceCalendar
        )
        XCTAssertEqual(result.map(\.id), [match.id])
    }

    func testGridSubtitleFormattingAndDefaultsReset() {
        let now = makeDate(year: 2026, month: 11, day: 20, hour: 15)
        let row = makeRow(
            name: "demo",
            date: makeDate(year: 2026, month: 11, day: 20, hour: 14, minute: 30),
            duration: 42,
            fileSize: 2_000_000,
            resolution: CGSize(width: 2560, height: 1440)
        )

        let subtitle = ClipLibraryFormatter.gridSubtitle(
            for: row,
            fields: [.date, .duration, .size, .resolution],
            dateFormat: .iso,
            now: now
        )
        XCTAssertTrue(subtitle.contains("00:42"))
        XCTAssertTrue(subtitle.contains("2560×1440"))
        XCTAssertTrue(subtitle.contains("2026-11-20"))

        let prevGroup = Defaults[.clipLibraryGroupMode]
        let prevColumns = Defaults[.clipLibraryVisibleColumns]
        defer {
            Defaults[.clipLibraryGroupMode] = prevGroup
            Defaults[.clipLibraryVisibleColumns] = prevColumns
        }

        Defaults[.clipLibraryGroupMode] = .tag
        Defaults[.clipLibraryVisibleColumns] = [.notes]
        ClipLibraryViewOptions.resetToDefaults()

        XCTAssertEqual(Defaults[.clipLibraryGroupMode], .date)
        XCTAssertEqual(Defaults[.clipLibraryVisibleColumns], ClipTableColumn.defaultVisible)
    }
}
