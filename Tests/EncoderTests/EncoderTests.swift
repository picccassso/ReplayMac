import XCTest
import CoreMedia
import CoreVideo
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

    /// The output callback runs on a VideoToolbox thread while `encode` keeps
    /// counting frames on the caller's. Zero timestamps take the callback's
    /// logging path, which reads the counter. Run under
    /// `swift test --sanitize=thread` to catch unguarded state.
    func testOutputCallbackDoesNotRaceWithEncode() throws {
        let encoder = VideoEncoder()
        let delivered = expectation(description: "encoded frame delivered")
        delivered.assertForOverFulfill = false
        encoder.outputHandler = { _ in delivered.fulfill() }
        try encoder.start(width: 64, height: 64, fps: 30, codec: .h264, bitrate: 1_000_000)
        defer { encoder.stop() }

        for _ in 0..<30 {
            encoder.encode(sampleBuffer: try makeFrame(width: 64, height: 64, presentationTime: .zero))
        }
        wait(for: [delivered], timeout: 5)
    }

    private func makeFrame(width: Int, height: Int, presentationTime: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return try XCTUnwrap(sampleBuffer)
    }
}
