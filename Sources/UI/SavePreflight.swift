import Foundation

public enum SavePreflightFailure: Equatable {
    case saveInProgress
    case notRecording
    case replayBufferUnavailable
    case bufferEmpty
    case insufficientDiskSpace
}

public enum SavePreflight {
    public static let minimumBufferedSeconds: TimeInterval = 1

    public static func canSaveQuickReplay(
        isRecording: Bool,
        bufferedSeconds: TimeInterval,
        saveInProgress: Bool,
        replayBufferEnabled: Bool = true
    ) -> Bool {
        failure(
            isRecording: isRecording,
            bufferedSeconds: bufferedSeconds,
            saveInProgress: saveInProgress,
            replayBufferEnabled: replayBufferEnabled
        ) == nil
    }

    public static func canSaveLongReplay(
        isRecording: Bool,
        saveInProgress: Bool,
        replayBufferEnabled: Bool = true
    ) -> Bool {
        isRecording && !saveInProgress && replayBufferEnabled
    }

    public static func bufferedSeconds(
        primaryVideo: TimeInterval,
        dualDisplay1: TimeInterval,
        dualDisplay2: TimeInterval,
        isSeparateDualSave: Bool
    ) -> TimeInterval {
        guard isSeparateDualSave else {
            return primaryVideo
        }

        return min(dualDisplay1, dualDisplay2)
    }

    /// - Parameter replayBufferEnabled: false while a session recording owns
    ///   the capture pipeline. The buffers are deliberately not being filled,
    ///   so reporting them as still filling would promise something that will
    ///   never happen.
    public static func failure(
        isRecording: Bool,
        bufferedSeconds: TimeInterval,
        saveInProgress: Bool,
        replayBufferEnabled: Bool = true,
        minimumBufferedSeconds: TimeInterval = minimumBufferedSeconds
    ) -> SavePreflightFailure? {
        if saveInProgress {
            return .saveInProgress
        }
        if !isRecording {
            return .notRecording
        }
        if !replayBufferEnabled {
            return .replayBufferUnavailable
        }
        if bufferedSeconds < minimumBufferedSeconds {
            return .bufferEmpty
        }
        return nil
    }

    public static func notificationMessage(for failure: SavePreflightFailure) -> (title: String, body: String) {
        switch failure {
        case .saveInProgress:
            return ("Save Already in Progress", "Wait for the current clip to finish saving.")
        case .notRecording:
            return ("Not Recording", "Start recording before saving a clip.")
        case .replayBufferUnavailable:
            return (
                "Replay Buffer Off",
                "A session recording is in progress. Stop it to save the session, or start buffer recording to capture replays."
            )
        case .bufferEmpty:
            return ("Buffer Still Filling", "Wait a moment for footage to buffer before saving.")
        case .insufficientDiskSpace:
            return ("Not Enough Disk Space", "Free up space on your drive before saving this clip.")
        }
    }

    /// Rough upper-bound size of a clip from its target bitrate and duration.
    /// `streamCount` covers separate dual-display saves (two files), and
    /// `overhead` pads for muxing, audio tracks, and keyframe bitrate spikes.
    public static func estimatedClipBytes(
        bitrateMbps: Double,
        durationSeconds: TimeInterval,
        streamCount: Int = 1,
        overhead: Double = 1.2
    ) -> Int64 {
        guard bitrateMbps > 0, durationSeconds > 0 else {
            return 0
        }
        let bytesPerStream = (bitrateMbps * 1_000_000 / 8) * durationSeconds
        let total = bytesPerStream * Double(max(streamCount, 1)) * overhead
        return Int64(total)
    }

    /// Reports a failure when the volume lacks room for the estimated clip plus
    /// a safety margin. Returns `nil` when the estimate is unknown (zero) so a
    /// missing estimate never blocks a save.
    public static func diskFailure(
        estimatedClipBytes: Int64,
        availableCapacityBytes: Int64,
        safetyMarginBytes: Int64 = 200 * 1024 * 1024
    ) -> SavePreflightFailure? {
        guard estimatedClipBytes > 0 else {
            return nil
        }
        if availableCapacityBytes < estimatedClipBytes + safetyMarginBytes {
            return .insufficientDiskSpace
        }
        return nil
    }
}
