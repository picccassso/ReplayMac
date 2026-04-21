import Foundation
import AppKit
@preconcurrency import UserNotifications

public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = NotificationManager()

    private var center: UNUserNotificationCenter?

    private override init() {
        super.init()
        // UNUserNotificationCenter crashes if called outside a proper .app bundle.
        // Only set up when running inside an app bundle.
        if Bundle.main.bundlePath.hasSuffix(".app") {
            self.center = UNUserNotificationCenter.current()
            self.center?.delegate = self
        }
    }

    public func requestAuthorization() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            guard let self, let center = self.center else {
                return
            }

            guard settings.authorizationStatus == .notDetermined else {
                return
            }

            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    print("Notification authorization error: \(error.localizedDescription)")
                }
                if !granted {
                    print("Notification authorization denied by user.")
                }
            }
        }
    }

    public func showClipSavedNotification(fileURL: URL, clipDuration: TimeInterval) {
        guard let center else { return }

        center.getNotificationSettings { [weak self] settings in
            guard let self, let center = self.center else {
                return
            }

            guard settings.authorizationStatus != .denied else {
                print("Notifications are disabled for ReplayMac in System Settings.")
                return
            }

            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else {
                        return
                    }
                    self.postClipSavedNotification(center: center, fileURL: fileURL, clipDuration: clipDuration)
                }
                return
            }

            self.postClipSavedNotification(center: center, fileURL: fileURL, clipDuration: clipDuration)
        }
    }

    private func postClipSavedNotification(
        center: UNUserNotificationCenter,
        fileURL: URL,
        clipDuration: TimeInterval
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Clip Saved"
        content.body = "\(Int(clipDuration.rounded()))s clip saved as \(fileURL.lastPathComponent)"
        content.sound = .default
        content.userInfo = ["clipPath": fileURL.path(percentEncoded: false)]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                print("Failed to post clip saved notification: \(error.localizedDescription)")
            }
        }
    }

    public func showSaveFailedNotification(error: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Clip Save Failed"
        content.body = error
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { addError in
            if let addError {
                print("Failed to post clip failure notification: \(addError.localizedDescription)")
            }
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.list, .banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer {
            completionHandler()
        }

        guard let clipPath = response.notification.request.content.userInfo["clipPath"] as? String else {
            return
        }

        let clipURL = URL(fileURLWithPath: clipPath)
        NSWorkspace.shared.activateFileViewerSelecting([clipURL])
    }
}
