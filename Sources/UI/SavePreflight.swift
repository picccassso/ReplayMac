import Foundation

public enum SavePreflightFailure: Equatable {
    case saveInProgress
    case notRecording
    case bufferEmpty
}

public enum SavePreflight {
    public static let minimumBufferedSeconds: TimeInterval = 1

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

    public static func failure(
        isRecording: Bool,
        bufferedSeconds: TimeInterval,
        saveInProgress: Bool,
        minimumBufferedSeconds: TimeInterval = minimumBufferedSeconds
    ) -> SavePreflightFailure? {
        if saveInProgress {
            return .saveInProgress
        }
        if !isRecording {
            return .notRecording
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
        case .bufferEmpty:
            return ("Buffer Still Filling", "Wait a moment for footage to buffer before saving.")
        }
    }
}
