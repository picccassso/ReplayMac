import Foundation

/// Rough RAM cost of the in-memory replay buffer for a given set of settings,
/// and how much of the requested window the memory cap can actually hold.
/// Bitrate is a VBR target, so every figure here is an estimate.
public struct ReplayMemoryEstimate: Equatable {
    public enum Tier: Equatable {
        case light      // up to a minute
        case moderate   // a few minutes
        case heavy      // close to the 5 minute maximum
    }

    /// Buffer lengths at or above this are steered toward extended replay.
    public static let heavyThresholdSeconds = 240
    public static let lightThresholdSeconds = 60
    /// Audio sits in the ring buffers as raw PCM, about 3 Mbps per source. The
    /// 0.2 Mbps AAC figure `estimatedLongBufferDiskGB` uses only applies once a
    /// track is written to disk; using it here understated the RAM audio needs
    /// fifteenfold and hid windows the audio buffers could not hold.
    static var audioBytesPerSecondPerSource: Double { AppSettings.audioRingBufferBytesPerSecond }
    /// Range and step of the Memory cap slider in Settings → Advanced.
    public static let memoryCapRangeMB: ClosedRange<Double> = 256...4096
    public static let memoryCapStepMB: Double = 64

    public let requestedSeconds: Int
    public let bitrateMbps: Double
    public let memoryCapMB: Double
    /// RAM the requested window needs, video and audio together.
    public let requiredBytes: Int
    /// Seconds of the window the memory cap holds, video and audio alike,
    /// before older footage is evicted.
    public let coveredSeconds: Int
    /// Smallest Memory cap slider value that holds the full window, or nil
    /// when even the maximum is not enough.
    public let minimumCapMBToFit: Double?

    public var isCapLimited: Bool { coveredSeconds < requestedSeconds }

    public var tier: Tier {
        if requestedSeconds <= Self.lightThresholdSeconds { return .light }
        if requestedSeconds < Self.heavyThresholdSeconds { return .moderate }
        return .heavy
    }

    public var formattedRequired: String { Self.formatBytes(requiredBytes) }

    public static func make(
        bufferSeconds: Int,
        bitrateMbps: Double,
        isDualMode: Bool,
        isSeparateDualSave: Bool,
        captureSystemAudio: Bool,
        captureMicrophone: Bool,
        memoryCapMB: Double
    ) -> ReplayMemoryEstimate {
        // Side-by-side dual capture encodes one composite stream; separate
        // files encode one stream per display, each at the full bitrate.
        let videoStreams = isDualMode && isSeparateDualSave ? 2 : 1
        let audioSources = (captureSystemAudio ? 1 : 0) + (captureMicrophone ? 1 : 0)
        let retainedSeconds = Double(bufferSeconds) + AppSettings.ringBufferHeadroomSeconds

        let videoBytesPerSecond = max(bitrateMbps, 0.1) * 1_000_000 / 8
        let audioBytesPerSecond = Double(audioSources) * audioBytesPerSecondPerSource
        let requiredBytes = Int((videoBytesPerSecond * Double(videoStreams) + audioBytesPerSecond) * retainedSeconds)

        func coveredSeconds(capMB: Double) -> Int {
            let caps = AppSettings.ringBufferMemoryCaps(
                isDualMode: isDualMode,
                captureSystemAudio: captureSystemAudio,
                captureMicrophone: captureMicrophone,
                retainedSeconds: retainedSeconds,
                totalCapMB: capMB
            )
            // A clip is only whole while every buffer still holds the window,
            // so whichever runs out first sets the coverage. Eviction drops
            // whole keyframe groups, so the video buffer settles a little under
            // what the cap could hold; the headroom covers that.
            var held = Double(caps.videoPerBuffer) / videoBytesPerSecond
            if audioSources > 0 {
                held = min(held, Double(caps.audioPerBuffer) / audioBytesPerSecondPerSource)
            }
            let seconds = held - AppSettings.ringBufferHeadroomSeconds
            return max(0, Int(seconds.rounded(.down)))
        }

        var minimumCapMBToFit: Double?
        var candidate = memoryCapRangeMB.lowerBound
        while candidate <= memoryCapRangeMB.upperBound {
            if coveredSeconds(capMB: candidate) >= bufferSeconds {
                minimumCapMBToFit = candidate
                break
            }
            candidate += memoryCapStepMB
        }

        return ReplayMemoryEstimate(
            requestedSeconds: bufferSeconds,
            bitrateMbps: bitrateMbps,
            memoryCapMB: memoryCapMB,
            requiredBytes: requiredBytes,
            coveredSeconds: coveredSeconds(capMB: memoryCapMB),
            minimumCapMBToFit: minimumCapMBToFit
        )
    }

    public static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    public static func formatCapMB(_ megabytes: Double) -> String {
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        return "\(Int(megabytes)) MB"
    }

    /// "45 s", "2 min", "3 min 29 s".
    public static func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 { return "\(remainder) s" }
        if remainder == 0 { return "\(minutes) min" }
        return "\(minutes) min \(remainder) s"
    }
}
