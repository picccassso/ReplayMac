import XCTest
import CoreGraphics
@testable import Capture

final class DisplayIdentityTests: XCTestCase {

    func testLegacyRawValueDetection() {
        XCTAssertTrue(DisplayIdentity.isLegacyRawValue("1"))
        XCTAssertTrue(DisplayIdentity.isLegacyRawValue("724043874"))
        XCTAssertFalse(DisplayIdentity.isLegacyRawValue(""))
        XCTAssertFalse(DisplayIdentity.isLegacyRawValue("edid:1552:41005:0"))
        XCTAssertFalse(DisplayIdentity.isLegacyRawValue("raw:3"))
    }

    func testResolveLegacyRawValueMatchesAttachedDisplay() {
        let attached: [CGDirectDisplayID] = [7, 12, 45]
        XCTAssertEqual(DisplayIdentity.resolve("12", among: attached), 12)
        XCTAssertNil(DisplayIdentity.resolve("99", among: attached))
    }

    func testResolveReturnsNilForUnattachedSelection() {
        XCTAssertNil(DisplayIdentity.resolve("edid:1552:41005:9999", among: []))
        XCTAssertNil(DisplayIdentity.resolve("", among: [1, 2]))
    }

    func testMatchesHandlesLegacyAndEmptyValues() {
        XCTAssertTrue(DisplayIdentity.matches("12", displayID: 12))
        XCTAssertFalse(DisplayIdentity.matches("12", displayID: 13))
        XCTAssertFalse(DisplayIdentity.matches(nil, displayID: 12))
        XCTAssertFalse(DisplayIdentity.matches("", displayID: 12))
    }

    func testMigrationLeavesNonLegacyAndUnresolvableValuesAlone() {
        XCTAssertNil(DisplayIdentity.migratedKey(forLegacyValue: "edid:1552:41005:0", among: [1, 2]))
        XCTAssertNil(DisplayIdentity.migratedKey(forLegacyValue: "", among: [1, 2]))
        // An unattached display keeps its raw ID and migrates on a later launch.
        XCTAssertNil(DisplayIdentity.migratedKey(forLegacyValue: "77", among: [1, 2]))
    }

    func testStableKeyRoundTripsForAttachedDisplays() throws {
        let online = DisplayIdentity.onlineDisplayIDs()
        try XCTSkipIf(online.isEmpty, "No displays attached")

        for displayID in online {
            let key = DisplayIdentity.stableKey(for: displayID)
            XCTAssertFalse(DisplayIdentity.isLegacyRawValue(key))
            XCTAssertNotNil(DisplayIdentity.resolve(key, among: online))
            XCTAssertTrue(DisplayIdentity.matches(key, displayID: DisplayIdentity.resolve(key, among: online)!))
        }
    }

    func testLegacyValueMigratesToStableKeyForAttachedDisplay() throws {
        let online = DisplayIdentity.onlineDisplayIDs()
        try XCTSkipIf(online.isEmpty, "No displays attached")
        let displayID = try XCTUnwrap(online.first)

        let migrated = DisplayIdentity.migratedKey(forLegacyValue: String(displayID), among: online)
        XCTAssertEqual(migrated, DisplayIdentity.stableKey(for: displayID))
    }
}
