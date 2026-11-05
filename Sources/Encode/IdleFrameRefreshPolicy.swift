import Foundation
@preconcurrency import CoreMedia

/// Keeps the encoded stream moving while the screen is still.
///
/// ScreenCaptureKit only hands over a complete frame when something on screen
/// changes; while the screen is still it sends idle frames with no image, which
/// never reach the encoder. Without input the encoder emits nothing, so the
/// replay buffer's newest frame stayed at the moment the screen froze while
/// audio kept arriving. A save measures its window back from that frame, so
/// after a still stretch the clip reached further back than the audio buffer
/// and opened on seconds of padded silence, and it ended at the freeze rather
/// than at the save. Keyframes can only land on frames the encoder receives,
/// so a still stretch also left them many seconds apart, which pushed a save's
/// keyframe snap-back past the audio buffer's headroom.
///
/// The encoder therefore repeats its last frame whenever it has gone
/// `idleInterval` without one. An unchanged frame compresses to almost
/// nothing, and the stream stays on the host clock that audio is stamped with.
public enum IdleFrameRefreshPolicy {
    /// How long the encoder may go without a frame before repeating the last one.
    public static let idleInterval = CMTime(value: 1, timescale: 4)

    /// How often the encoder checks whether it has gone idle.
    public static let checkInterval: TimeInterval = 0.1

    /// Longest keyframe gap left to VideoToolbox before one is forced. The
    /// session asks for one every 2 s; this backstop sits a little above that
    /// so it never doubles up with a keyframe VideoToolbox already scheduled.
    public static let maximumKeyframeGap = CMTime(value: 5, timescale: 2)

    /// Worst-case spacing between keyframes in the encoded stream: the forced
    /// keyframe backstop plus the longest wait for the frame it lands on. A
    /// saved clip starts on the keyframe at or before its window, so the ring
    /// buffers' headroom has to cover this.
    public static var worstCaseKeyframeSpacing: TimeInterval {
        maximumKeyframeGap.seconds + idleInterval.seconds + checkInterval
    }

    /// Smallest step used to keep presentation times strictly increasing.
    static let minimumPTSStep = CMTime(value: 1, timescale: 1_000)

    /// True when the encoder has gone `idleInterval` without a frame.
    public static func shouldRefresh(lastSubmittedPTS: CMTime, now: CMTime) -> Bool {
        guard lastSubmittedPTS.isNumeric, now.isNumeric else { return false }
        return CMTimeCompare(CMTimeSubtract(now, lastSubmittedPTS), idleInterval) >= 0
    }

    /// A repeated frame is stamped with the current host time, and a real frame
    /// captured just before it can reach the encoder just after. The encoder
    /// and the ring buffers need presentation times in order, so a frame that
    /// would land at or before the previous one is nudged just past it.
    public static func monotonicPTS(_ proposed: CMTime, after last: CMTime) -> CMTime {
        guard proposed.isNumeric, last.isNumeric else { return proposed }
        guard CMTimeCompare(proposed, last) <= 0 else { return proposed }
        return CMTimeAdd(last, minimumPTSStep)
    }

    /// True when the gap since the last keyframe has reached `maximumKeyframeGap`.
    public static func shouldForceKeyframe(pts: CMTime, lastKeyframePTS: CMTime) -> Bool {
        guard pts.isNumeric, lastKeyframePTS.isNumeric else { return false }
        return CMTimeCompare(CMTimeSubtract(pts, lastKeyframePTS), maximumKeyframeGap) >= 0
    }
}
