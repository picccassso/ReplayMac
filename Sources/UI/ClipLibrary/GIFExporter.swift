import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Output width presets for GIF export. Larger keeps more detail (sharper UI
/// text) at the cost of a bigger file.
enum GIFWidth: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var points: CGFloat {
        switch self {
        case .small: return 480
        case .medium: return 720
        case .large: return 1080
        }
    }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

enum GIFExportError: LocalizedError {
    case noFrames
    case cannotCreateDestination
    case finalizeFailed

    var errorDescription: String? {
        switch self {
        case .noFrames:
            return "Could not read any frames from the selected range."
        case .cannotCreateDestination:
            return "Unable to create the GIF file."
        case .finalizeFailed:
            return "Writing the GIF did not complete."
        }
    }
}

private final class GIFFrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private var collected: [(time: Double, image: CGImage)] = []
    private var processed = 0
    private var finished = false

    init(total: Int) {
        self.total = total
    }

    /// Returns the ordered frames exactly once, on the callback that completes
    /// the batch. `>=` rather than `==` so an extra callback can't slip past
    /// the completion point and strand the caller's continuation; `finished`
    /// guarantees it still only fires once.
    func record(requestedTime: CMTime, image: CGImage?) -> [CGImage]? {
        lock.lock()
        defer { lock.unlock() }

        guard !finished else { return nil }

        if let image {
            collected.append((requestedTime.seconds, image))
        }

        processed += 1
        guard processed >= total else {
            return nil
        }

        finished = true
        return collected
            .sorted { $0.time < $1.time }
            .map(\.image)
    }
}

/// Renders a time range of a video into an animated, looping GIF.
enum GIFExporter {
    /// - Parameters:
    ///   - frameRate: Sampled frames per second. GIFs look fine at 10–15 fps
    ///     and the format itself caps practical playback near there.
    ///   - maxWidth: Output is scaled to fit this width (aspect preserved) to
    ///     keep file size reasonable for sharing.
    ///   - maxFrames: Hard cap so a long range can't produce a huge file; the
    ///     effective frame rate is lowered to fit.
    static func export(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        frameRate: Double = 12,
        maxWidth: CGFloat = 720,
        maxFrames: Int = 300,
        crop: NormalizedVideoCrop? = nil,
        to outputURL: URL
    ) async throws {
        let rangeDuration = endSeconds - startSeconds
        guard rangeDuration > 0 else {
            throw GIFExportError.noFrames
        }

        var frameCount = max(1, Int((rangeDuration * frameRate).rounded()))
        frameCount = min(frameCount, maxFrames)
        let interval = rangeDuration / Double(frameCount)

        // Deduplicate: a very short range can round two samples onto the same
        // 1/600s tick, and the generator coalesces identical requested times
        // into a single callback. The collector counts callbacks, so duplicates
        // would leave it waiting for a callback that never comes.
        var seenTicks = Set<Int64>()
        let sampleTimes: [CMTime] = (0..<frameCount).compactMap { index in
            let time = CMTime(seconds: startSeconds + Double(index) * interval, preferredTimescale: 600)
            return seenTicks.insert(time.value).inserted ? time : nil
        }

        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Generate enough source pixels that a narrow crop can still reach the
        // requested output width. AVAssetImageGenerator caps this at the
        // source's native resolution, so this does not upscale the video.
        let sourceWidth = crop.map { maxWidth / max($0.rect.width, 0.05) } ?? maxWidth
        generator.maximumSize = CGSize(width: sourceWidth, height: sourceWidth * 4)

        var frames = await generateFrames(generator: generator, times: sampleTimes)
        if let crop, !crop.isFullFrame {
            frames = frames.compactMap { croppedAndScaled($0, crop: crop, maxWidth: maxWidth) }
        }
        guard !frames.isEmpty else {
            throw GIFExportError.noFrames
        }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw GIFExportError.cannotCreateDestination
        }

        let fileProperties = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0  // loop forever
            ]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)

        let frameProperties = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFUnclampedDelayTime as String: interval
            ]
        ] as CFDictionary

        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFExportError.finalizeFailed
        }
    }

    /// A `<clipname>_GIF.gif` URL next to the source, deduped with a counter.
    static func uniqueOutputURL(basedOn sourceURL: URL) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(baseName)_GIF.gif")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)_GIF_\(counter).gif")
            counter += 1
        }
        return candidate
    }

    /// Bridges the callback-based generator into ordered frames. The handler is
    /// invoked once per requested time, possibly out of order, so frames are
    /// sorted by requested time before returning.
    private static func generateFrames(
        generator: AVAssetImageGenerator,
        times: [CMTime]
    ) async -> [CGImage] {
        await withCheckedContinuation { continuation in
            let collector = GIFFrameCollector(total: times.count)

            generator.generateCGImagesAsynchronously(
                forTimes: times.map { NSValue(time: $0) }
            ) { requestedTime, image, _, _, _ in
                if let ordered = collector.record(requestedTime: requestedTime, image: image) {
                    continuation.resume(returning: ordered)
                }
            }
        }
    }

    static func croppedAndScaled(
        _ image: CGImage,
        crop: NormalizedVideoCrop,
        maxWidth: CGFloat
    ) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let cropRect = VideoCropper.pixelRect(for: crop, displaySize: imageSize)
            .intersection(CGRect(origin: .zero, size: imageSize))
        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0,
              let cropped = image.cropping(to: cropRect) else {
            return nil
        }

        guard CGFloat(cropped.width) > maxWidth else { return cropped }
        let scale = maxWidth / CGFloat(cropped.width)
        let outputWidth = max(1, Int(maxWidth.rounded(.down)))
        let outputHeight = max(1, Int((CGFloat(cropped.height) * scale).rounded(.down)))
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        return context.makeImage()
    }
}
