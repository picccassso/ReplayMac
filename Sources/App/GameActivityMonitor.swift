import AppKit
import Capture
import Foundation
import UI
import os

/// Watches the workspace for game applications and reports when the user starts
/// or stops playing one, so the app can begin and end recording automatically.
///
/// Detection combines two signals:
///  - Apple's App Store "Games" category, read from each app's Info.plist. This
///    needs no setup and covers most native and App Store games.
///  - A user-managed list of bundle identifiers, for titles (many Steam games)
///    that do not declare that category. This path reads only the bundle id
///    delivered by the workspace notification, so it also works when file
///    access to other app bundles is unavailable.
///
/// "Playing" is treated as: a game is launched, is already running when watching
/// begins, or is brought to the front. Recording continues across brief app
/// switches (alt-tab) and only the *last* game quitting reports a stop, so a
/// short detour to another window never interrupts a clip buffer.
@MainActor
final class GameActivityMonitor: NSObject {
    /// Fired when a game becomes active and none were active before. The string
    /// is a human-readable app name for use in notifications.
    var onGameActivityStarted: ((String) -> Void)?
    /// Fired when the last tracked game terminates.
    var onGameActivityStopped: (() -> Void)?

    private let logger = Logger(subsystem: "com.replaycap", category: "GameAutoRecord")
    private let workspace = NSWorkspace.shared

    private var isRunning = false
    /// Process ids of games currently considered "playing", keyed so repeated
    /// activations of an already-tracked game don't re-fire the start callback.
    private var activeGamePIDs: Set<pid_t> = []
    /// Caches whether a bundle path's declared category is a game, so we read
    /// each app's Info.plist at most once.
    private var categoryIsGameCache: [String: Bool] = [:]

    /// Begins watching for game activity and immediately evaluates apps that are
    /// already running (so enabling the feature while a game is open records it).
    func start() {
        guard !isRunning else { return }
        isRunning = true

        let center = workspace.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationLaunchedOrActivated(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationLaunchedOrActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        logger.info("Game auto-record monitoring started")
        scanRunningApplications()
    }

    /// Stops watching. Does not itself change recording state — the owner
    /// decides what to do with any recording that was auto-started.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        workspace.notificationCenter.removeObserver(self)
        activeGamePIDs.removeAll()
        logger.info("Game auto-record monitoring stopped")
    }

    /// Re-evaluates running apps after the user edits the manual game list, so a
    /// newly listed app that is already open starts recording without relaunch.
    func refreshManualGameList() {
        guard isRunning else { return }
        scanRunningApplications()
    }

    // MARK: - Workspace events

    @objc private func applicationLaunchedOrActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        registerIfGame(app)
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        let pid = app.processIdentifier
        guard activeGamePIDs.remove(pid) != nil else { return }
        logger.info("Tracked game terminated (pid \(pid, privacy: .public)); \(self.activeGamePIDs.count, privacy: .public) remaining")
        if activeGamePIDs.isEmpty {
            onGameActivityStopped?()
        }
    }

    // MARK: - Detection

    private func scanRunningApplications() {
        var currentMatchingPIDs = Set<pid_t>()
        for app in workspace.runningApplications {
            if registerIfGame(app) {
                currentMatchingPIDs.insert(app.processIdentifier)
            }
        }

        let previousPIDs = activeGamePIDs
        activeGamePIDs.formIntersection(currentMatchingPIDs)
        if !previousPIDs.isEmpty && activeGamePIDs.isEmpty {
            logger.info("All active games closed or excluded; stopping game recording")
            onGameActivityStopped?()
        }
    }

    @discardableResult
    private func registerIfGame(_ app: NSRunningApplication) -> Bool {
        // Only user-facing apps: skip menu-bar agents, daemons, and ourselves.
        guard app.activationPolicy == .regular else { return false }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        guard isGame(app) else { return false }

        let pid = app.processIdentifier
        let wasIdle = activeGamePIDs.isEmpty
        let inserted = activeGamePIDs.insert(pid).inserted
        if inserted {
            logger.info("Detected game \(app.bundleIdentifier ?? "?", privacy: .public) (pid \(pid, privacy: .public))")
            if wasIdle {
                onGameActivityStarted?(app.localizedName ?? app.bundleIdentifier ?? "a game")
            }
        }
        return true
    }

    private func isGame(_ app: NSRunningApplication) -> Bool {
        let manualBundleIDs = Set(AppSettings.autoRecordGameBundleIDs)
        let excludedBundleIDs = Set(AppSettings.autoRecordExcludedBundleIDs)
        return GameAppClassifier.isGame(
            bundleIdentifier: app.bundleIdentifier,
            category: declaredCategory(of: app),
            manualBundleIDs: manualBundleIDs,
            excludedBundleIDs: excludedBundleIDs
        )
    }

    /// Reads and caches the app's declared App Store category. Returns nil when
    /// the bundle cannot be read (e.g. under a restrictive sandbox), in which
    /// case only the manual list applies to that app.
    private func declaredCategory(of app: NSRunningApplication) -> String? {
        guard let bundleURL = app.bundleURL else { return nil }
        let path = bundleURL.path
        if let cached = categoryIsGameCache[path] {
            return cached ? "public.app-category.games" : nil
        }
        let category = Bundle(url: bundleURL)?
            .object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        categoryIsGameCache[path] = GameAppClassifier.isGameCategory(category)
        return category
    }
}
