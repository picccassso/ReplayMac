import Foundation

/// Applies a gain to interleaved Float32 audio and holds the result under
/// full scale by turning the gain down across a loud passage, instead of
/// flattening each peak the way a clamp does.
///
/// A boosted microphone needs this: speech that is comfortable at 300% has
/// consonants and laughs that would land well past full scale, and clamped
/// they come out as harsh crackle. Audio that stays under the ceiling passes
/// through untouched, sample for sample.
///
/// There is no look-ahead, so the gain drops on the very sample that crosses
/// the ceiling. Every channel of a frame shares one gain, which keeps a stereo
/// image from shifting when only one side is loud.
struct PeakLimiter {
    /// Full scale. Nothing leaves `process` above this.
    static let ceiling: Float = 1

    /// How long the gain takes to come most of the way back after a peak.
    /// Long enough not to ride the individual cycles of a low voice, short
    /// enough that a cough does not duck the sentence after it.
    static let releaseSeconds = 0.15

    /// The limiter's own gain, 1 when idle and lower while it is holding a
    /// loud passage down. Carried between buffers so the release runs across
    /// buffer edges without a step.
    private(set) var reduction: Float = 1

    /// Scales `samples` by `gain` and limits the result in place.
    /// `samples` holds `channelCount` interleaved channels.
    mutating func process(
        _ samples: UnsafeMutableBufferPointer<Float>,
        channelCount: Int,
        gain: Float,
        sampleRate: Double
    ) {
        guard channelCount > 0, sampleRate > 0 else { return }
        let frameCount = samples.count / channelCount
        guard frameCount > 0 else { return }

        let release = Float(exp(-1 / (Self.releaseSeconds * sampleRate)))
        var reduction = self.reduction

        for frame in 0..<frameCount {
            let base = frame * channelCount
            var peak: Float = 0
            for channel in 0..<channelCount {
                let scaled = samples[base + channel] * gain
                samples[base + channel] = scaled
                peak = max(peak, abs(scaled))
            }

            // Recover toward unity, then drop at once if this frame would
            // still be over the ceiling.
            reduction = 1 - (1 - reduction) * release
            if peak * reduction > Self.ceiling {
                reduction = Self.ceiling / peak
            }
            guard reduction < 1 else { continue }

            for channel in 0..<channelCount {
                samples[base + channel] *= reduction
            }
        }

        // A non-finite sample (a device glitch) would otherwise poison the
        // gain for the rest of the run.
        self.reduction = reduction.isFinite ? min(max(reduction, 0), 1) : 1
    }

    mutating func reset() {
        reduction = 1
    }
}
