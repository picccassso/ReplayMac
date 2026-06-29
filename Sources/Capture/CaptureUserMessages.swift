import Foundation

public struct CaptureUserMessage: Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public extension CaptureInterruption {
    var userMessage: CaptureUserMessage? {
        switch self {
        case .systemStopped:
            return CaptureUserMessage(
                title: "Recording Paused",
                body: "macOS interrupted screen capture. ReplayMac will resume when your session is active."
            )
        case .permissionRevoked:
            return CaptureUserMessage(
                title: "Screen Recording Disabled",
                body: "ReplayMac no longer has Screen Recording permission. Enable it in System Settings → Privacy & Security → Screen Recording."
            )
        case .displayDisconnected:
            return CaptureUserMessage(
                title: "Display Disconnected",
                body: "The selected display was disconnected. Recording has stopped."
            )
        case .stopped(let reason):
            return CaptureUserMessage(
                title: "Recording Stopped",
                body: reason
            )
        }
    }
}

public extension CapturePermissionError {
    var userMessage: CaptureUserMessage {
        switch self {
        case .denied:
            return CaptureUserMessage(
                title: "Screen Recording Permission Required",
                body: "Enable ReplayMac in System Settings → Privacy & Security → Screen Recording, then choose Start Recording from the menu bar."
            )
        case .noDisplaysAvailable:
            return CaptureUserMessage(
                title: "No Displays Available",
                body: "ReplayMac could not find a display to capture."
            )
        case .pickerFailed(let error):
            return CaptureUserMessage(
                title: "Screen Recording Setup Failed",
                body: error.localizedDescription
            )
        }
    }
}

public extension CaptureError {
    var userMessage: CaptureUserMessage {
        switch self {
        case .noDisplay:
            return CaptureUserMessage(
                title: "No Display Selected",
                body: "Choose a display in Settings → Video, then start recording again."
            )
        case .notEnoughDisplays:
            return CaptureUserMessage(
                title: "Dual Display Unavailable",
                body: "Dual capture requires at least two connected displays."
            )
        case .sameDisplay:
            return CaptureUserMessage(
                title: "Duplicate Display Selection",
                body: "Display 1 and Display 2 must be different monitors."
            )
        }
    }
}

public enum CaptureStartErrorMapper {
    public static func userMessage(for error: Error) -> CaptureUserMessage {
        if let permissionError = error as? CapturePermissionError {
            return permissionError.userMessage
        }
        if let captureError = error as? CaptureError {
            return captureError.userMessage
        }

        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("permission")
            || description.localizedCaseInsensitiveContains("denied") {
            return CapturePermissionError.denied.userMessage
        }

        return CaptureUserMessage(
            title: "Recording Failed to Start",
            body: description
        )
    }
}
