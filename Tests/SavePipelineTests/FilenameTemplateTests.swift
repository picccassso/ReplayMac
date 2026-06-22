import XCTest
@testable import Save

final class FilenameTemplateTests: XCTestCase {
    private let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 22
        components.hour = 11
        components.minute = 0
        components.second = 21
        return Calendar.current.date(from: components)!
    }()

    func testDefaultTemplateReproducesLegacyName() {
        let result = FilenameTemplate.resolve(
            template: FilenameTemplate.default,
            appName: "Rocket League",
            date: referenceDate
        )
        XCTAssertEqual(result, "ReplayMac_2026-06-22_11-00-21")
    }

    func testAppTokenIsSubstituted() {
        let result = FilenameTemplate.resolve(
            template: "{app}_{date}",
            appName: "Rocket League",
            date: referenceDate
        )
        XCTAssertEqual(result, "Rocket League_2026-06-22")
    }

    func testMissingAppTokenLeavesNoStraySeparators() {
        let result = FilenameTemplate.resolve(
            template: "{app}_{date}_{time}",
            appName: nil,
            date: referenceDate
        )
        XCTAssertEqual(result, "2026-06-22_11-00-21")
    }

    func testIllegalCharactersAreSanitized() {
        let result = FilenameTemplate.resolve(
            template: "{app}",
            appName: "Final/Cut: Pro",
            date: referenceDate
        )
        XCTAssertFalse(result.contains("/"))
        XCTAssertFalse(result.contains(":"))
    }

    func testEmptyResultFallsBackToDefaultBaseName() {
        let result = FilenameTemplate.resolve(
            template: "{app}",
            appName: nil,
            date: referenceDate
        )
        XCTAssertEqual(result, "ReplayMac_2026-06-22_11-00-21")
    }
}
