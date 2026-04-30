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
    private var targetFrameDuration = CMTime(value: 1, timescale: 60)
    private var pixelBufferPool: CVPixelBufferPool?
    private var _outputHandler: OutputHandler?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

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
                          display2Width: Int, display2Height: Int,
                          fps: Int) {
        lock.lock()
        defer { lock.unlock() }

        let totalWidth = display1Width + display2Width
        let maxHeight = max(display1Height, display2Height)

        compositeWidth = totalWidth
        compositeHeight = maxHeight
        targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

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
        lastOutputPTS = nil
        lastSyntheticPTS = .zero
        syntheticPTSBasis = nil
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
            guard shouldEmitFrame(preferred: frame.sampleBuffer, fallback: primary!.sampleBuffer) else {
                lock.unlock()
                return
            }
            let pts = reserveOutputPTS(preferred: frame.sampleBuffer, fallback: primary!.sampleBuffer)
            let compositeBuffer = composite(
                primary: primary!,
                secondary: secondary!,
                presentationTimeStamp: pts,
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
        let staleFramePTS = staleFrame.flatMap { frame -> CMTime? in
            guard shouldEmitFrame(preferred: frame.sampleBuffer) else { return nil }
            return reserveOutputPTS(preferred: frame.sampleBuffer)
        }

        lock.unlock()

        if primaryStale || secondaryStale {
            if let handler, let frame = staleFrame, let pts = staleFramePTS {
                let compositeBuffer = singleDisplayComposite(
                    frame: frame,
                    isPrimary: primary != nil,
                    presentationTimeStamp: pts,
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

    private func composite(
        primary: DisplayFrame,
        secondary: DisplayFrame,
        presentationTimeStamp pts: CMTime,
        pool: CVPixelBufferPool
    ) -> CMSampleBuffer? {
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { return nil }

        clear(outBuffer)
        drawPixelBuffer(primary.sampleBuffer, into: outBuffer, atX: 0, width: primary.width, height: primary.height)
        drawPixelBuffer(secondary.sampleBuffer, into: outBuffer, atX: primary.width, width: secondary.width, height: secondary.height)

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

    private func singleDisplayComposite(
        frame: DisplayFrame,
        isPrimary: Bool,
        presentationTimeStamp pts: CMTime,
        pool: CVPixelBufferPool
    ) -> CMSampleBuffer? {
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { return nil }

        clear(outBuffer)
        let xOffset = isPrimary ? 0 : frame.width
        drawPixelBuffer(frame.sampleBuffer, into: outBuffer, atX: xOffset, width: frame.width, height: frame.height)

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

    private func clear(_ pixelBuffer: CVPixelBuffer) {
        let bounds = CGRect(x: 0, y: 0, width: compositeWidth, height: compositeHeight)
        let image = CIImage(color: .black).cropped(to: bounds)
        ciContext.render(image, to: pixelBuffer, bounds: bounds, colorSpace: colorSpace)
    }

    private func drawPixelBuffer(
        _ sampleBuffer: CMSampleBuffer,
        into outputBuffer: CVPixelBuffer,
        atX x: Int,
        width: Int,
        height: Int
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let yOffset = (compositeHeight - height) / 2
        let bounds = CGRect(x: CGFloat(x), y: CGFloat(yOffset), width: CGFloat(width), height: CGFloat(height))
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
        ciContext.render(ciImage, to: outputBuffer, bounds: bounds, colorSpace: colorSpace)
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

    private func shouldEmitFrame(preferred: CMSampleBuffer, fallback: CMSampleBuffer? = nil) -> Bool {
        guard let lastOutputPTS else { return true }
        let candidate = candidateOutputPTS(preferred: preferred, fallback: fallback)
        return CMTimeCompare(CMTimeSubtract(candidate, lastOutputPTS), targetFrameDuration) >= 0
    }

    private func reserveOutputPTS(preferred: CMSampleBuffer, fallback: CMSampleBuffer? = nil) -> CMTime {
        let pts = candidateOutputPTS(preferred: preferred, fallback: fallback)
        lastOutputPTS = pts
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
