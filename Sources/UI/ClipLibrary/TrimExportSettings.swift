import CoreGraphics
import Foundation

enum TrimExportResolution: String, CaseIterable, Identifiable, Sendable {
    case source
    case fullHD
    case HD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: return "Original"
        case .fullHD: return "1080p"
        case .HD: return "720p"
        }
    }

    var filenameLabel: String? {
        switch self {
        case .source: return nil
        case .fullHD: return "1080p"
        case .HD: return "720p"
        }
    }

    /// Fits a source or crop inside the selected landscape/portrait bounding
    /// box without upscaling or changing its aspect ratio.
    func outputSize(for inputSize: CGSize) -> CGSize {
        guard inputSize.width > 0, inputSize.height > 0 else {
            return CGSize(width: 2, height: 2)
        }

        let boundingSize: CGSize?
        switch self {
        case .source:
            boundingSize = nil
        case .fullHD:
            boundingSize = inputSize.width >= inputSize.height
                ? CGSize(width: 1920, height: 1080)
                : CGSize(width: 1080, height: 1920)
        case .HD:
            boundingSize = inputSize.width >= inputSize.height
                ? CGSize(width: 1280, height: 720)
                : CGSize(width: 720, height: 1280)
        }

        let scale: CGFloat
        if let boundingSize {
            scale = min(
                1,
                boundingSize.width / inputSize.width,
                boundingSize.height / inputSize.height
            )
        } else {
            scale = 1
        }

        // H.264 and HEVC encoders require even dimensions on common hardware.
        return CGSize(
            width: max(2, floor((inputSize.width * scale) / 2) * 2),
            height: max(2, floor((inputSize.height * scale) / 2) * 2)
        )
    }
}

enum TrimExportQuality: String, CaseIterable, Identifiable, Sendable {
    case source
    case compact
    case balanced
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: return "Source"
        case .compact: return "Compact"
        case .balanced: return "Balanced"
        case .high: return "High"
        }
    }

    var filenameLabel: String? {
        switch self {
        case .source: return nil
        case .compact: return "Compact"
        case .balanced: return "Balanced"
        case .high: return "High"
        }
    }

    /// Target HEVC bitrate scaled from a 1080p baseline. The sub-linear pixel
    /// scaling avoids starving 720p while keeping 1440p and 4K exports useful.
    func videoBitrateMbps(for outputSize: CGSize) -> Double? {
        let base1080p: Double
        switch self {
        case .source:
            return nil
        case .compact:
            base1080p = 4
        case .balanced:
            base1080p = 8
        case .high:
            base1080p = 12
        }

        let pixels = max(Double(outputSize.width * outputSize.height), 1)
        let pixelRatio = pixels / Double(1920 * 1080)
        let scaled = base1080p * pow(pixelRatio, 0.7)
        return max(1.5, (scaled * 4).rounded() / 4)
    }
}

enum TrimExportEstimate {
    static let discordLimitBytes: Int64 = 100_000_000
    static let audioBitrateMbpsPerTrack = 0.192
    static let containerOverhead = 1.05

    /// Estimates final MP4 size from the selected range and target data rate.
    /// Custom exports have a known HEVC target bitrate; Source uses the clip's
    /// measured whole-file bitrate as the best available passthrough estimate.
    static func bytes(
        durationSeconds: TimeInterval,
        quality: TrimExportQuality,
        outputSize: CGSize,
        audioTrackCount: Int,
        sourceTotalBitrateMbps: Double
    ) -> Int64 {
        guard durationSeconds > 0 else { return 0 }

        let totalBitrateMbps: Double
        if let videoBitrate = quality.videoBitrateMbps(for: outputSize) {
            totalBitrateMbps = videoBitrate
                + Double(max(0, audioTrackCount)) * audioBitrateMbpsPerTrack
        } else {
            guard sourceTotalBitrateMbps > 0 else { return 0 }
            totalBitrateMbps = sourceTotalBitrateMbps
        }

        let bytes = totalBitrateMbps * 1_000_000 / 8
            * durationSeconds
            * containerOverhead
        return Int64(bytes.rounded(.up))
    }
}
