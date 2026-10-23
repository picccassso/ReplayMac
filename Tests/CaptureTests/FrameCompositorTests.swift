import XCTest
import CoreMedia
import CoreVideo
@testable import Capture

final class FrameCompositorTests: XCTestCase {
    private func makeFrame(width: Int, height: Int, seconds: Double) throws -> CMSampleBuffer {
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
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60_000),
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

    func testCompositesBothDisplaysSideBySide() throws {
        let compositor = FrameCompositor()
        compositor.configure(display1Width: 64, display1Height: 36, display2Width: 48, display2Height: 40, fps: 60)

        let output = OutputRecorder()
        compositor.outputHandler = { output.record($0) }

        compositor.pushPrimaryFrame(try makeFrame(width: 64, height: 36, seconds: 1))
        compositor.pushSecondaryFrame(try makeFrame(width: 48, height: 40, seconds: 1))

        let buffer = try XCTUnwrap(output.last)
        let pixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(buffer))
        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), 112)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer), 40)
    }

    /// Frames from the two displays arrive on separate capture queues while the
    /// pipeline can reconfigure or reset the compositor. Run under
    /// `swift test --sanitize=thread` to catch unguarded state.
    func testConcurrentFramesAndReconfigurationDoNotRace() throws {
        let compositor = FrameCompositor()
        compositor.configure(display1Width: 32, display1Height: 18, display2Width: 32, display2Height: 18, fps: 60)
        compositor.outputHandler = { _ in }

        let primaryFrames = try (0..<40).map { try makeFrame(width: 32, height: 18, seconds: 1 + Double($0) / 60) }
        let secondaryFrames = try (0..<40).map { try makeFrame(width: 32, height: 18, seconds: 1 + Double($0) / 60) }

        DispatchQueue.concurrentPerform(iterations: 3) { lane in
            for index in 0..<40 {
                switch lane {
                case 0:
                    compositor.pushPrimaryFrame(primaryFrames[index])
                case 1:
                    if index.isMultiple(of: 2) {
                        compositor.pushSecondaryFrame(secondaryFrames[index])
                    }
                default:
                    if index.isMultiple(of: 5) {
                        compositor.reset()
                        compositor.configure(
                            display1Width: 32, display1Height: 18,
                            display2Width: 32, display2Height: 18,
                            fps: 60
                        )
                    }
                }
            }
        }
    }
}

private final class OutputRecorder: @unchecked Sendable {
    // Guarded by `lock`; the compositor calls back on whichever thread pushed the frame.
    private let lock = NSLock()
    private var buffers: [CMSampleBuffer] = []

    func record(_ buffer: CMSampleBuffer) {
        lock.lock()
        buffers.append(buffer)
        lock.unlock()
    }

    var last: CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffers.last
    }
}
