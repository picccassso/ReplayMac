import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import os.log

public final class FrameCompositor: @unchecked Sendable {
    // @unchecked: mutable state is only touched inside `lock`; drawing works on copies taken under it.
    public typealias OutputHandler = @Sendable (CMSampleBuffer) -> Void

    private enum DisplayIndex: Int {
        case primary = 0
        case secondary = 1
    }

    private struct DisplayFrame {
        let sampleBuffer: CMSampleBuffer
        let width: Int
        let height: Int
    }

    /// The output size, copied out of the lock along with the pool so drawing
    /// never reads dimensions that `configure` may be changing.
    private struct Canvas: Equatable {
        let width: Int
        let height: Int
    }

    /// Cache key for the overlay mask/border images. The images are rebuilt
    /// only when one of these changes — never per frame.
    private struct OverlayCacheKey: Equatable {
        let canvas: Canvas
        let layout: CameraOverlayLayout
        let aspectRatio: Double
    }

    /// Cached, immutable `CIImage`s used to draw the overlay, all positioned at
    /// their final place in canvas coordinates (CIImage pixel-aligns extents,
    /// so mask / camera / border share the same aligned extent).
    private struct OverlayCache {
        /// Rounded-rect mask, extent = overlay rect size.
        let mask: CIImage
        /// Fully transparent image, extent = overlay rect size; the
        /// `CIBlendWithMask` background that leaves the camera visible only
        /// inside the rounded rect.
        let transparent: CIImage
        /// White border ring (outer rounded rect minus the overlay rect),
        /// extent = border rect size. nil when the border is disabled.
        let border: CIImage?
    }

    /// Everything `drawOverlay` needs, copied out of the lock together with
    /// the camera frame so drawing never reads state `setCameraOverlay` /
    /// `pushCameraFrame` may be changing.
    private struct OverlayAssets {
        let camera: CMSampleBuffer
        let rect: CGRect
        let borderRect: CGRect
        let mask: CIImage
        let transparent: CIImage
        let border: CIImage?
    }

    private let logger = Logger(subsystem: "com.replaycap", category: "FrameCompositor")
    private let lock = NSLock()
    /// Serializes "reserve output PTS → render → hand to outputHandler", so
    /// composites reach the encoder in PTS order now that both the screen
    /// queue(s) and the camera queue can trigger one. Always taken before
    /// `lock`, never while holding it.
    private let emitLock = NSLock()
    private var primaryFrame: DisplayFrame?
    private var secondaryFrame: DisplayFrame?
    private var compositeWidth: Int = 0
    private var compositeHeight: Int = 0
    /// true = single-display mode (`configureSingleDisplay`), false = dual
    /// side-by-side mode (`configure`).
    private var singleDisplayMode = false
    private var targetFrameDuration = CMTime(value: 1, timescale: 60)
    private var pixelBufferPool: CVPixelBufferPool?
    private var _outputHandler: OutputHandler?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    // Explicit sRGB rather than device RGB, so compositing stays in the same
    // space as the sRGB capture and the BT.709 tags the encoder writes.
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // Camera overlay state. While the screen updates, screen-frame PTS drives
    // emission; a camera frame only re-emits the last screen frame once the
    // screen has gone idle (`emitCameraRefreshIfScreenIdle`).
    private var cameraOverlay: CameraOverlayLayout?
    private var cameraFrame: CMSampleBuffer?
    private var cameraFramePTS: CMTime = .invalid
    private var overlayCacheKey: OverlayCacheKey?
    private var overlayCache: OverlayCache?

    private var primaryTimeoutCounter = 0
    private var secondaryTimeoutCounter = 0
    private static let maxStaleFrames = 3

    private var compositeFrameCount: Int64 = 0
    private var syntheticPTSBasis: CMTime?
    private var lastSyntheticPTS: CMTime = .zero
    private var lastOutputPTS: CMTime?
    /// true when the last emitted composite was a camera refresh (the screen
    /// was idle), false when it came from a screen frame.
    private var lastEmitWasCameraRefresh = false

    /// How long the screen must have been idle before camera frames start
    /// re-emitting the last screen frame. Two camera frames at 30 fps: long
    /// enough that a screen which is actively updating (even below the target
    /// fps, e.g. a game at 40 fps) keeps driving emission on its own.
    private static let minimumScreenIdleInterval = CMTime(value: 1, timescale: 15)

    /// How far a camera frame may be AHEAD of the screen frame it is drawn on.
    /// Camera and screen frames arrive on different queues, so the newest
    /// camera frame can carry a PTS a few ms past a screen frame that is still
    /// being composited; refusing it would blink the overlay out for a frame.
    private static let cameraLeadTolerance: Double = 0.05

    public var outputHandler: OutputHandler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _outputHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _outputHandler = newValue
        }
    }

    public init() {}

    public func configure(display1Width: Int, display1Height: Int,
                          display2Width: Int, display2Height: Int,
                          fps: Int) {
        lock.lock()
        defer { lock.unlock() }

        // Dual side-by-side mode.
        singleDisplayMode = false

        let totalWidth = display1Width + display2Width
        let maxHeight = max(display1Height, display2Height)

        compositeWidth = totalWidth
        compositeHeight = maxHeight
        targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

        pixelBufferPool = Self.makePixelBufferPool(width: totalWidth, height: maxHeight)
        lastOutputPTS = nil
        lastEmitWasCameraRefresh = false
        lastSyntheticPTS = .zero
        syntheticPTSBasis = nil
    }

    /// Single-display mode: the canvas is exactly `width` x `height` and every
    /// primary screen frame is composited full-canvas (with the camera overlay
    /// on top when one is set). Uses the same 32BGRA pool as `configure(...)`.
    public func configureSingleDisplay(width: Int, height: Int, fps: Int) {
        lock.lock()
        defer { lock.unlock() }

        singleDisplayMode = true
        compositeWidth = width
        compositeHeight = height
        targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

        pixelBufferPool = Self.makePixelBufferPool(width: width, height: height)
        lastOutputPTS = nil
        lastEmitWasCameraRefresh = false
        lastSyntheticPTS = .zero
        syntheticPTSBasis = nil
    }

    /// Shared 32BGRA pool creation (IOSurface + Metal compatible, min 8
    /// buffers) used by both dual and single-display modes.
    private static func makePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let pixelFormat = kCVPixelFormatType_32BGRA

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 8
        ]

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        return pool
    }

    /// Sets (or clears, with nil) the camera overlay layout. Cached mask/border
    /// images are rebuilt lazily on the next frame only if (canvas, layout,
    /// aspect) actually changed.
    public func setCameraOverlay(_ layout: CameraOverlayLayout?) {
        lock.lock()
        cameraOverlay = layout
        lock.unlock()
    }

    /// Stores the latest camera frame + PTS under lock. While the screen is
    /// actively updating, screen frames drive emission and the camera frame is
    /// only composited on top of them. ScreenCaptureKit only delivers a
    /// complete frame when the display changes, though, so on a still screen
    /// the camera frame also re-emits the last screen frame (see
    /// `emitCameraRefreshIfScreenIdle`); otherwise the overlay would freeze
    /// until something on screen moved.
    public func pushCameraFrame(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }
        lock.lock()
        cameraFrame = sampleBuffer
        cameraFramePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lock.unlock()
        emitCameraRefreshIfScreenIdle()
    }

    /// Re-composites the last screen frame(s) under the newest camera frame,
    /// stamped with the camera frame's PTS (both are host-clock based), when
    /// no composite has been emitted for a while. Needs at least one screen
    /// composite first: the camera alone never starts emission.
    private func emitCameraRefreshIfScreenIdle() {
        // A composite already in flight means the screen is active; never
        // block the camera queue waiting for it.
        guard emitLock.try() else { return }
        defer { emitLock.unlock() }

        lock.lock()
        guard cameraOverlay != nil,
              let lastOutputPTS,
              compositeWidth > 0, compositeHeight > 0,
              let pool = pixelBufferPool,
              let primary = primaryFrame else {
            lock.unlock()
            return
        }
        let secondary = secondaryFrame
        if !singleDisplayMode && secondary == nil {
            lock.unlock()
            return
        }
        let pts = cameraFramePTS
        guard Self.ptsIsValid(pts) else {
            lock.unlock()
            return
        }
        // After a screen frame, wait until the screen has clearly gone idle.
        // Between camera refreshes, half a frame of slack absorbs camera
        // timestamp jitter so a 30 fps camera is never halved by the gate.
        let requiredGap = lastEmitWasCameraRefresh
            ? CMTimeMultiplyByRatio(targetFrameDuration, multiplier: 1, divisor: 2)
            : CMTimeMaximum(CMTimeMultiply(targetFrameDuration, multiplier: 2), Self.minimumScreenIdleInterval)
        guard CMTimeCompare(CMTimeSubtract(pts, lastOutputPTS), requiredGap) >= 0 else {
            lock.unlock()
            return
        }
        let canvas = Canvas(width: compositeWidth, height: compositeHeight)
        guard let overlayAssets = overlayAssetsLocked(canvas: canvas, screenPTS: pts) else {
            lock.unlock()
            return
        }
        self.lastOutputPTS = pts
        lastEmitWasCameraRefresh = true
        compositeFrameCount += 1
        let handler = _outputHandler
        lock.unlock()

        let compositeBuffer: CMSampleBuffer?
        if singleDisplayMode {
            compositeBuffer = singleModeComposite(
                frame: primary,
                presentationTimeStamp: pts,
                pool: pool,
                canvas: canvas,
                overlayAssets: overlayAssets
            )
        } else if let secondary {
            compositeBuffer = composite(
                primary: primary,
                secondary: secondary,
                presentationTimeStamp: pts,
                pool: pool,
                canvas: canvas,
                overlayAssets: overlayAssets
            )
        } else {
            compositeBuffer = nil
        }
        if let buffer = compositeBuffer {
            handler?(buffer)
        }
    }

    /// Drops the stored camera frame; subsequent composites have no overlay
    /// until a fresh camera frame arrives.
    public func clearCameraFrame() {
        lock.lock()
        cameraFrame = nil
        cameraFramePTS = .invalid
        lock.unlock()
    }

    public func pushPrimaryFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let frame = DisplayFrame(sampleBuffer: sampleBuffer, width: width, height: height)
        processFrame(frame, for: .primary)
    }

    public func pushSecondaryFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let frame = DisplayFrame(sampleBuffer: sampleBuffer, width: width, height: height)
        processFrame(frame, for: .secondary)
    }

    private func processFrame(_ frame: DisplayFrame, for display: DisplayIndex) {
        emitLock.lock()
        defer { emitLock.unlock() }
        lock.lock()

        if singleDisplayMode, display == .secondary {
            // Single-display mode renders only the primary display; secondary
            // pushes are ignored entirely.
            lock.unlock()
            return
        }

        switch display {
        case .primary:
            primaryFrame = frame
            primaryTimeoutCounter = 0
        case .secondary:
            secondaryFrame = frame
            secondaryTimeoutCounter = 0
        }

        guard compositeWidth > 0, compositeHeight > 0, let pool = pixelBufferPool else {
            lock.unlock()
            return
        }

        let handler = _outputHandler
        let canvas = Canvas(width: compositeWidth, height: compositeHeight)

        let primary = primaryFrame
        let secondary = secondaryFrame

        if singleDisplayMode {
            // Single-display emission: every primary frame goes through the
            // same cadence gate as dual mode. The camera never gates or
            // triggers emission.
            guard shouldEmitFrame(preferred: frame.sampleBuffer) else {
                lock.unlock()
                return
            }
            let pts = reserveOutputPTS(preferred: frame.sampleBuffer)
            compositeFrameCount += 1
            if compositeFrameCount <= 5 || compositeFrameCount % 60 == 0 {
                logger.debug("Single-display composite #\(self.compositeFrameCount) PTS=\(pts.seconds) valid=\(pts.isValid)")
            }
            let overlayAssets = overlayAssetsLocked(canvas: canvas, screenPTS: pts)
            lock.unlock()

            let compositeBuffer = singleModeComposite(
                frame: frame,
                presentationTimeStamp: pts,
                pool: pool,
                canvas: canvas,
                overlayAssets: overlayAssets
            )
            if let buffer = compositeBuffer {
                handler?(buffer)
            }
            return
        }

        if primary != nil && secondary != nil {
            guard shouldEmitFrame(preferred: frame.sampleBuffer, fallback: primary!.sampleBuffer) else {
                lock.unlock()
                return
            }
            let pts = reserveOutputPTS(preferred: frame.sampleBuffer, fallback: primary!.sampleBuffer)
            let primaryFrame = primary!
            let secondaryFrame = secondary!
            compositeFrameCount += 1
            if compositeFrameCount <= 5 || compositeFrameCount % 60 == 0 {
                logger.debug("Composite #\(self.compositeFrameCount) PTS=\(pts.seconds) valid=\(pts.isValid)")
            }
            let overlayAssets = overlayAssetsLocked(canvas: canvas, screenPTS: pts)
            lock.unlock()

            let compositeBuffer = composite(
                primary: primaryFrame,
                secondary: secondaryFrame,
                presentationTimeStamp: pts,
                pool: pool,
                canvas: canvas,
                overlayAssets: overlayAssets
            )
            if let buffer = compositeBuffer {
                handler?(buffer)
            }
            return
        }

        primaryTimeoutCounter += 1
        secondaryTimeoutCounter += 1

        let primaryStale = primary == nil && primaryTimeoutCounter > Self.maxStaleFrames
        let secondaryStale = secondary == nil && secondaryTimeoutCounter > Self.maxStaleFrames
        let staleFrame = (primaryStale || secondaryStale) ? primary ?? secondary : nil
        let staleFramePTS = staleFrame.flatMap { frame -> CMTime? in
            guard shouldEmitFrame(preferred: frame.sampleBuffer) else { return nil }
            return reserveOutputPTS(preferred: frame.sampleBuffer)
        }
        let logsStaleComposite = compositeFrameCount <= 5

        lock.unlock()

        if primaryStale || secondaryStale {
            if let handler, let frame = staleFrame, let pts = staleFramePTS {
                let compositeBuffer = singleDisplayComposite(
                    frame: frame,
                    isPrimary: primary != nil,
                    presentationTimeStamp: pts,
                    pool: pool,
                    canvas: canvas
                )
                if logsStaleComposite {
                    let pts = compositeBuffer.map { CMSampleBufferGetPresentationTimeStamp($0) }
                    logger.debug("Stale single-display composite PTS=\(pts?.seconds ?? -1) valid=\(pts?.isValid ?? false)")
                }
                if let buffer = compositeBuffer {
                    handler(buffer)
                }
            }
        }
    }

    private func composite(
        primary: DisplayFrame,
        secondary: DisplayFrame,
        presentationTimeStamp pts: CMTime,
        pool: CVPixelBufferPool,
        canvas: Canvas,
        overlayAssets: OverlayAssets? = nil
    ) -> CMSampleBuffer? {
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { return nil }

        if let overlayAssets {
            // With an overlay the whole scene is composed in the image graph
            // (source-over) and rendered in one full-canvas pass — a separate
            // bounded render of the masked camera would replace (not blend
            // over) its region and punch transparent holes into the canvas.
            let bounds = CGRect(x: 0, y: 0, width: CGFloat(canvas.width), height: CGFloat(canvas.height))
            var scene = CIImage(color: .black).cropped(to: bounds)
            scene = displaySceneImage(primary, atX: 0, canvas: canvas).applyingFilter(
                "CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: scene]
            )
            scene = displaySceneImage(secondary, atX: primary.width, canvas: canvas).applyingFilter(
                "CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: scene]
            )
            if let overlayScene = overlaySceneImage(assets: overlayAssets, onTopOf: scene) {
                scene = overlayScene
            }
            ciContext.render(scene, to: outBuffer, bounds: bounds, colorSpace: colorSpace)
        } else {
            clear(outBuffer, canvas: canvas)
            drawPixelBuffer(primary.sampleBuffer, into: outBuffer, canvas: canvas, atX: 0, width: primary.width, height: primary.height)
            drawPixelBuffer(secondary.sampleBuffer, into: outBuffer, canvas: canvas, atX: primary.width, width: secondary.width, height: secondary.height)
        }

        return makeSampleBuffer(from: outBuffer, presentationTimeStamp: pts, sourceDuration: CMSampleBufferGetDuration(primary.sampleBuffer))
    }

    /// Single-display mode composite: the screen frame is drawn as the
    /// FULL-canvas base render (no black clear — the scaled screen image
    /// covers the whole canvas), with the camera overlay on top when fresh.
    private func singleModeComposite(
        frame: DisplayFrame,
        presentationTimeStamp pts: CMTime,
        pool: CVPixelBufferPool,
        canvas: Canvas,
        overlayAssets: OverlayAssets? = nil
    ) -> CMSampleBuffer? {
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: CGFloat(canvas.width), height: CGFloat(canvas.height))
        let screenImage = screenSceneImage(frame, canvas: canvas)
        if let overlayAssets, let screenImage,
           let scene = overlaySceneImage(assets: overlayAssets, onTopOf: screenImage) {
            // Screen as full-canvas base + overlay source-over in one render.
            ciContext.render(scene, to: outBuffer, bounds: bounds, colorSpace: colorSpace)
        } else {
            drawPixelBufferFullCanvas(
                frame.sampleBuffer,
                frameWidth: frame.width,
                frameHeight: frame.height,
                into: outBuffer,
                canvas: canvas
            )
        }

        return makeSampleBuffer(from: outBuffer, presentationTimeStamp: pts, sourceDuration: CMSampleBufferGetDuration(frame.sampleBuffer))
    }

    /// Wraps a pooled pixel buffer in a ready `CMSampleBuffer` with the given PTS.
    private func makeSampleBuffer(from outBuffer: CVPixelBuffer, presentationTimeStamp pts: CMTime, sourceDuration: CMTime) -> CMSampleBuffer? {
        let duration = sourceDuration.isValid ? sourceDuration : CMTime(value: 1, timescale: 60)

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard let formatDesc = formatDescription else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }

    private func singleDisplayComposite(
        frame: DisplayFrame,
        isPrimary: Bool,
        presentationTimeStamp pts: CMTime,
        pool: CVPixelBufferPool,
        canvas: Canvas
    ) -> CMSampleBuffer? {
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { return nil }

        clear(outBuffer, canvas: canvas)
        let xOffset = isPrimary ? 0 : frame.width
        drawPixelBuffer(frame.sampleBuffer, into: outBuffer, canvas: canvas, atX: xOffset, width: frame.width, height: frame.height)

        return makeSampleBuffer(from: outBuffer, presentationTimeStamp: pts, sourceDuration: CMSampleBufferGetDuration(frame.sampleBuffer))
    }

    private func clear(_ pixelBuffer: CVPixelBuffer, canvas: Canvas) {
        let bounds = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let image = CIImage(color: .black).cropped(to: bounds)
        ciContext.render(image, to: pixelBuffer, bounds: bounds, colorSpace: colorSpace)
    }

    private func drawPixelBuffer(
        _ sampleBuffer: CMSampleBuffer,
        into outputBuffer: CVPixelBuffer,
        canvas: Canvas,
        atX x: Int,
        width: Int,
        height: Int
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let yOffset = (canvas.height - height) / 2
        let bounds = CGRect(x: CGFloat(x), y: CGFloat(yOffset), width: CGFloat(width), height: CGFloat(height))
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
        ciContext.render(ciImage, to: outputBuffer, bounds: bounds, colorSpace: colorSpace)
    }

    /// Draws a screen frame stretched over the whole canvas (single-display
    /// mode base render). The screen image covers the entire canvas, so the
    /// black `clear` is skipped on this path.
    private func drawPixelBufferFullCanvas(
        _ sampleBuffer: CMSampleBuffer,
        frameWidth: Int,
        frameHeight: Int,
        into outputBuffer: CVPixelBuffer,
        canvas: Canvas
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              frameWidth > 0, frameHeight > 0 else { return }

        let bounds = CGRect(x: 0, y: 0, width: CGFloat(canvas.width), height: CGFloat(canvas.height))
        let scaleX = bounds.width / CGFloat(frameWidth)
        let scaleY = bounds.height / CGFloat(frameHeight)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(ciImage, to: outputBuffer, bounds: bounds, colorSpace: colorSpace)
    }

    /// Computes the overlay draw inputs under lock. Returns nil when there is
    /// no overlay configured or the stored camera frame is stale: the overlay
    /// is drawn only while `-cameraLeadTolerance <= screenPTS - cameraPTS < 0.5`
    /// (both PTS are host-clock based). A stale/absent camera never affects
    /// screen-driven emission.
    private func overlayAssetsLocked(canvas: Canvas, screenPTS: CMTime) -> OverlayAssets? {
        guard let layout = cameraOverlay, let camera = cameraFrame else { return nil }
        let cameraPTS = cameraFramePTS
        guard Self.ptsIsValid(cameraPTS) else { return nil }
        let age = screenPTS.seconds - cameraPTS.seconds
        guard age >= -Self.cameraLeadTolerance, age < 0.5 else { return nil }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(camera) else { return nil }
        let cameraWidth = CVPixelBufferGetWidth(pixelBuffer)
        let cameraHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard cameraWidth > 0, cameraHeight > 0 else { return nil }
        let aspectRatio = Double(cameraWidth) / Double(cameraHeight)

        let rect = layout.overlayRect(canvasWidth: canvas.width, canvasHeight: canvas.height, aspectRatio: aspectRatio)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let borderRect = layout.borderRect(canvasWidth: canvas.width, canvasHeight: canvas.height, aspectRatio: aspectRatio)

        // Rebuild the cached mask/border images only when the key changed, so
        // the steady state allocates nothing per frame.
        let key = OverlayCacheKey(canvas: canvas, layout: layout, aspectRatio: aspectRatio)
        if overlayCacheKey != key {
            overlayCache = Self.buildOverlayCache(layout: layout, canvas: canvas, aspectRatio: aspectRatio, rect: rect, borderRect: borderRect)
            overlayCacheKey = key
        }
        guard let cache = overlayCache else { return nil }

        return OverlayAssets(
            camera: camera,
            rect: rect,
            borderRect: borderRect,
            mask: cache.mask,
            transparent: cache.transparent,
            border: cache.border
        )
    }

    /// Builds the cached overlay images for one (canvas, layout, aspect) key.
    /// All images are generated at their final position in canvas coordinates
    /// (CIImage pixel-aligns extents, so the mask, the camera image and the
    /// border ring all land on the same aligned extent).
    private static func buildOverlayCache(
        layout: CameraOverlayLayout,
        canvas: Canvas,
        aspectRatio: Double,
        rect: CGRect,
        borderRect: CGRect
    ) -> OverlayCache {
        let radius = layout.cornerRadius(canvasWidth: canvas.width, canvasHeight: canvas.height, aspectRatio: aspectRatio)
        let mask = roundedRectImage(rect, radius: radius, color: .white)
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: rect)

        var border: CIImage?
        if layout.borderEnabled, borderRect.width > 0, borderRect.height > 0 {
            // Ring = outer rounded rect with the overlay's rounded rect punched
            // out, so compositing it over the camera leaves a border of
            // `borderWidthFraction * overlayHeight` visible around it.
            let borderWidth = (borderRect.height - rect.height) / 2
            let outerRadius = min(radius + borderWidth, min(borderRect.width, borderRect.height) / 2)
            let outer = roundedRectImage(borderRect, radius: outerRadius, color: .white)
            border = outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }

        return OverlayCache(mask: mask, transparent: transparent, border: border)
    }

    /// A rounded-rectangle image covering `rect`. The generator filter is
    /// `CIRoundedRectangleGenerator` (inputExtent / inputRadius / inputColor).
    private static func roundedRectImage(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        if let output = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": NSNumber(value: Double(radius)),
            "inputColor": color
        ])?.outputImage {
            return output
        }
        return CIImage(color: color).cropped(to: rect)
    }

    /// The screen frame of a single-display composite as a scene image,
    /// scaled to cover the whole canvas.
    private func screenSceneImage(_ frame: DisplayFrame, canvas: Canvas) -> CIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer),
              frame.width > 0, frame.height > 0 else { return nil }
        let scaleX = CGFloat(canvas.width) / CGFloat(frame.width)
        let scaleY = CGFloat(canvas.height) / CGFloat(frame.height)
        return CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: 0, ty: 0))
    }

    /// One display of a dual side-by-side composite as a scene image,
    /// positioned at `x`, vertically centered like `drawPixelBuffer`.
    private func displaySceneImage(_ frame: DisplayFrame, atX x: Int, canvas: Canvas) -> CIImage {
        let yOffset = (canvas.height - frame.height) / 2
        return CIImage(cvPixelBuffer: CMSampleBufferGetImageBuffer(frame.sampleBuffer)!)
            .transformed(by: CGAffineTransform(translationX: CGFloat(x), y: CGFloat(yOffset)))
    }

    /// Composites the camera overlay on top of `base` in the image graph and
    /// returns the resulting scene image. The camera frame is scaled to fit
    /// the overlay rect preserving aspect (the rect already has the camera
    /// aspect), masked with the cached rounded-rect mask via `CIBlendWithMask`,
    /// and the cached border ring is composited over it. Source-over has to
    /// happen in the graph: `CIContext.render(_:to:bounds:)` replaces the
    /// bounds region rather than blending, so a separate bounded render of the
    /// masked camera would punch transparent holes into the canvas at the
    /// rounded corners. The steady state allocates no per-frame images beyond
    /// the filter graph itself (mask/border are cached).
    private func overlaySceneImage(assets: OverlayAssets, onTopOf base: CIImage) -> CIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(assets.camera) else { return nil }
        let cameraImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = cameraImage.extent
        guard extent.width > 0, extent.height > 0,
              assets.rect.width > 0, assets.rect.height > 0 else { return nil }

        // Uniform scale + translate in one matrix maps the camera image
        // exactly onto the overlay rect.
        let scale = assets.rect.width / extent.width
        let scaled = cameraImage.transformed(by: CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: assets.rect.minX, ty: assets.rect.minY
        ))
        let masked = scaled.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: assets.transparent,
            kCIInputMaskImageKey: assets.mask
        ])
        let top = assets.border?.applyingFilter(
            "CISourceOverCompositing",
            parameters: [kCIInputBackgroundImageKey: masked]
        ) ?? masked
        return top.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: base])
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        primaryFrame = nil
        secondaryFrame = nil
        primaryTimeoutCounter = 0
        secondaryTimeoutCounter = 0
        compositeFrameCount = 0
        syntheticPTSBasis = nil
        lastSyntheticPTS = .zero
        lastOutputPTS = nil
        lastEmitWasCameraRefresh = false
        // Also drop the camera frame and the cached overlay images.
        cameraFrame = nil
        cameraFramePTS = .invalid
        overlayCache = nil
        overlayCacheKey = nil
    }

    private static func ptsIsValid(_ pts: CMTime) -> Bool {
        pts.isValid && pts.seconds > 0
    }

    private func shouldEmitFrame(preferred: CMSampleBuffer, fallback: CMSampleBuffer? = nil) -> Bool {
        guard let lastOutputPTS else { return true }
        let candidate = candidateOutputPTS(preferred: preferred, fallback: fallback)
        return CMTimeCompare(CMTimeSubtract(candidate, lastOutputPTS), targetFrameDuration) >= 0
    }

    private func reserveOutputPTS(preferred: CMSampleBuffer, fallback: CMSampleBuffer? = nil) -> CMTime {
        let pts = candidateOutputPTS(preferred: preferred, fallback: fallback)
        lastOutputPTS = pts
        lastEmitWasCameraRefresh = false
        return pts
    }

    private func candidateOutputPTS(preferred: CMSampleBuffer, fallback: CMSampleBuffer? = nil) -> CMTime {
        let preferredPTS = CMSampleBufferGetPresentationTimeStamp(preferred)
        let fallbackPTS = fallback.map(CMSampleBufferGetPresentationTimeStamp) ?? .invalid
        let candidate = Self.ptsIsValid(preferredPTS) ? preferredPTS : fallbackPTS
        var pts = Self.ptsIsValid(candidate) ? candidate : nextSyntheticPTSCandidate()

        if let lastOutputPTS, CMTimeCompare(pts, lastOutputPTS) <= 0 {
            pts = CMTimeAdd(lastOutputPTS, targetFrameDuration)
        }

        return pts
    }

    private func nextSyntheticPTSCandidate() -> CMTime {
        if syntheticPTSBasis == nil {
            syntheticPTSBasis = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1000000000)
        }
        lastSyntheticPTS = CMTimeAdd(lastSyntheticPTS, targetFrameDuration)
        return lastSyntheticPTS
    }
}
