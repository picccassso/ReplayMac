import XCTest
@testable import Encode

final class EncoderTests: XCTestCase {
    func testHDRRejectsH264() {
        let encoder = VideoEncoder()
        defer { encoder.stop() }
        XCTAssertThrowsError(try encoder.start(width: 128, height: 64, fps: 30, codec: .h264, captureHDR: true)) { error in
            guard case VideoEncoderError.hdrRequiresHEVC = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHEVCInitialization() throws {
        let encoder = VideoEncoder()
        try encoder.start(width: 1920, height: 1080, fps: 60, codec: .hevc, bitrate: 20_000_000)
        XCTAssertEqual(
            encoder.currentConfiguration,
            VideoEncoderConfiguration(width: 1920, height: 1080, fps: 60, codec: .hevc, bitrate: 20_000_000)
        )
        encoder.stop()
    }

    func testH264Initialization() throws {
        let encoder = VideoEncoder()
        try encoder.start(width: 1920, height: 1080, fps: 60, codec: .h264, bitrate: 20_000_000)
        XCTAssertEqual(
            encoder.currentConfiguration,
            VideoEncoderConfiguration(width: 1920, height: 1080, fps: 60, codec: .h264, bitrate: 20_000_000)
        )
        encoder.stop()
    }

    func testBitrateIsReflectedInCurrentConfiguration() throws {
        let encoder = VideoEncoder()
        try encoder.start(width: 1280, height: 720, fps: 30, codec: .hevc, bitrate: 35_000_000)

        XCTAssertEqual(encoder.currentConfiguration?.bitrate, 35_000_000)

        encoder.stop()
        XCTAssertNil(encoder.currentConfiguration)
    }
}
