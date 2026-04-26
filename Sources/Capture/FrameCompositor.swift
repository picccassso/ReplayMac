import Foundation
import CoreMedia
import CoreVideo
import CoreImage

public final class FrameCompositor: @unchecked Sendable {
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

    private let lock = NSLock()
    private var primaryFrame: DisplayFrame?
    private var secondaryFrame: DisplayFrame?
    private var compositeWidth: Int = 0
    private var compositeHeight: Int = 0
    private var pixelBufferPool: CVPixelBufferPool?
    private var _outputHandler: OutputHandler?

    private var primaryTimeoutCounter = 0
    private var secondaryTimeoutCounter = 0
    private static let maxStaleFrames = 3

    private var compositeFrameCount: Int64 = 0
    private var syntheticPTSBasis: CMTime?
    private var lastSyntheticPTS: CMTime = .zero
    private var lastOutputPTS: CMTime?

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
                          display2Width: Int, display2Height: Int) {
        lock.lock()
        defer { lock.unlock() }

        let totalWidth = display1Width + display2Width
        let maxHeight = max(display1Height, display2Height)

        compositeWidth = totalWidth
        compositeHeight = maxHeight

        var pool: CVPixelBufferPool?
        let pixelFormat = kCVPixelFormatType_32BGRA

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 8
        ]

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: totalWidth,
            kCVPixelBufferHeightKey as String: maxHeight,
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
        pixelBufferPool = pool
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
        lock.lock()

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

        let primary = primaryFrame
        let secondary = secondaryFrame

        if primary != nil && secondary != nil {
            let pts = nextOutputPTS(preferred: frame.sampleBuffer, fallback: primary!.sampleBuffer)
            let compositeBuffer = Self.composite(
                primary: primary!,
                secondary: secondary!,
                presentationTimeStamp: pts,
                compositeWidth: compositeWidth,
                compositeHeight: compositeHeight,
                pool: pool
            )
            compositeFrameCount += 1
            if compositeFrameCount <= 5 || compositeFrameCount % 60 == 0 {
                let pts = compositeBuffer.map { CMSampleBufferGetPresentationTimeStamp($0) }
                print("FrameCompositor: composite #\(compositeFrameCount) PTS=\(pts?.seconds ?? -1) valid=\(pts?.isValid ?? false)")
            }
            lock.unlock()

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
        let staleFramePTS = staleFrame.map { nextOutputPTS(preferred: $0.sampleBuffer) }

        lock.unlock()

        if primaryStale || secondaryStale {
            if let handler, let frame = staleFrame, let pts = staleFramePTS {
                let compositeBuffer = Self.singleDisplayComposite(
                    frame: frame,
                    isPrimary: primary != nil,
                    presentationTimeStamp: pts,
                    compositeWidth: compositeWidth,
                    compositeHeight: compositeHeight,
                    pool: pool
                )
                if compositeFrameCount <= 5 {
                    let pts = compositeBuffer.map { CMSampleBufferGetPresentationTimeStamp($0) }
                    print("FrameCompositor: stale single-display composite PTS=\(pts?.seconds ?? -1) valid=\(pts?.isValid ?? false)")
                }
                if let buffer = compositeBuffer {
                    handler(buffer)
                }
            }
        }
    }

    private static func composite(
        primary: DisplayFrame,
        secondary: DisplayFrame,
        presentationTimeStamp pts: CMTime,
        compositeWidth: Int,
        compositeHeight: Int,
        pool: CVPixelBufferPool
    ) -> CMSampleBuffer? {
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(outBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(outBuffer)

        let context = CGContext(
            data: baseAddress,
            width: compositeWidth,
            height: compositeHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        guard let ctx = context else { return nil }

        ctx.setFillColor(CGColor.black)
        ctx.fill(CGRect(x: 0, y: 0, width: compositeWidth, height: compositeHeight))

        drawPixelBuffer(primary.sampleBuffer, in: ctx, atX: 0, width: primary.width, height: primary.height, canvasHeight: compositeHeight)
        drawPixelBuffer(secondary.sampleBuffer, in: ctx, atX: primary.width, width: secondary.width, height: secondary.height, canvasHeight: compositeHeight)

        let sourceDuration = CMSampleBufferGetDuration(primary.sampleBuffer)
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

    private static func singleDisplayComposite(
        frame: DisplayFrame,
        isPrimary: Bool,
        presentationTimeStamp pts: CMTime,
        compositeWidth: Int,
        compositeHeight: Int,
        pool: CVPixelBufferPool
    ) -> CMSampleBuffer? {
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(outBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(outBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(outBuffer)

        let context = CGContext(
            data: baseAddress,
            width: compositeWidth,
            height: compositeHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        guard let ctx = context else { return nil }

        ctx.setFillColor(CGColor.black)
        ctx.fill(CGRect(x: 0, y: 0, width: compositeWidth, height: compositeHeight))

        let xOffset = isPrimary ? 0 : frame.width
        drawPixelBuffer(frame.sampleBuffer, in: ctx, atX: xOffset, width: frame.width, height: frame.height, canvasHeight: compositeHeight)

        let sourceDuration = CMSampleBufferGetDuration(frame.sampleBuffer)
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

    private static func drawPixelBuffer(
        _ sampleBuffer: CMSampleBuffer,
        in context: CGContext,
        atX x: Int,
        width: Int,
        height: Int,
        canvasHeight: Int
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let yOffset = (canvasHeight - height) / 2
        let rect = CGRect(x: CGFloat(x), y: CGFloat(yOffset), width: CGFloat(width), height: CGFloat(height))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        var bitmap: CGContext?
        bitmap = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )

        guard let bmp = bitmap else { return }

        let ciContext = CIContext(cgContext: bmp, options: nil)
        ciContext.draw(ciImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), from: ciImage.extent)

        guard let cgImage = bmp.makeImage() else { return }
        context.draw(cgImage, in: rect)
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
    }

    private static func ptsIsValid(_ pts: CMTime) -> Bool {
        pts.isValid && pts.seconds > 0
    }

    private func nextOutputPTS(preferred: CMSampleBuffer, fallback: CMSampleBuffer? = nil) -> CMTime {
        let preferredPTS = CMSampleBufferGetPresentationTimeStamp(preferred)
        let fallbackPTS = fallback.map(CMSampleBufferGetPresentationTimeStamp) ?? .invalid
        let candidate = Self.ptsIsValid(preferredPTS) ? preferredPTS : fallbackPTS
        var pts = Self.ptsIsValid(candidate) ? candidate : nextSyntheticPTS()

        if let lastOutputPTS, CMTimeCompare(pts, lastOutputPTS) <= 0 {
            let step = CMSampleBufferGetDuration(preferred)
            let frameDuration = step.isValid && step > .zero ? step : CMTime(value: 1, timescale: 60)
            pts = CMTimeAdd(lastOutputPTS, frameDuration)
        }

        lastOutputPTS = pts
        return pts
    }

    private func nextSyntheticPTS(fps: Int32 = 60) -> CMTime {
        let frameDuration = CMTime(value: 1, timescale: fps)
        if syntheticPTSBasis == nil {
            syntheticPTSBasis = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1000000000)
        }
        lastSyntheticPTS = CMTimeAdd(lastSyntheticPTS, frameDuration)
        return lastSyntheticPTS
    }
}
