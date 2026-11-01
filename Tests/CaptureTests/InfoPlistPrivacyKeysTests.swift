import Foundation
import XCTest

/// macOS terminates the app (TCC SIGABRT) the moment it requests a
/// privacy-protected resource whose usage-description key is missing from
/// Info.plist, and a misspelled key counts as missing. Both the direct build
/// and the App Store project use Resources/Info.plist.
final class InfoPlistPrivacyKeysTests: XCTestCase {
    /// Purpose strings for every protected resource the app requests.
    private static let requiredKeys = [
        "NSCameraUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSAudioCaptureUsageDescription",
        "NSScreenCaptureUsageDescription",
        "NSLocalNetworkUsageDescription"
    ]

    /// Every usage-description key spelling the system actually reads, so a
    /// typo (e.g. "NSCameraUseUsageDescription") fails here instead of
    /// crashing on a user's Mac.
    private static let knownKeys = Set(requiredKeys)

    private func loadInfoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CaptureTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testRequiredUsageDescriptionsArePresent() throws {
        let plist = try loadInfoPlist()
        for key in Self.requiredKeys {
            let value = plist[key] as? String
            XCTAssertFalse(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, "\(key) is missing or empty")
        }
    }

    func testNoMisspelledUsageDescriptionKeys() throws {
        let plist = try loadInfoPlist()
        let unknown = plist.keys.filter { $0.hasSuffix("UsageDescription") && !Self.knownKeys.contains($0) }
        XCTAssertEqual(unknown.sorted(), [], "Unrecognised usage-description keys; macOS ignores these")
    }
}
