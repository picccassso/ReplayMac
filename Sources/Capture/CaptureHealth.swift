import Foundation

public enum CaptureHealth {
    public static func isVideoStalled(
        isCaptureRunning: Bool,
        isSessionActive: Bool,
        monitoringStartedAt: Date,
        lastVideoSampleDate: Date?,
        now: Date,
        timeout: TimeInterval = 15
    ) -> Bool {
        guard isCaptureRunning, isSessionActive, timeout > 0 else {
            return false
        }

        let referenceDate = lastVideoSampleDate ?? monitoringStartedAt
        return now.timeIntervalSince(referenceDate) >= timeout
    }

    /// True when a capture-side audio track has gone quiet for `timeout`.
    ///
    /// ScreenCaptureKit keeps delivering buffers while a stream is up, silence
    /// included, so a genuinely idle machine still ticks this over. A gap means
    /// the audio tap itself has stalled — which is what an output-device change
    /// mid-call produces, and which the stream-stopped delegate never reports
    /// because the video half of the stream carries on.
    ///
    /// The timeout is deliberately long: this only ever raises a warning, since
    /// tearing the pipeline down mid-recording on a false positive would cost
    /// the user more than the stall does.
    public static func isAudioStalled(
        isCaptureRunning: Bool,
        isCapturingAudio: Bool,
        isSessionActive: Bool,
        monitoringStartedAt: Date,
        lastAudioSampleDate: Date?,
        now: Date,
        timeout: TimeInterval = 30
    ) -> Bool {
        guard isCaptureRunning, isCapturingAudio, isSessionActive, timeout > 0 else {
            return false
        }

        let referenceDate = lastAudioSampleDate ?? monitoringStartedAt
        return now.timeIntervalSince(referenceDate) >= timeout
    }
}

public enum CaptureRecoveryPolicy {
    public static let maximumAttempts = 5

    public static func shouldScheduleRecovery(
        automaticResumeEnabled: Bool,
        shouldResume: Bool,
        isSessionActive: Bool,
        areScreensAwake: Bool,
        isPreparingRecovery: Bool,
        hasScheduledRecovery: Bool
    ) -> Bool {
        automaticResumeEnabled
            && shouldResume
            && isSessionActive
            && areScreensAwake
            && !isPreparingRecovery
            && !hasScheduledRecovery
    }

    public static func shouldRecoverUnexpectedStreamStop(
        automaticResumeEnabled: Bool,
        captureWasRunning: Bool
    ) -> Bool {
        automaticResumeEnabled && captureWasRunning
    }

    public static func shouldPreserveTransitionStop(
        automaticResumeEnabled: Bool,
        shouldResume: Bool,
        isSessionActive: Bool,
        areScreensAwake: Bool,
        isPreparingRecovery: Bool
    ) -> Bool {
        automaticResumeEnabled && shouldResume
            && (isPreparingRecovery || !isSessionActive || !areScreensAwake)
    }

    public static func retryDelay(completedAttempts: Int) -> TimeInterval {
        let attempt = max(0, completedAttempts)
        return min(2 * pow(2, Double(attempt)), 10)
    }

    public static func isStableRestart(
        isCaptureRunning: Bool,
        lastVideoSampleDate: Date?,
        now: Date,
        maximumSampleAge: TimeInterval = 5
    ) -> Bool {
        guard isCaptureRunning,
              maximumSampleAge > 0,
              let lastVideoSampleDate else {
            return false
        }
        return now.timeIntervalSince(lastVideoSampleDate) <= maximumSampleAge
    }
}
