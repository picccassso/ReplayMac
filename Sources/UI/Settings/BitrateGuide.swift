import Foundation

/// Where a bitrate sits against what the quality presets would pick for the
/// same output size, frame rate and codec. Performance marks the bottom of the
/// sweet spot and Ultra the top: below it fast motion can break up, above it
/// clips and the replay buffer grow without looking any better.
public struct BitrateGuide: Equatable {
    public enum Zone: Equatable {
        case low
        case sweetSpot
        case high
    }

    /// Range of the Bitrate slider in Settings → Video.
    public static let sliderRange: ClosedRange<Double> = 10...50
    /// Output size the preset bitrates are tuned for.
    static let referencePixels = Double(2560 * 1440)

    public let recommendedMbps: Double
    public let sweetSpot: ClosedRange<Double>

    public init(width: Int, height: Int, frameRate: Int, isH264SDR: Bool) {
        func mbps(_ preset: QualityPreset) -> Double {
            Self.recommendedMbps(
                preset: preset,
                width: width,
                height: height,
                frameRate: frameRate,
                isH264SDR: isH264SDR
            )
        }
        recommendedMbps = mbps(.quality)
        sweetSpot = mbps(.performance)...mbps(.ultra)
    }

    /// Custom has no target of its own, so it recommends what Quality would.
    public static func recommendedMbps(
        preset: QualityPreset,
        width: Int,
        height: Int,
        frameRate: Int,
        isH264SDR: Bool
    ) -> Double {
        let pixelScale = max(Double(width * height) / referencePixels, 0.25)
        let fpsScale = max(Double(frameRate) / 60.0, 0.5)
        let codecScale = isH264SDR ? 1.3 : 1.0

        let baseMbps: Double
        switch preset {
        case .performance:
            baseMbps = 18
        case .quality, .custom:
            baseMbps = 25
        case .ultra:
            baseMbps = 40
        }

        let recommendation = (baseMbps * pixelScale * fpsScale * codecScale).rounded()
        return min(max(recommendation, sliderRange.lowerBound), sliderRange.upperBound)
    }

    public func zone(for mbps: Double) -> Zone {
        if mbps < sweetSpot.lowerBound { return .low }
        if mbps > sweetSpot.upperBound { return .high }
        return .sweetSpot
    }

    public func message(for mbps: Double) -> String {
        let low = Int(sweetSpot.lowerBound)
        let high = Int(sweetSpot.upperBound)
        switch zone(for: mbps) {
        case .low:
            return "Fast motion can look blocky below \(low) Mbps at this size and frame rate."
        case .sweetSpot:
            if low == high {
                return "\(low) Mbps is the sweet spot for this size and frame rate."
            }
            return "In the sweet spot for this size and frame rate (\(low)–\(high) Mbps)."
        case .high:
            return "Above \(high) Mbps, clips get bigger without looking better."
        }
    }

    /// Rough 0–1 picture quality for the explainer chart and preview, shaped
    /// so the sweet spot starts at 0.85 and gains flatten out past it. Not a
    /// measurement: real results depend on how busy the footage is.
    public func illustrativeQuality(at mbps: Double) -> Double {
        1 - pow(0.15, mbps / sweetSpot.lowerBound)
    }

    /// Bits each pixel of each frame gets on average.
    public static func bitsPerPixel(mbps: Double, width: Int, height: Int, frameRate: Int) -> Double {
        let pixelsPerSecond = Double(width * height * frameRate)
        guard pixelsPerSecond > 0 else { return 0 }
        return mbps * 1_000_000 / pixelsPerSecond
    }

    /// Size of one minute of video from one encoder stream at `mbps`.
    public static func bytesPerMinute(_ mbps: Double) -> Int {
        Int(mbps * 1_000_000 / 8 * 60)
    }
}
