import AppKit
// @preconcurrency: kept from ClipLibraryView.swift, where this code used to
// live, so Swift 6.1 (GitHub's macos-latest runners) checks it the same way.
@preconcurrency import AVFoundation

/// Carries a pre-decoded `CGImage` across task boundaries so the main thread
/// never has to decompress a JPEG/PNG when a grid card scrolls into view.
final class PredecodedThumbnailBox: @unchecked Sendable {
    let image: CGImage?
    init(image: CGImage?) { self.image = image }
}

extension ClipLibraryViewModel {
    static func predecodedThumbnail(for url: URL) async -> PredecodedThumbnailBox {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Sized for a large grid card on a Retina display.
        generator.maximumSize = CGSize(width: 640, height: 360)

        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                guard let image else {
                    continuation.resume(returning: PredecodedThumbnailBox(image: nil))
                    return
                }
                // Rasterize into a standard 32-bit BGRA bitmap off the main thread
                // so CoreAnimation never decodes or color-converts during scroll.
                let width = image.width
                let height = image.height
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                if let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                ) {
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    continuation.resume(returning: PredecodedThumbnailBox(image: context.makeImage() ?? image))
                } else {
                    continuation.resume(returning: PredecodedThumbnailBox(image: image))
                }
            }
        }
    }

    static func thumbnailData(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Sized for a large grid card on a Retina display.
        generator.maximumSize = CGSize(width: 640, height: 360)

        // Encode to JPEG inside the callback so only `Data` (Sendable) crosses
        // the continuation and task-group boundaries. JPEG keeps the larger
        // posters a fraction of the size PNG would be in the cache.
        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                guard let image else {
                    continuation.resume(returning: nil)
                    return
                }
                let rep = NSBitmapImageRep(cgImage: image)
                continuation.resume(returning: rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
            }
        }
    }
}
