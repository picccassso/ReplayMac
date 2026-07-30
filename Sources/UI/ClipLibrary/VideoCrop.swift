import Foundation
@preconcurrency import AVFoundation
import CoreGraphics

/// A crop rectangle expressed in displayed-video coordinates, where every
/// component is normalized to 0...1 and the origin is the top-left corner.
struct NormalizedVideoCrop: Equatable, Sendable {
    static let fullFrame = NormalizedVideoCrop(unchecked: CGRect(x: 0, y: 0, width: 1, height: 1))

    let rect: CGRect

    init(_ candidate: CGRect) {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clipped = candidate.standardized.intersection(unit)
        if clipped.isNull || clipped.width <= 0 || clipped.height <= 0 {
            self = .fullFrame
        } else {
            rect = clipped
        }
    }

    private init(unchecked rect: CGRect) {
        self.rect = rect
    }

    var isFullFrame: Bool {
        abs(rect.minX) < 0.0001
            && abs(rect.minY) < 0.0001
            && abs(rect.width - 1) < 0.0001
            && abs(rect.height - 1) < 0.0001
    }
}

struct VideoCropGeometry: Equatable, Sendable {
    let displaySize: CGSize
    let orientationTransform: CGAffineTransform
}

enum VideoCropper {
    /// Resolves a track's encoded dimensions and preferred transform into a
    /// top-left-origin display space suitable for both preview and export.
    static func geometry(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> VideoCropGeometry {
        let sourceBounds = CGRect(origin: .zero, size: naturalSize)
        let transformedBounds = sourceBounds.applying(preferredTransform).standardized
        let orientationTransform = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -transformedBounds.minX,
                y: -transformedBounds.minY
            )
        )
        return VideoCropGeometry(
            displaySize: CGSize(
                width: abs(transformedBounds.width),
                height: abs(transformedBounds.height)
            ),
            orientationTransform: orientationTransform
        )
    }

    static func pixelRect(for crop: NormalizedVideoCrop, displaySize: CGSize) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0 else { return .zero }

        let raw = CGRect(
            x: crop.rect.minX * displaySize.width,
            y: crop.rect.minY * displaySize.height,
            width: crop.rect.width * displaySize.width,
            height: crop.rect.height * displaySize.height
        )

        // H.264/HEVC encoders are most reliable with even output dimensions.
        let x = floor(raw.minX)
        let y = floor(raw.minY)
        let availableWidth = max(2, floor(displaySize.width - x))
        let availableHeight = max(2, floor(displaySize.height - y))
        let width = min(availableWidth, max(2, floor(raw.width / 2) * 2))
        let height = min(availableHeight, max(2, floor(raw.height / 2) * 2))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func geometry(for asset: AVAsset) async throws -> VideoCropGeometry {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoCropError.noVideoTrack
        }
        return geometry(
            naturalSize: try await track.load(.naturalSize),
            preferredTransform: try await track.load(.preferredTransform)
        )
    }

    /// Creates an export composition that first applies the track's preferred
    /// orientation and then moves the selected displayed region to (0, 0).
    ///
    /// Deliberately not main-actor isolated: building this loads tracks and
    /// their properties, and none of it needs the main thread.
    nonisolated static func videoComposition(
        for asset: AVAsset,
        crop: NormalizedVideoCrop
    ) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoCropError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let geometry = geometry(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        let cropRect = pixelRect(for: crop, displaySize: geometry.displaySize)
        guard cropRect.width > 0, cropRect.height > 0 else {
            throw VideoCropError.invalidCrop
        }

        let composition = AVMutableVideoComposition()
        composition.renderSize = cropRect.size
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let frameRate = nominalFrameRate.isFinite && nominalFrameRate > 0 ? nominalFrameRate : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let cropTransform = geometry.orientationTransform.concatenating(
            CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        )
        layerInstruction.setTransform(cropTransform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        return composition
    }
}

enum VideoCropError: LocalizedError {
    case noVideoTrack
    case invalidCrop

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The clip does not contain a video track to crop."
        case .invalidCrop:
            return "The selected crop area is too small to export."
        }
    }
}
