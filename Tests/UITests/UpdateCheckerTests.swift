import XCTest
@testable import UI

final class UpdateCheckerTests: XCTestCase {
    func testNewerVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("v1.4", newerThan: "1.3"))
        XCTAssertTrue(UpdateChecker.isVersion("1.3.1", newerThan: "1.3"))
        XCTAssertTrue(UpdateChecker.isVersion("release-v2.0.0", newerThan: "1.99.99"))
    }

    func testEqualAndOlderVersionsAreNotUpdates() {
        XCTAssertFalse(UpdateChecker.isVersion("v1.3", newerThan: "1.3.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.9", newerThan: "1.3"))
    }

    func testInvalidVersionsAreNotUpdates() {
        XCTAssertFalse(UpdateChecker.isVersion("latest", newerThan: "1.3"))
        XCTAssertFalse(UpdateChecker.isVersion("v1..4", newerThan: "1.3"))
    }
}

