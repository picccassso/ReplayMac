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
