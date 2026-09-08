import XCTest
import ScreenCaptureKit
import CoreVideo
import CoreGraphics
@testable import Capture

final class HDRCaptureTests: XCTestCase {
    func testHDRStreamUsesTenBitHLGMatchingEncoder() throws {
        guard CaptureManager.supportsHDRCapture else { throw XCTSkip("HDR requires Apple silicon") }
        let config = CaptureManager.makeStreamConfiguration(captureHDR: true)
        XCTAssertEqual(config.captureDynamicRange, .hdrCanonicalDisplay)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(config.colorSpaceName, CGColorSpace.itur_2100_HLG)
        XCTAssertEqual(config.colorMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)
    }

    func testStreamUpdatesPreserveHDRColorConfiguration() throws {
        guard CaptureManager.supportsHDRCapture else { throw XCTSkip("HDR requires Apple silicon") }
        let original = CaptureManager.makeStreamConfiguration(captureHDR: true)
        let updated = SCStreamConfiguration()
        CaptureManager.copyColorConfiguration(from: original, to: updated)
        XCTAssertEqual(updated.captureDynamicRange, original.captureDynamicRange)
        XCTAssertEqual(updated.pixelFormat, original.pixelFormat)
        XCTAssertEqual(updated.colorSpaceName, original.colorSpaceName)
        XCTAssertEqual(updated.colorMatrix, original.colorMatrix)
    }

    func testSDRStillUsesOriginalCaptureFormat() {
        let config = CaptureManager.makeStreamConfiguration(captureHDR: false)
        XCTAssertEqual(config.captureDynamicRange, .SDR)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(config.colorSpaceName, CGColorSpace.sRGB)
    }
}
