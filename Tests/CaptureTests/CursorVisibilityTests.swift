import XCTest
import ScreenCaptureKit
@testable import Capture

final class CursorVisibilityTests: XCTestCase {
    func testSDRConfigurationAppliesShowsCursor() {
        XCTAssertTrue(CaptureManager.makeStreamConfiguration(captureHDR: false, showsCursor: true).showsCursor)
        XCTAssertFalse(CaptureManager.makeStreamConfiguration(captureHDR: false, showsCursor: false).showsCursor)
    }

    func testHDRConfigurationAppliesShowsCursor() throws {
        guard CaptureManager.supportsHDRCapture else { throw XCTSkip("HDR requires Apple silicon") }
        XCTAssertFalse(CaptureManager.makeStreamConfiguration(captureHDR: true, showsCursor: false).showsCursor)
    }
}
