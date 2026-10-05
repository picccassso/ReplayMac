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
        let plan = try GIFSamplingPlan(start: startSeconds, end: endSeconds,
                                       frameRate: frameRate, maxFrames: maxFrames)
        let frames = try await renderedFrames(sourceURL: sourceURL, times: plan.times,
                                             maxWidth: maxWidth, crop: crop)
        try Task.checkCancellation()
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw GIFExportError.cannotCreateDestination
        }

        try encode(frames, interval: plan.interval, destination: destination)
    }

    /// Content-aware approximation using the same sampled frames and encoder as export.
    static func estimateBytes(
        sourceURL: URL, startSeconds: Double, endSeconds: Double,
        maxWidth: CGFloat = 720, crop: NormalizedVideoCrop? = nil
    ) async throws -> Int64 {
        let plan = try GIFSamplingPlan(start: startSeconds, end: endSeconds)
        let sampleTimes = plan.estimateTimes()
        let frames = try await renderedFrames(sourceURL: sourceURL, times: sampleTimes,
                                             maxWidth: maxWidth, crop: crop)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, frames.count, nil
        ) else { throw GIFExportError.cannotCreateDestination }
        try encode(frames, interval: plan.interval, destination: destination)
        try Task.checkCancellation()
        return Int64((Double(data.length) * Double(plan.times.count) / Double(frames.count)).rounded(.up))
    }

    private static func renderedFrames(
        sourceURL: URL, times: [CMTime], maxWidth: CGFloat, crop: NormalizedVideoCrop?
    ) async throws -> [CGImage] {
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let sourceWidth = crop.map { maxWidth / max($0.rect.width, 0.05) } ?? maxWidth
        generator.maximumSize = CGSize(width: sourceWidth, height: sourceWidth * 4)
        let generation = GIFImageGeneration(generator: generator)
        var frames = await withTaskCancellationHandler {
            await generateFrames(generation: generation, times: times)
        } onCancel: {
            generation.cancel()
        }
        try Task.checkCancellation()
        if let crop, !crop.isFullFrame {
            frames = frames.compactMap { croppedAndScaled($0, crop: crop, maxWidth: maxWidth) }
        }
        guard !frames.isEmpty else { throw GIFExportError.noFrames }
        return frames
    }

    private static func encode(_ frames: [CGImage], interval: Double,
                               destination: CGImageDestination) throws {
        let fileProperties = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        let frameProperties = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFUnclampedDelayTime as String: interval
            ]
        ] as CFDictionary
        for frame in frames {
            try Task.checkCancellation()
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw GIFExportError.finalizeFailed }
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
        generation: GIFImageGeneration,
        times: [CMTime]
    ) async -> [CGImage] {
        await withCheckedContinuation { continuation in
            let collector = GIFFrameCollector(total: times.count)

            guard generation.start(times: times, handler: { requestedTime, image, _, _, _ in
                if let ordered = collector.record(requestedTime: requestedTime, image: image) {
                    continuation.resume(returning: ordered)
                }
            }) else {
                continuation.resume(returning: [])
                return
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

/// Serialises starting and cancelling generation, including cancellation before start.
private final class GIFImageGeneration: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var cancelled = false
    init(generator: AVAssetImageGenerator) { self.generator = generator }

    func start(times: [CMTime], handler: @escaping AVAssetImageGeneratorCompletionHandler) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        generator.generateCGImagesAsynchronously(forTimes: times.map { NSValue(time: $0) },
                                                completionHandler: handler)
        return true
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        generator.cancelAllCGImageGeneration()
    }
}

struct GIFSamplingPlan {
    let times: [CMTime]
    let interval: Double

    init(start: Double, end: Double, frameRate: Double = 12, maxFrames: Int = 300) throws {
        let duration = end - start
        guard start.isFinite, end.isFinite, start >= 0, duration.isFinite, duration > 0,
              end < Double(Int64.max) / 600,
              frameRate.isFinite, frameRate > 0, maxFrames > 0 else {
            throw GIFExportError.noFrames
        }
        let count = Int(min(Double(maxFrames), max(1, (duration * frameRate).rounded())))
        let samplingInterval = duration / Double(count)
        interval = samplingInterval
        var seen = Set<Int64>()
        times = (0..<count).compactMap { index in
            // CMTime(seconds:) truncates fractional ticks. Floating-point multiplication
            // can place an exact frame boundary just below its tick, which AVFoundation
            // may fail to decode with zero tolerance. Round the shared sequence explicitly.
            let seconds = start + Double(index) * samplingInterval
            let time = CMTime(value: Int64((seconds * 600).rounded()), timescale: 600)
            return seen.insert(time.value).inserted ? time : nil
        }
    }

    func estimateTimes(limit: Int = 12) -> [CMTime] {
        guard limit > 0 else { return [] }
        guard times.count > limit else { return times }
        guard limit > 1 else { return [times[times.count / 2]] }
        return (0..<limit).map { index in
            times[Int((Double(index) * Double(times.count - 1) / Double(limit - 1)).rounded())]
        }
    }
}
