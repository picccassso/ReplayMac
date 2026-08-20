import XCTest
import CoreGraphics
@testable import Capture

final class DisplayIdentityTests: XCTestCase {

    func testLegacyRawValueDetection() {
        XCTAssertTrue(DisplayIdentity.isLegacyRawValue("1"))
        XCTAssertTrue(DisplayIdentity.isLegacyRawValue("724043874"))
        XCTAssertFalse(DisplayIdentity.isLegacyRawValue(""))
        XCTAssertFalse(DisplayIdentity.isLegacyRawValue("edid:1552:41005:0"))
        XCTAssertFalse(DisplayIdentity.isLegacyRawValue("size:597x336"))
        XCTAssertFalse(DisplayIdentity.isLegacyRawValue("raw:3"))
        XCTAssertFalse(DisplayIdentity.isLegacyRawValue("builtin:main"))
    }

    func testResolveLegacyRawValueMatchesAttachedDisplay() {
        let attached: [CGDirectDisplayID] = [7, 12, 45]
        XCTAssertEqual(DisplayIdentity.resolve("12", among: attached), 12)
        XCTAssertNil(DisplayIdentity.resolve("99", among: attached))
    }

    func testResolveRawPrefixMatchesAttachedDisplay() {
        let attached: [CGDirectDisplayID] = [7, 12, 45]
        XCTAssertEqual(DisplayIdentity.resolve("raw:12", among: attached), 12)
        XCTAssertNil(DisplayIdentity.resolve("raw:99", among: attached))
    }

    func testResolveReturnsNilForUnattachedSelection() {
        XCTAssertNil(DisplayIdentity.resolve("edid:1552:41005:9999", among: []))
        XCTAssertNil(DisplayIdentity.resolve("size:9999x9999", among: []))
        XCTAssertNil(DisplayIdentity.resolve("", among: [1, 2]))
    }

    func testMatchesHandlesLegacyAndEmptyValues() {
        XCTAssertTrue(DisplayIdentity.matches("12", displayID: 12))
        XCTAssertFalse(DisplayIdentity.matches("12", displayID: 13))
        XCTAssertTrue(DisplayIdentity.matches("raw:12", displayID: 12))
        XCTAssertFalse(DisplayIdentity.matches("raw:12", displayID: 13))
        XCTAssertFalse(DisplayIdentity.matches(nil, displayID: 12))
        XCTAssertFalse(DisplayIdentity.matches("", displayID: 12))
    }

    func testMatchesEDIDExactAndPartial() {
        let online = DisplayIdentity.onlineDisplayIDs()
        if let first = online.first {
            let edid = DisplayIdentity.edidKey(for: first)
            XCTAssertTrue(DisplayIdentity.matches(edid, displayID: first))
        }
    }

    func testIsBuiltinDisplayKeyDetection() {
        XCTAssertTrue(DisplayIdentity.isBuiltinDisplayKey("builtin:main"))
        XCTAssertFalse(DisplayIdentity.isBuiltinDisplayKey("edid:7722:1234:0"))
        XCTAssertFalse(DisplayIdentity.isBuiltinDisplayKey("raw:2"))
        XCTAssertFalse(DisplayIdentity.isBuiltinDisplayKey("size:597x336"))
    }

    func testIsExternalDisplayKeyWithVariousFormats() {
        XCTAssertTrue(DisplayIdentity.isExternalDisplayKey("edid:7722:1234:0", among: []))
        XCTAssertTrue(DisplayIdentity.isExternalDisplayKey("edid:1552:41005:0", among: [])) // Apple external display
        XCTAssertTrue(DisplayIdentity.isExternalDisplayKey("size:597x336", among: []))
        XCTAssertFalse(DisplayIdentity.isExternalDisplayKey("builtin:main", among: []))
        XCTAssertFalse(DisplayIdentity.isExternalDisplayKey("", among: []))
    }

    func testMigrationLeavesNonLegacyAndUnresolvableValuesAlone() {
        XCTAssertNil(DisplayIdentity.migratedKey(forLegacyValue: "edid:1552:41005:0", among: [1, 2]))
        XCTAssertNil(DisplayIdentity.migratedKey(forLegacyValue: "size:597x336", among: [1, 2]))
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

    func testRawPrefixValueMigratesToStableKeyForAttachedDisplay() throws {
        let online = DisplayIdentity.onlineDisplayIDs()
        try XCTSkipIf(online.isEmpty, "No displays attached")
        let displayID = try XCTUnwrap(online.first)

        let migrated = DisplayIdentity.migratedKey(forLegacyValue: "raw:\(displayID)", among: online)
        XCTAssertEqual(migrated, DisplayIdentity.stableKey(for: displayID))
    }

    func testMatchesSizeKey() {
        let online = DisplayIdentity.onlineDisplayIDs()
        if let first = online.first {
            let size = DisplayIdentity.physicalSize(for: first)
            if size.width > 0 && size.height > 0 {
                let key = "size:\(size.width)x\(size.height)"
                XCTAssertTrue(DisplayIdentity.matches(key, displayID: first))
            }
        }
    }
}
