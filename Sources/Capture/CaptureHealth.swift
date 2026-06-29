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
}
