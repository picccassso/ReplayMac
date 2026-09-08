import XCTest
import Defaults
import Capture
@testable import UI

final class HDRSettingsTests: XCTestCase {
    func testHDRSelectsHEVCOnlyForSupportedCaptureModes() {
        let previousHDR = Defaults[.captureHDR]
        let previousCodec = Defaults[.videoCodec]
        let previousMode = Defaults[.captureMode]
        let previousSaveMode = Defaults[.dualCaptureSaveMode]
        defer {
            Defaults[.captureHDR] = previousHDR
            Defaults[.videoCodec] = previousCodec
            Defaults[.captureMode] = previousMode
            Defaults[.dualCaptureSaveMode] = previousSaveMode
        }
        Defaults[.captureHDR] = true
        Defaults[.videoCodec] = "h264"
        Defaults[.captureMode] = CaptureMode.single.rawValue
        XCTAssertEqual(AppSettings.isHDRCaptureActive, CaptureManager.supportsHDRCapture)
        XCTAssertEqual(AppSettings.effectiveVideoCodec, CaptureManager.supportsHDRCapture ? "hevc" : "h264")
        Defaults[.captureMode] = CaptureMode.dualSideBySide.rawValue
        Defaults[.dualCaptureSaveMode] = DualCaptureSaveMode.sideBySide.rawValue
        XCTAssertFalse(AppSettings.isHDRCaptureActive)
        XCTAssertEqual(AppSettings.effectiveVideoCodec, "h264")
        Defaults[.dualCaptureSaveMode] = DualCaptureSaveMode.separateFiles.rawValue
        XCTAssertEqual(AppSettings.isHDRCaptureActive, CaptureManager.supportsHDRCapture)
        Defaults[.captureHDR] = false
        XCTAssertFalse(AppSettings.isHDRCaptureActive)
        XCTAssertEqual(AppSettings.effectiveVideoCodec, "h264")
    }
}
