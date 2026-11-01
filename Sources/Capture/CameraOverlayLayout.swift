import Foundation
import CoreGraphics

/// Which corner of the clip the camera overlay is anchored to.
///
/// Raw values are persisted in user defaults and capture profiles, so they
/// must never change (tests pin them).
public enum CameraOverlayPosition: String, CaseIterable, Sendable, Codable {
    case topLeft = "top_left"
    case topRight = "top_right"
    case bottomLeft = "bottom_left"
    case bottomRight = "bottom_right"
}

/// Overlay size as a fraction of the clip width.
public enum CameraOverlaySize: String, CaseIterable, Sendable, Codable {
    case small = "small"
    case medium = "medium"
    case large = "large"

    /// Share of the canvas width the overlay occupies.
    public var widthFraction: Double {
        switch self {
        case .small: return 0.18
        case .medium: return 0.25
        case .large: return 0.34
        }
    }
}

/// Camera capture resolution + frame rate. Maps to an
/// `AVCaptureSession.Preset` (see `CameraCapture.swift`).
public enum CameraCaptureResolution: String, CaseIterable, Sendable, Codable {
    case hd720p30 = "720p30"    // AVCaptureSession.Preset.hd1280x720
    case hd1080p30 = "1080p30"  // AVCaptureSession.Preset.hd1920x1080
}

/// Geometry of the camera overlay inside a composited clip.
///
/// All rects are in image coordinates with a bottom-left origin (the CIImage /
/// CoreGraphics convention, which `CIContext.render(_:to:bounds:)` uses), so
/// `top_left` means the overlay sits at the TOP-left of the visible image:
/// `y = canvasHeight - margin - height`.
///
/// The layout is a pure value: every function derives its result from the
/// canvas size and the camera aspect ratio only, which keeps it unit-testable
/// without any capture hardware.
public struct CameraOverlayLayout: Sendable, Equatable {
    public let position: CameraOverlayPosition
    public let size: CameraOverlaySize
    /// Whether to draw the rounded-corner border ring around the overlay.
    public let borderEnabled: Bool

    /// Gap between the overlay and the canvas edges, as a fraction of
    /// `min(canvasWidth, canvasHeight)`.
    public let marginFraction: Double
    /// Corner radius as a fraction of the overlay height.
    public let cornerRadiusFraction: Double
    /// Border ring width as a fraction of the overlay height.
    public let borderWidthFraction: Double

    public init(
        position: CameraOverlayPosition = .topLeft,
        size: CameraOverlaySize = .small,
        borderEnabled: Bool = true,
        marginFraction: Double = 0.02,
        cornerRadiusFraction: Double = 0.08,
        borderWidthFraction: Double = 0.006
    ) {
        self.position = position
        self.size = size
        self.borderEnabled = borderEnabled
        self.marginFraction = marginFraction
        self.cornerRadiusFraction = cornerRadiusFraction
        self.borderWidthFraction = borderWidthFraction
    }

    /// The overlay rect inside a `canvasWidth` x `canvasHeight` canvas,
    /// preserving the camera `aspectRatio` (width / height) inside the corner
    /// region. The result is always clamped to stay inside the canvas, even for
    /// tiny canvases or extreme aspect ratios.
    public func overlayRect(canvasWidth: Int, canvasHeight: Int, aspectRatio: Double) -> CGRect {
        let w = CGFloat(canvasWidth)
        let h = CGFloat(canvasHeight)
        guard w > 0, h > 0 else { return .zero }

        let margin = CGFloat(marginFraction) * min(w, h)
        // Region left inside the margins on each axis.
        let maxWidth = max(0, w - 2 * margin)
        let maxHeight = max(0, h - 2 * margin)

        let aspect = aspectRatio > 0 ? CGFloat(aspectRatio) : 1
        var width = CGFloat(size.widthFraction) * w
        var height = width / aspect

        // Preserve the camera aspect ratio: if the rect is too tall for the
        // canvas, shrink it to the available height and re-derive the width
        // (and vice versa), so the camera is never stretched.
        if height > maxHeight, maxHeight > 0 {
            height = maxHeight
            width = height * aspect
        }
        if width > maxWidth, maxWidth > 0 {
            width = maxWidth
            height = width / aspect
        }
        width = max(0, width)
        height = max(0, height)

        let x: CGFloat
        switch position {
        case .topLeft, .bottomLeft:
            x = margin
        case .topRight, .bottomRight:
            x = w - margin - width
        }
        // Image coords have a bottom-left origin: "top" means the overlay's
        // far edge is at canvasHeight - margin.
        let y: CGFloat
        switch position {
        case .topLeft, .topRight:
            y = h - margin - height
        case .bottomLeft, .bottomRight:
            y = margin
        }

        // Final safety clamp for degenerate (tiny) canvases: never emit a
        // rect that escapes the canvas or has negative origin.
        let clampedX = min(max(0, x), max(0, w - width))
        let clampedY = min(max(0, y), max(0, h - height))
        return CGRect(x: clampedX, y: clampedY, width: min(width, w), height: min(height, h))
    }

    /// The rect the border ring is drawn in: the overlay rect outset by the
    /// border width on every side, clamped to the canvas.
    public func borderRect(canvasWidth: Int, canvasHeight: Int, aspectRatio: Double) -> CGRect {
        let rect = overlayRect(canvasWidth: canvasWidth, canvasHeight: canvasHeight, aspectRatio: aspectRatio)
        let borderWidth = CGFloat(borderWidthFraction) * rect.height
        let canvasBounds = CGRect(x: 0, y: 0, width: CGFloat(canvasWidth), height: CGFloat(canvasHeight))
        return rect.insetBy(dx: -borderWidth, dy: -borderWidth).intersection(canvasBounds)
    }

    /// Corner radius of the overlay (and of the border ring's outer edge),
    /// clamped to half the smaller overlay dimension so the rounded rect
    /// never self-intersects.
    public func cornerRadius(canvasWidth: Int, canvasHeight: Int, aspectRatio: Double) -> CGFloat {
        let rect = overlayRect(canvasWidth: canvasWidth, canvasHeight: canvasHeight, aspectRatio: aspectRatio)
        let radius = CGFloat(cornerRadiusFraction) * rect.height
        return min(radius, min(rect.width, rect.height) / 2)
    }
}
