import XCTest
import CoreMedia
import CoreVideo
import AVFoundation
@testable import Capture

/// Camera overlay tests: pure layout geometry, single/dual compositor emission
/// with a camera overlay, camera-frame staleness, and headless `CameraCapture`
/// smoke tests (no camera hardware required).
///
/// `makeFrame` / `OutputRecorder` mirror the helpers in
/// `FrameCompositorTests.swift` (they are file-private there).
final class CameraOverlayTests: XCTestCase {
    // MARK: - Helpers

    private func makeFrame(width: Int, height: Int, seconds: Double) throws -> CMSampleBuffer {
        try makeSolidFrame(width: width, height: height, bgra: (0, 0, 0, 255), seconds: seconds)
    }

    /// A 32BGRA frame filled with one solid color (BGRA byte order), wrapped in
    /// a `CMSampleBuffer` with the given PTS — stands in for a camera or screen
    /// frame so pixel checks are deterministic.
    private func makeSolidFrame(width: Int, height: Int, bgra: (UInt8, UInt8, UInt8, UInt8), seconds: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)

        CVPixelBufferLockBaseAddress(imageBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(imageBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
            for row in 0..<height {
                let rowPtr = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for col in 0..<width {
                    rowPtr[col * 4 + 0] = bgra.0
                    rowPtr[col * 4 + 1] = bgra.1
                    rowPtr[col * 4 + 2] = bgra.2
                    rowPtr[col * 4 + 3] = bgra.3
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer, [])

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            // Exact integer PTS: CMTime(seconds:) rounds through Double and can
            // land one tick below the intended value, which would make the
            // compositor's cadence gate see a sub-frame interval.
            presentationTimeStamp: CMTime(value: Int64(llround(seconds * 60_000)), timescale: 60_000),
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

    /// Reads one BGRA pixel from a 32BGRA buffer. `row` counts from the top of
    /// the image (buffer row 0), while layout rects use the bottom-left
    /// CoreGraphics origin — convert with `row = canvasHeight - ciY`.
    private func pixelAt(_ buffer: CVPixelBuffer, col: Int, row: Int) -> (b: Int, g: Int, r: Int, a: Int)? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.advanced(by: row * bytesPerRow + col * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(ptr[0]), Int(ptr[1]), Int(ptr[2]), Int(ptr[3]))
    }

    /// Pixel at the center of a layout rect, converting the bottom-left rect
    /// coordinates into top-left buffer rows.
    private func pixelAtCenter(of rect: CGRect, in buffer: CVPixelBuffer, canvasHeight: Int) -> (b: Int, g: Int, r: Int, a: Int)? {
        pixelAt(buffer, col: Int(rect.midX), row: Int(CGFloat(canvasHeight) - rect.midY))
    }

    private func assertPixel(_ pixel: (b: Int, g: Int, r: Int, a: Int)?, is bgra: (Int, Int, Int, Int), file: StaticString = #filePath, line: UInt = #line) {
        guard let pixel else {
            XCTFail("no pixel", file: file, line: line)
            return
        }
        XCTAssertEqual(pixel.b, bgra.0, accuracy: 8, file: file, line: line)
        XCTAssertEqual(pixel.g, bgra.1, accuracy: 8, file: file, line: line)
        XCTAssertEqual(pixel.r, bgra.2, accuracy: 8, file: file, line: line)
        XCTAssertEqual(pixel.a, bgra.3, accuracy: 8, file: file, line: line)
    }

    // MARK: - Enum raw-value stability

    func testEnumRawValuesAreStable() {
        XCTAssertEqual(CameraOverlayPosition.topLeft.rawValue, "top_left")
        XCTAssertEqual(CameraOverlayPosition.topRight.rawValue, "top_right")
        XCTAssertEqual(CameraOverlayPosition.bottomLeft.rawValue, "bottom_left")
        XCTAssertEqual(CameraOverlayPosition.bottomRight.rawValue, "bottom_right")
        XCTAssertEqual(CameraOverlayPosition.allCases.count, 4)

        XCTAssertEqual(CameraOverlaySize.small.rawValue, "small")
        XCTAssertEqual(CameraOverlaySize.medium.rawValue, "medium")
        XCTAssertEqual(CameraOverlaySize.large.rawValue, "large")
        XCTAssertEqual(CameraOverlaySize.small.widthFraction, 0.18)
        XCTAssertEqual(CameraOverlaySize.medium.widthFraction, 0.25)
        XCTAssertEqual(CameraOverlaySize.large.widthFraction, 0.34)

        XCTAssertEqual(CameraCaptureResolution.hd720p30.rawValue, "720p30")
        XCTAssertEqual(CameraCaptureResolution.hd1080p30.rawValue, "1080p30")

        // Codable round-trips (these raw values land in user defaults and
        // capture profiles).
        for position in CameraOverlayPosition.allCases {
            XCTAssertEqual(CameraOverlayPosition(rawValue: position.rawValue), position)
        }
        for size in CameraOverlaySize.allCases {
            XCTAssertEqual(CameraOverlaySize(rawValue: size.rawValue), size)
        }
        for resolution in CameraCaptureResolution.allCases {
            XCTAssertEqual(CameraCaptureResolution(rawValue: resolution.rawValue), resolution)
        }
    }

    // MARK: - Layout geometry

    func testOverlayRectForAllFourCorners() {
        let layout = CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: true)
        let aspect = 16.0 / 9.0
        // canvas 200x100, small = 0.18 * 200 = 36 wide, 36 / (16/9) = 20.25 high,
        // margin = 0.02 * min(200, 100) = 2.
        let expected = CGRect(x: 2, y: 100 - 2 - 20.25, width: 36, height: 20.25)
        let rect = layout.overlayRect(canvasWidth: 200, canvasHeight: 100, aspectRatio: aspect)
        XCTAssertEqual(rect.origin.x, expected.origin.x, accuracy: 1e-6)
        XCTAssertEqual(rect.origin.y, expected.origin.y, accuracy: 1e-6)
        XCTAssertEqual(rect.width, expected.width, accuracy: 1e-6)
        XCTAssertEqual(rect.height, expected.height, accuracy: 1e-6)

        // Image coords have a bottom-left origin: "top" rects sit at
        // y = canvasHeight - margin - height, "bottom" at y = margin;
        // "left" at x = margin, "right" at x = canvasWidth - margin - width.
        let cases: [(CameraOverlayPosition, CGFloat, CGFloat)] = [
            (.topLeft, 2, 77.75),
            (.topRight, 200 - 2 - 36, 77.75),
            (.bottomLeft, 2, 2),
            (.bottomRight, 200 - 2 - 36, 2)
        ]
        for (position, x, y) in cases {
            let l = CameraOverlayLayout(position: position, size: .small, borderEnabled: true)
            let r = l.overlayRect(canvasWidth: 200, canvasHeight: 100, aspectRatio: aspect)
            XCTAssertEqual(r.origin.x, x, accuracy: 1e-6, "\(position)")
            XCTAssertEqual(r.origin.y, y, accuracy: 1e-6, "\(position)")
            XCTAssertEqual(r.width, 36, accuracy: 1e-6, "\(position)")
            XCTAssertEqual(r.height, 20.25, accuracy: 1e-6, "\(position)")
        }
    }

    func testOverlayRectScalesWithSize() {
        let aspect = 16.0 / 9.0
        for (size, fraction) in [(CameraOverlaySize.small, 0.18), (CameraOverlaySize.medium, 0.25), (CameraOverlaySize.large, 0.34)] {
            let layout = CameraOverlayLayout(position: .bottomRight, size: size, borderEnabled: false)
            let rect = layout.overlayRect(canvasWidth: 200, canvasHeight: 100, aspectRatio: aspect)
            XCTAssertEqual(rect.width, fraction * 200, accuracy: 1e-6, "\(size)")
            XCTAssertEqual(rect.height, fraction * 200 / aspect, accuracy: 1e-6, "\(size)")
        }
    }

    func testOverlayRectPreservesAspectAndClampsToCanvas() {
        // Portrait camera (9:16) on a wide, short canvas: the rect must be
        // shrunk to the available height while keeping the aspect ratio.
        let layout = CameraOverlayLayout(position: .bottomLeft, size: .small, borderEnabled: false)
        let portrait = 9.0 / 16.0
        let rect = layout.overlayRect(canvasWidth: 100, canvasHeight: 20, aspectRatio: portrait)
        let margin = 0.02 * 20.0
        let maxHeight = 20.0 - 2 * margin // 19.2
        XCTAssertEqual(rect.height, maxHeight, accuracy: 1e-6)
        XCTAssertEqual(rect.width, maxHeight * portrait, accuracy: 1e-6)
        XCTAssertEqual(rect.origin.x, margin, accuracy: 1e-6)
        XCTAssertEqual(rect.origin.y, margin, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(rect.maxX, 100)
        XCTAssertLessThanOrEqual(rect.maxY, 20)
    }

    func testTinyCanvasClampsOverlayInsideCanvas() {
        // Even on degenerate canvases the rect must stay inside the canvas
        // with a non-negative origin, for every position/size/aspect.
        for width in [1, 2, 4, 6, 10] {
            for height in [1, 2, 4, 6, 10] {
                for position in CameraOverlayPosition.allCases {
                    for size in CameraOverlaySize.allCases {
                        for aspect in [9.0 / 16.0, 1.0, 16.0 / 9.0] {
                            let layout = CameraOverlayLayout(position: position, size: size, borderEnabled: true)
                            let rect = layout.overlayRect(canvasWidth: width, canvasHeight: height, aspectRatio: aspect)
                            XCTAssertFalse(rect.isNull, "w=\(width) h=\(height) \(position) \(size) aspect=\(aspect)")
                            XCTAssertGreaterThanOrEqual(rect.minX, 0)
                            XCTAssertGreaterThanOrEqual(rect.minY, 0)
                            XCTAssertLessThanOrEqual(rect.maxX, CGFloat(width) + 1e-6)
                            XCTAssertLessThanOrEqual(rect.maxY, CGFloat(height) + 1e-6)
                        }
                    }
                }
            }
        }
    }

    func testBorderRectOutsetAndCornerRadiusScaling() {
        let layout = CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: true)
        let aspect = 16.0 / 9.0
        let rect = layout.overlayRect(canvasWidth: 200, canvasHeight: 100, aspectRatio: aspect)
        let border = layout.borderRect(canvasWidth: 200, canvasHeight: 100, aspectRatio: aspect)
        let borderWidth = 0.006 * rect.height

        // Border rect is the overlay rect outset by the border width.
        XCTAssertEqual(border.minX, rect.minX - borderWidth, accuracy: 1e-6)
        XCTAssertEqual(border.minY, rect.minY - borderWidth, accuracy: 1e-6)
        XCTAssertEqual(border.width, rect.width + 2 * borderWidth, accuracy: 1e-6)
        XCTAssertEqual(border.height, rect.height + 2 * borderWidth, accuracy: 1e-6)
        XCTAssertTrue(border.contains(rect))

        // Corner radius is 0.08 of the overlay height.
        let radius = layout.cornerRadius(canvasWidth: 200, canvasHeight: 100, aspectRatio: aspect)
        XCTAssertEqual(radius, 0.08 * rect.height, accuracy: 1e-6)

        // Radius is clamped to half the smaller overlay dimension.
        let extreme = CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: true, cornerRadiusFraction: 2.0)
        let clamped = extreme.cornerRadius(canvasWidth: 200, canvasHeight: 100, aspectRatio: aspect)
        XCTAssertEqual(clamped, min(rect.width, rect.height) / 2, accuracy: 1e-6)

        // Border rect stays inside the canvas even at a canvas edge.
        let edge = layout.borderRect(canvasWidth: 200, canvasHeight: 100, aspectRatio: aspect)
        XCTAssertGreaterThanOrEqual(edge.minX, 0)
        XCTAssertGreaterThanOrEqual(edge.minY, 0)
    }

    // MARK: - Single-display + overlay emission

    func testSingleDisplayOverlayEmitsEveryFrameWithOverlayPixels() throws {
        let compositor = FrameCompositor()
        compositor.configureSingleDisplay(width: 64, height: 36, fps: 60)
        let layout = CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: true)
        compositor.setCameraOverlay(layout)

        let output = OutputRecorder()
        compositor.outputHandler = { output.record($0) }

        // Solid red "camera" frame at t=1.0 (32x18 → 16:9).
        compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 0, 255, 255), seconds: 1.0))

        // 10 blue screen frames at 60 fps.
        for i in 0..<10 {
            compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (255, 0, 0, 255), seconds: 1 + Double(i) / 60))
        }

        XCTAssertEqual(output.count, 10)
        let rect = layout.overlayRect(canvasWidth: 64, canvasHeight: 36, aspectRatio: 32.0 / 18.0)

        for (index, buffer) in output.buffers.enumerated() {
            let pixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(buffer))
            XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), 64)
            XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer), 36)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixelBuffer), kCVPixelFormatType_32BGRA)
            // Cadence: one output per pushed frame, PTS tracks the input PTS.
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            XCTAssertEqual(pts.seconds, 1 + Double(index) / 60, accuracy: 1e-3)
            // Overlay center shows the camera color (red), background stays blue.
            assertPixel(pixelAtCenter(of: rect, in: pixelBuffer, canvasHeight: 36), is: (0, 0, 255, 255))
            assertPixel(pixelAt(pixelBuffer, col: 62, row: 34), is: (255, 0, 0, 255))
        }
    }

    func testPushCameraFrameAloneEmitsNothing() throws {
        // Single-display mode.
        let single = FrameCompositor()
        single.configureSingleDisplay(width: 64, height: 36, fps: 60)
        single.setCameraOverlay(CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: true))
        let singleOutput = OutputRecorder()
        single.outputHandler = { singleOutput.record($0) }
        for i in 0..<5 {
            single.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 0, 255, 255), seconds: 1 + Double(i) / 30))
        }
        XCTAssertEqual(singleOutput.count, 0)

        // Dual mode.
        let dual = FrameCompositor()
        dual.configure(display1Width: 32, display1Height: 18, display2Width: 32, display2Height: 18, fps: 60)
        dual.setCameraOverlay(CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: true))
        let dualOutput = OutputRecorder()
        dual.outputHandler = { dualOutput.record($0) }
        for i in 0..<5 {
            dual.pushCameraFrame(try makeSolidFrame(width: 16, height: 9, bgra: (0, 0, 255, 255), seconds: 1 + Double(i) / 30))
        }
        XCTAssertEqual(dualOutput.count, 0)
    }

    func testStaleCameraFrameOmitsOverlayButKeepsCadence() throws {
        let compositor = FrameCompositor()
        compositor.configureSingleDisplay(width: 64, height: 36, fps: 60)
        let layout = CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: false)
        compositor.setCameraOverlay(layout)

        let output = OutputRecorder()
        compositor.outputHandler = { output.record($0) }

        // Camera frame frozen at t=1.0.
        compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 0, 255, 255), seconds: 1.0))

        // 60 screen frames at 60 fps → t up to ~1.983; camera age reaches 0.5s at i=30.
        for i in 0..<60 {
            compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (255, 0, 0, 255), seconds: 1 + Double(i) / 60))
        }

        // Emission cadence is unchanged: all 60 frames emit.
        XCTAssertEqual(output.count, 60)
        let rect = layout.overlayRect(canvasWidth: 64, canvasHeight: 36, aspectRatio: 32.0 / 18.0)

        // Fresh (age < 0.5s): overlay drawn.
        for index in [0, 29] {
            guard let buffer = output.buffers[safe: index],
                  let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
                XCTFail("missing output \(index)")
                continue
            }
            assertPixel(pixelAtCenter(of: rect, in: pixelBuffer, canvasHeight: 36), is: (0, 0, 255, 255))
        }
        // Stale (age >= 0.5s): overlay omitted, pixel returns to background,
        // but the frame is still emitted.
        for index in [30, 59] {
            guard let buffer = output.buffers[safe: index],
                  let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
                XCTFail("missing output \(index)")
                continue
            }
            assertPixel(pixelAtCenter(of: rect, in: pixelBuffer, canvasHeight: 36), is: (255, 0, 0, 255))
        }
    }

    // MARK: - Idle screen: camera keeps the overlay moving

    /// ScreenCaptureKit stops delivering complete frames while the display is
    /// still. Camera frames must then re-emit the last screen frame at the
    /// camera's rate, stamped with the camera PTS, and the screen takes over
    /// again as soon as it changes.
    func testIdleScreenCameraFramesKeepOverlayUpdating() throws {
        let compositor = FrameCompositor()
        compositor.configureSingleDisplay(width: 64, height: 36, fps: 60)
        let layout = CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: false)
        compositor.setCameraOverlay(layout)

        let output = OutputRecorder()
        compositor.outputHandler = { output.record($0) }
        let rect = layout.overlayRect(canvasWidth: 64, canvasHeight: 36, aspectRatio: 32.0 / 18.0)

        let red: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 255, 255)
        let green: (UInt8, UInt8, UInt8, UInt8) = (0, 255, 0, 255)

        compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: red, seconds: 1.0))
        compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (255, 0, 0, 255), seconds: 1.0))
        XCTAssertEqual(output.count, 1)

        // A camera frame right after a screen frame doesn't count as idle yet.
        compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: green, seconds: 1.0 + 1.0 / 30))
        XCTAssertEqual(output.count, 1)

        // The screen stays still: 10 camera frames at 30 fps, alternating colour.
        let cameraTimes = (0..<10).map { 1.1 + Double($0) / 30 }
        for (index, time) in cameraTimes.enumerated() {
            compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: index.isMultiple(of: 2) ? red : green, seconds: time))
        }
        XCTAssertEqual(output.count, 11)
        for (index, time) in cameraTimes.enumerated() {
            let buffer = try XCTUnwrap(output.buffers[safe: index + 1])
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer).seconds, time, accuracy: 1e-3)
            let pixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(buffer))
            let expected: (Int, Int, Int, Int) = index.isMultiple(of: 2) ? (0, 0, 255, 255) : (0, 255, 0, 255)
            assertPixel(pixelAtCenter(of: rect, in: pixelBuffer, canvasHeight: 36), is: expected)
            // The last screen frame (blue) is reused underneath.
            assertPixel(pixelAt(pixelBuffer, col: 62, row: 34), is: (255, 0, 0, 255))
        }

        // The screen changes again: it drives emission from here on.
        let resume = cameraTimes[cameraTimes.count - 1] + 1.0 / 30
        compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (0, 255, 255, 255), seconds: resume))
        XCTAssertEqual(output.count, 12)
        let resumed = try XCTUnwrap(output.last.flatMap(CMSampleBufferGetImageBuffer))
        assertPixel(pixelAt(resumed, col: 62, row: 34), is: (0, 255, 255, 255))

        // ...so a camera frame shortly after it waits for the idle gap again.
        compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: red, seconds: resume + 1.0 / 30))
        XCTAssertEqual(output.count, 12)

        var previousPTS = -1.0
        for buffer in output.buffers {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            XCTAssertGreaterThan(pts, previousPTS)
            previousPTS = pts
        }
    }

    /// While the screen updates at full rate, camera frames (which carry a
    /// slightly older PTS than the screen frame they arrive next to) must
    /// never add extra composites: one output per screen frame, screen PTS.
    func testActiveScreenIsNotInterleavedWithCameraRefreshes() throws {
        let compositor = FrameCompositor()
        compositor.configureSingleDisplay(width: 64, height: 36, fps: 60)
        compositor.setCameraOverlay(CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: true))

        let output = OutputRecorder()
        compositor.outputHandler = { output.record($0) }

        for i in 0..<60 {
            let screenTime = 1 + Double(i) / 60
            compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (255, 0, 0, 255), seconds: screenTime))
            if i.isMultiple(of: 2) {
                compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 0, 255, 255), seconds: screenTime - 0.03))
            }
        }

        XCTAssertEqual(output.count, 60)
        for (index, buffer) in output.buffers.enumerated() {
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer).seconds, 1 + Double(index) / 60, accuracy: 1e-3)
        }
    }

    /// A camera frame a few ms newer than the screen frame being composited
    /// is still drawn instead of blinking the overlay out.
    func testCameraFrameSlightlyAheadOfScreenIsDrawn() throws {
        let compositor = FrameCompositor()
        compositor.configureSingleDisplay(width: 64, height: 36, fps: 60)
        let layout = CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: false)
        compositor.setCameraOverlay(layout)

        let output = OutputRecorder()
        compositor.outputHandler = { output.record($0) }

        compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 0, 255, 255), seconds: 1.02))
        compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (255, 0, 0, 255), seconds: 1.0))

        XCTAssertEqual(output.count, 1)
        let pixelBuffer = try XCTUnwrap(output.last.flatMap(CMSampleBufferGetImageBuffer))
        let rect = layout.overlayRect(canvasWidth: 64, canvasHeight: 36, aspectRatio: 32.0 / 18.0)
        assertPixel(pixelAtCenter(of: rect, in: pixelBuffer, canvasHeight: 36), is: (0, 0, 255, 255))
    }

    /// Dual side-by-side mode refreshes both displays under a new camera frame
    /// while the screens are idle.
    func testDualModeIdleScreensRefreshFromCamera() throws {
        let compositor = FrameCompositor()
        compositor.configure(display1Width: 32, display1Height: 18, display2Width: 32, display2Height: 18, fps: 60)
        let layout = CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: false)
        compositor.setCameraOverlay(layout)

        let output = OutputRecorder()
        compositor.outputHandler = { output.record($0) }

        compositor.pushPrimaryFrame(try makeSolidFrame(width: 32, height: 18, bgra: (255, 0, 0, 255), seconds: 1.0))
        compositor.pushSecondaryFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 255, 0, 255), seconds: 1.0))
        XCTAssertEqual(output.count, 1)

        compositor.pushCameraFrame(try makeSolidFrame(width: 16, height: 9, bgra: (0, 0, 255, 255), seconds: 1.2))
        XCTAssertEqual(output.count, 2)
        let buffer = try XCTUnwrap(output.last)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer).seconds, 1.2, accuracy: 1e-3)
        let pixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(buffer))
        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), 64)
        let rect = layout.overlayRect(canvasWidth: 64, canvasHeight: 18, aspectRatio: 16.0 / 9.0)
        assertPixel(pixelAtCenter(of: rect, in: pixelBuffer, canvasHeight: 18), is: (0, 0, 255, 255))
        assertPixel(pixelAt(pixelBuffer, col: 50, row: 9), is: (0, 255, 0, 255))
    }

    // MARK: - Dual mode + overlay

    func testDualModeWithOverlayKeepsCadenceAndDrawsOverlay() throws {
        let compositor = FrameCompositor()
        compositor.configure(display1Width: 32, display1Height: 18, display2Width: 32, display2Height: 18, fps: 60)
        let layout = CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: true)
        compositor.setCameraOverlay(layout)

        let output = OutputRecorder()
        compositor.outputHandler = { output.record($0) }

        compositor.pushCameraFrame(try makeSolidFrame(width: 16, height: 9, bgra: (0, 0, 255, 255), seconds: 1.0))

        // Interleaved primary (blue) / secondary (green) pushes at 60 fps.
        for i in 0..<10 {
            compositor.pushPrimaryFrame(try makeSolidFrame(width: 32, height: 18, bgra: (255, 0, 0, 255), seconds: 1 + Double(i) / 60))
            compositor.pushSecondaryFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 255, 0, 255), seconds: 1 + Double(i) / 60))
        }

        // Cadence is driven by the screen frames only (the camera pushed once
        // at t=1.0 never gates emission): the first push finds no secondary
        // yet, every later push finds both displays and emits — the dual path
        // keeps its existing behavior of emitting per push with monotonically
        // increasing PTS.
        XCTAssertEqual(output.count, 19)
        var previousPTS: Double = -1
        for buffer in output.buffers {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            XCTAssertGreaterThan(pts, previousPTS)
            previousPTS = pts
        }
        let rect = layout.overlayRect(canvasWidth: 64, canvasHeight: 18, aspectRatio: 16.0 / 9.0)

        let first = try XCTUnwrap(CMSampleBufferGetImageBuffer(output.buffers[0]))
        XCTAssertEqual(CVPixelBufferGetWidth(first), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(first), 18)
        // Overlay (red) on top of the left display (blue) in the top-left corner.
        assertPixel(pixelAtCenter(of: rect, in: first, canvasHeight: 18), is: (0, 0, 255, 255))
        // Left display background below the overlay, right display untouched.
        assertPixel(pixelAt(first, col: 10, row: 16), is: (255, 0, 0, 255))
        assertPixel(pixelAt(first, col: 50, row: 9), is: (0, 255, 0, 255))
    }

    // MARK: - reset / setCameraOverlay(nil) / clearCameraFrame

    func testResetAndClearingOverlayDropCameraState() throws {
        let compositor = FrameCompositor()
        compositor.configureSingleDisplay(width: 64, height: 36, fps: 60)
        let layout = CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: true)
        compositor.setCameraOverlay(layout)

        let output = OutputRecorder()
        compositor.outputHandler = { output.record($0) }
        let rect = layout.overlayRect(canvasWidth: 64, canvasHeight: 36, aspectRatio: 32.0 / 18.0)

        func centerPixel(_ index: Int) -> (b: Int, g: Int, r: Int, a: Int)? {
            guard let buffer = output.buffers[safe: index],
                  let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
            return pixelAtCenter(of: rect, in: pixelBuffer, canvasHeight: 36)
        }

        // 1: camera + screen frame → overlay drawn.
        compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 0, 255, 255), seconds: 1.0))
        compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (255, 0, 0, 255), seconds: 1.0))
        XCTAssertEqual(output.count, 1)
        assertPixel(centerPixel(0), is: (0, 0, 255, 255))

        // 2: reset() clears the camera frame → next frame emits without overlay.
        compositor.reset()
        compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (255, 0, 0, 255), seconds: 1 + 1.0 / 60))
        XCTAssertEqual(output.count, 2)
        assertPixel(centerPixel(1), is: (255, 0, 0, 255))

        // 3: setCameraOverlay(nil) → even a fresh camera frame draws nothing.
        compositor.setCameraOverlay(layout)
        compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 0, 255, 255), seconds: 1 + 2.0 / 60))
        compositor.setCameraOverlay(nil)
        compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (255, 0, 0, 255), seconds: 1 + 2.0 / 60))
        XCTAssertEqual(output.count, 3)
        assertPixel(centerPixel(2), is: (255, 0, 0, 255))

        // 4: clearCameraFrame() → no overlay until a new camera frame arrives.
        compositor.setCameraOverlay(layout)
        compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 0, 255, 255), seconds: 1 + 3.0 / 60))
        compositor.clearCameraFrame()
        compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (255, 0, 0, 255), seconds: 1 + 3.0 / 60))
        XCTAssertEqual(output.count, 4)
        assertPixel(centerPixel(3), is: (255, 0, 0, 255))

        // 5: pushing a fresh camera frame afterwards restores the overlay.
        compositor.pushCameraFrame(try makeSolidFrame(width: 32, height: 18, bgra: (0, 0, 255, 255), seconds: 1 + 4.0 / 60))
        compositor.pushPrimaryFrame(try makeSolidFrame(width: 64, height: 36, bgra: (255, 0, 0, 255), seconds: 1 + 4.0 / 60))
        XCTAssertEqual(output.count, 5)
        assertPixel(centerPixel(4), is: (0, 0, 255, 255))
    }

    // MARK: - Concurrency hammer (run under --sanitize=thread)

    /// Screen frames, camera frames, overlay changes and reconfigurations all
    /// arrive on different queues in production. Run under
    /// `swift test --sanitize=thread` to catch unguarded state.
    func testConcurrentCameraOverlayAndFramesDoNotRace() throws {
        let compositor = FrameCompositor()
        compositor.configure(display1Width: 32, display1Height: 18, display2Width: 32, display2Height: 18, fps: 60)
        compositor.outputHandler = { _ in }

        let layouts: [CameraOverlayLayout?] = [
            nil,
            CameraOverlayLayout(position: .topLeft, size: .small, borderEnabled: true),
            CameraOverlayLayout(position: .bottomRight, size: .large, borderEnabled: false),
            CameraOverlayLayout(position: .topRight, size: .medium, borderEnabled: true)
        ]
        let primaryFrames = try (0..<60).map { try makeSolidFrame(width: 32, height: 18, bgra: (255, 0, 0, 255), seconds: 1 + Double($0) / 60) }
        let secondaryFrames = try (0..<60).map { try makeSolidFrame(width: 32, height: 18, bgra: (0, 255, 0, 255), seconds: 1 + Double($0) / 60) }
        let cameraFrames = try (0..<60).map { try makeSolidFrame(width: 16, height: 9, bgra: (0, 0, 255, 255), seconds: 1 + Double($0) / 30) }

        DispatchQueue.concurrentPerform(iterations: 5) { lane in
            for index in 0..<60 {
                switch lane {
                case 0:
                    compositor.pushPrimaryFrame(primaryFrames[index])
                case 1:
                    compositor.pushSecondaryFrame(secondaryFrames[index])
                case 2:
                    compositor.pushCameraFrame(cameraFrames[index])
                case 3:
                    compositor.setCameraOverlay(layouts[index % layouts.count])
                default:
                    if index.isMultiple(of: 5) {
                        compositor.reset()
                        if index.isMultiple(of: 10) {
                            compositor.configure(display1Width: 32, display1Height: 18, display2Width: 32, display2Height: 18, fps: 60)
                        } else {
                            compositor.configureSingleDisplay(width: 32, height: 18, fps: 60)
                        }
                    }
                }
            }
        }
    }

    // MARK: - CameraCapture headless smoke

    /// No camera hardware or TCC grant is needed for these: they only touch
    /// the statics and a fresh instance.
    func testCameraCaptureHeadlessSmoke() {
        let status = CameraCapture.authorizationStatus()
        XCTAssertTrue([.authorized, .denied, .notDetermined, .restricted].contains(status))

        // Must not crash without a camera (headless CI): may simply be empty.
        let devices = CameraCapture.availableDevices()
        for device in devices {
            XCTAssertFalse(device.uniqueID.isEmpty)
            XCTAssertEqual(device.id, device.uniqueID)
        }

        let capture = CameraCapture()
        XCTAssertFalse(capture.isRunning)
        XCTAssertNil(capture.secondsSinceLastFrame())
        capture.setFrameHandler { _ in }
        capture.setErrorHandler { _ in }
        capture.stop() // no-op on a fresh instance
        XCTAssertFalse(capture.isRunning)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private final class OutputRecorder: @unchecked Sendable {
    // Guarded by `lock`; the compositor calls back on whichever thread pushed the frame.
    private let lock = NSLock()
    private var recorded: [CMSampleBuffer] = []

    func record(_ buffer: CMSampleBuffer) {
        lock.lock()
        recorded.append(buffer)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    var buffers: [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var last: CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last
    }
}
