import Foundation
@preconcurrency import CoreMedia

/// Assigns presentation timestamps to microphone buffers.
///
/// Within an unbroken run of buffers, timestamps advance by frame count, which
/// keeps them sample-accurate and free of the jitter in per-buffer host times.
/// Frame counting alone, though, silently absorbs every dropout: a stall in
/// delivery would shift the entire remaining mic timeline earlier by the length
/// of the stall, and since clips select audio by absolute PTS against the video
/// window, a mic drifting far enough behind stops overlapping that window and
/// vanishes from the saved clip entirely.
///
/// So each buffer's own host time is checked against where frame counting says
/// it should land, and a discontinuity past the threshold re-anchors the
/// timeline — turning a dropout back into the real gap it was.
struct MicrophoneTimeline {
    struct Stamp {
        let presentationTime: CMTime
        /// Non-nil when this buffer re-anchored the timeline, carrying the
        /// size of the discontinuity in seconds (positive when the mic fell
        /// behind the host clock).
        let reanchoredBySeconds: Double?
    }

    let resyncThresholdSeconds: Double

    private var anchor: CMTime?
    private var framesEmitted: Int64 = 0

    init(resyncThresholdSeconds: Double) {
        self.resyncThresholdSeconds = resyncThresholdSeconds
    }

    mutating func reset() {
        anchor = nil
        framesEmitted = 0
    }

    /// - Parameters:
    ///   - hostTime: the buffer's capture instant on the host clock, the same
    ///     clock ScreenCaptureKit stamps video with.
    ///   - frameCount: output frames in this buffer.
    ///   - sampleRate: output sample rate.
    mutating func stamp(
        hostTime: CMTime,
        frameCount: Int64,
        sampleRate: Double
    ) -> Stamp {
        guard sampleRate > 0, frameCount > 0 else {
            return Stamp(presentationTime: hostTime, reanchoredBySeconds: nil)
        }

        guard let existingAnchor = anchor else {
            anchor = hostTime
            framesEmitted = frameCount
            return Stamp(presentationTime: hostTime, reanchoredBySeconds: nil)
        }

        let expected = CMTimeAdd(
            existingAnchor,
            CMTime(value: framesEmitted, timescale: CMTimeScale(sampleRate))
        )
        let drift = CMTimeGetSeconds(CMTimeSubtract(hostTime, expected))

        guard abs(drift) > resyncThresholdSeconds else {
            let presentationTime = expected
            framesEmitted += frameCount
            return Stamp(presentationTime: presentationTime, reanchoredBySeconds: nil)
        }

        anchor = hostTime
        framesEmitted = frameCount
        return Stamp(presentationTime: hostTime, reanchoredBySeconds: drift)
    }
}
