import XCTest
@testable import Encode

final class EncoderTests: XCTestCase {
    func testHEVCInitialization() throws {
        let encoder = VideoEncoder()
        try encoder.start(width: 1920, height: 1080, fps: 60, codec: .hevc, bitrate: 20_000_000)
        encoder.stop()
    }

    func testH264Initialization() throws {
        let encoder = VideoEncoder()
        try encoder.start(width: 1920, height: 1080, fps: 60, codec: .h264, bitrate: 20_000_000)
        encoder.stop()
    }
}
