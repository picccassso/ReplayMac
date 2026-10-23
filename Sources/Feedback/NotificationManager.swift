import Branding
import Foundation
import AppKit
import os.log
@preconcurrency import UserNotifications

private let notificationLogger = Logger(subsystem: "com.replaycap", category: "Notifications")

public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = NotificationManager()

    private var center: UNUserNotificationCenter?

    private enum Category {
        static let clipSaved = "CLIP_SAVED"
    }

    private enum Action {
        static let open = "OPEN_CLIP"
        static let revealInFinder = "REVEAL_IN_FINDER"
    }

    private override init() {
        super.init()
        // UNUserNotificationCenter crashes if called outside a proper .app bundle.
        // Only set up when running inside an app bundle.
        if Bundle.main.bundlePath.hasSuffix(".app") {
            self.center = UNUserNotificationCenter.current()
            self.center?.delegate = self
            registerCategories()
        }
    }

    private func registerCategories() {
        guard let center else { return }

        let openAction = UNNotificationAction(
            identifier: Action.open,
            title: "Open",
            options: [.foreground]
        )
        let revealAction = UNNotificationAction(
            identifier: Action.revealInFinder,
            title: "Reveal in Finder",
            options: [.foreground]
        )
        let clipSaved = UNNotificationCategory(
            identifier: Category.clipSaved,
            actions: [openAction, revealAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([clipSaved])
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
                    notificationLogger.error("Notification authorization error: \(error.localizedDescription, privacy: .public)")
                }
                if !granted {
                    notificationLogger.info("Notification authorization denied by user.")
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
                notificationLogger.info("Notifications are disabled for \(AppBranding.name, privacy: .public) in System Settings.")
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
        content.categoryIdentifier = Category.clipSaved
        content.userInfo = ["clipPath": fileURL.path(percentEncoded: false)]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                notificationLogger.error("Failed to post clip saved notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func showSaveFailedNotification(error: String) {
        showOperationalNotification(title: "Clip Save Failed", body: error)
    }

    public func showOperationalNotification(title: String, body: String) {
        guard let center else { return }

        center.getNotificationSettings { [weak self] settings in
            guard let self, let center = self.center else {
                return
            }

            guard settings.authorizationStatus != .denied else {
                notificationLogger.info("Notifications are disabled for \(AppBranding.name, privacy: .public) in System Settings.")
                return
            }

            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else {
                        return
                    }
                    self.postOperationalNotification(center: center, title: title, body: body)
                }
                return
            }

            self.postOperationalNotification(center: center, title: title, body: body)
        }
    }

    private func postOperationalNotification(
        center: UNUserNotificationCenter,
        title: String,
        body: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { addError in
            if let addError {
                notificationLogger.error("Failed to post operational notification: \(addError.localizedDescription, privacy: .public)")
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
        guard FileManager.default.fileExists(atPath: clipURL.path) else {
            // Clip was moved, renamed, or deleted since the notification posted.
            return
        }

        switch response.actionIdentifier {
        case Action.open:
            NSWorkspace.shared.open(clipURL)
        case Action.revealInFinder, UNNotificationDefaultActionIdentifier:
            // Tapping the notification body keeps the original reveal behavior.
            NSWorkspace.shared.activateFileViewerSelecting([clipURL])
        default:
            break
        }
    }
}
