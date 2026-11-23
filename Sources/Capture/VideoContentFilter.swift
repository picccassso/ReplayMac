import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

public enum VideoCaptureFilterMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case fullDisplay = "full_display"
    case hideOverlays = "hide_overlays"
    case activeApp = "active_app"
    case selectedApp = "selected_app"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullDisplay:
            return "Full display"
        case .hideOverlays:
            return "Hide overlays"
        case .activeApp:
            return "Active app only"
        case .selectedApp:
            return "Selected app only"
        }
    }
}

public struct VideoAppIdentity: Equatable, Hashable, Sendable {
    public let pid: pid_t
    public let bundleIdentifier: String?

    public init(pid: pid_t, bundleIdentifier: String?) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct VideoContentFilterConfig: Equatable, Sendable {
    public var mode: VideoCaptureFilterMode
    public var hideMenuBar: Bool
    public var hideFloatingUtilityApps: Bool
    public var hiddenBundleIDs: [String]
    public var selectedAppBundleID: String
    public var activeAppPID: pid_t?
    public var activeAppBundleID: String?
    public var ownBundleID: String?

    public init(
        mode: VideoCaptureFilterMode = .fullDisplay,
        hideMenuBar: Bool = false,
        hideFloatingUtilityApps: Bool = true,
        hiddenBundleIDs: [String] = [],
        selectedAppBundleID: String = "",
        activeAppPID: pid_t? = nil,
        activeAppBundleID: String? = nil,
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.mode = mode
        self.hideMenuBar = hideMenuBar
        self.hideFloatingUtilityApps = hideFloatingUtilityApps
        self.hiddenBundleIDs = hiddenBundleIDs
        self.selectedAppBundleID = selectedAppBundleID
        self.activeAppPID = activeAppPID
        self.activeAppBundleID = activeAppBundleID
        self.ownBundleID = ownBundleID
    }

    public static let fullDisplay = VideoContentFilterConfig()

    /// True whenever the video SCContentFilter excludes applications, which
    /// would also exclude those apps' audio if system audio were captured on
    /// the same SCStream.
    public var excludesOtherApplications: Bool {
        mode != .fullDisplay
    }
}

public enum AppActivationKind: Equatable, Sendable {
    case regular
    case accessory
    case prohibited
    case unknown

    public init(policy: NSApplication.ActivationPolicy) {
        switch policy {
        case .regular:
            self = .regular
        case .accessory:
            self = .accessory
        case .prohibited:
            self = .prohibited
        @unknown default:
            self = .unknown
        }
    }
}

public struct CapturableAppSnapshot: Equatable, Sendable {
    public let pid: pid_t
    public let bundleIdentifier: String
    public let activationKind: AppActivationKind

    public init(pid: pid_t, bundleIdentifier: String, activationKind: AppActivationKind) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.activationKind = activationKind
    }
}

public struct CapturableWindowSnapshot: Equatable, Sendable {
    public let windowID: CGWindowID
    public let owningPID: pid_t?
    public let owningBundleIdentifier: String?
    public let frame: CGRect
    public let windowLayer: Int
    public let isOnScreen: Bool

    public init(
        windowID: CGWindowID,
        owningPID: pid_t?,
        owningBundleIdentifier: String?,
        frame: CGRect,
        windowLayer: Int,
        isOnScreen: Bool
    ) {
        self.windowID = windowID
        self.owningPID = owningPID
        self.owningBundleIdentifier = owningBundleIdentifier
        self.frame = frame
        self.windowLayer = windowLayer
        self.isOnScreen = isOnScreen
    }
}

public struct ResolvedVideoFilterPlan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case fullDisplay
        case exclude(
            excludedAppPIDs: Set<pid_t>,
            excludedWindowIDs: Set<CGWindowID>,
            includeMenuBar: Bool
        )
        case include(
            includedAppPIDs: Set<pid_t>,
            resolvedActiveApp: VideoAppIdentity?
        )
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

/// Pure, deterministic classifier that resolves a `VideoContentFilterConfig`
/// against a snapshot of running applications and windows on a display.
public enum VideoOverlayClassifier {
    /// macOS system overlay processes excluded automatically in Hide Overlays mode.
    public static let builtInOverlayBundleIDs: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.osduihelper",
        "com.apple.controlcenter",
        "com.apple.spotlight",
        "com.apple.siri",
        "com.apple.sirincservice",
        "com.apple.usernotificationcenter"
    ]

    /// Core desktop/shell processes that must never be auto-excluded by the
    /// accessory-app heuristic so wallpaper, Dock, and window management stay intact.
    public static let protectedShellBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.windowmanager",
        "com.apple.loginwindow",
        "com.apple.wallpaper.agent",
        "com.apple.wallpaperagent",
        "com.apple.screensaver.engine",
        "com.apple.systemuiserver"
    ]

    /// Minimum size (in points) for a normal-layer window to be treated as a
    /// primary app window owned by an accessory process (e.g. a helper-launched game).
    static let largeNormalWindowMinimumDimension: CGFloat = 200

    /// Minimum size (in points) for an on-screen window to count as a visible
    /// window of a regular app on a given display.
    static let visibleAppWindowMinimumDimension: CGFloat = 50

    public static func matchesBundleID(_ candidate: String, target: String) -> Bool {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty, !trimmedTarget.isEmpty else { return false }
        if trimmedCandidate.caseInsensitiveCompare(trimmedTarget) == .orderedSame {
            return true
        }
        return trimmedCandidate.lowercased().hasPrefix(trimmedTarget.lowercased() + ".")
    }

    public static func matchesAnyBundleID(_ candidate: String, in targets: some Collection<String>) -> Bool {
        targets.contains { matchesBundleID(candidate, target: $0) }
    }

    public static func resolve(
        displayFrame: CGRect,
        applications: [CapturableAppSnapshot],
        windows: [CapturableWindowSnapshot],
        config: VideoContentFilterConfig,
        lastActiveApp: VideoAppIdentity? = nil
    ) -> ResolvedVideoFilterPlan {
        switch config.mode {
        case .fullDisplay:
            return ResolvedVideoFilterPlan(kind: .fullDisplay)

        case .hideOverlays:
            return resolveHideOverlays(
                applications: applications,
                windows: windows,
                config: config
            )

        case .activeApp:
            return resolveActiveApp(
                displayFrame: displayFrame,
                applications: applications,
                windows: windows,
                config: config,
                lastActiveApp: lastActiveApp
            )

        case .selectedApp:
            return resolveSelectedApp(
                applications: applications,
                config: config
            )
        }
    }

    private static func resolveHideOverlays(
        applications: [CapturableAppSnapshot],
        windows: [CapturableWindowSnapshot],
        config: VideoContentFilterConfig
    ) -> ResolvedVideoFilterPlan {
        // Accessory apps that own a large normal-layer window (e.g. a game or
        // helper process rendering main content) should not be auto-hidden.
        let pidsWithLargeNormalWindows: Set<pid_t> = Set(
            windows.compactMap { window in
                guard window.isOnScreen,
                      window.windowLayer == 0,
                      window.frame.width >= largeNormalWindowMinimumDimension,
                      window.frame.height >= largeNormalWindowMinimumDimension else {
                    return nil
                }
                return window.owningPID
            }
        )

        var excludedPIDs = Set<pid_t>()
        for app in applications {
            if matchesAnyBundleID(app.bundleIdentifier, in: config.hiddenBundleIDs) {
                excludedPIDs.insert(app.pid)
                continue
            }
            if matchesAnyBundleID(app.bundleIdentifier, in: builtInOverlayBundleIDs) {
                excludedPIDs.insert(app.pid)
                continue
            }
            if config.hideFloatingUtilityApps,
               app.activationKind == .accessory,
               !isOwnApp(bundleIdentifier: app.bundleIdentifier, ownBundleID: config.ownBundleID),
               !matchesAnyBundleID(app.bundleIdentifier, in: protectedShellBundleIDs),
               !pidsWithLargeNormalWindows.contains(app.pid) {
                excludedPIDs.insert(app.pid)
            }
        }

        // Hide ReplayMac's own floating panels (such as the saved-clip thumbnail
        // toast) without hiding its normal main/settings window.
        var ownFloatingWindowIDs = Set<CGWindowID>()
        if let ownBundleID = config.ownBundleID, !ownBundleID.isEmpty {
            for window in windows {
                guard window.windowLayer > 0,
                      let bundleID = window.owningBundleIdentifier,
                      isOwnApp(bundleIdentifier: bundleID, ownBundleID: ownBundleID) else {
                    continue
                }
                if let pid = window.owningPID, excludedPIDs.contains(pid) {
                    continue
                }
                ownFloatingWindowIDs.insert(window.windowID)
            }
        }

        return ResolvedVideoFilterPlan(
            kind: .exclude(
                excludedAppPIDs: excludedPIDs,
                excludedWindowIDs: ownFloatingWindowIDs,
                includeMenuBar: !config.hideMenuBar
            )
        )
    }

    private static func resolveActiveApp(
        displayFrame: CGRect,
        applications: [CapturableAppSnapshot],
        windows: [CapturableWindowSnapshot],
        config: VideoContentFilterConfig,
        lastActiveApp: VideoAppIdentity?
    ) -> ResolvedVideoFilterPlan {
        let appByPID = Dictionary(uniqueKeysWithValues: applications.map { ($0.pid, $0) })

        // 1. Prefer the newly/currently frontmost regular app if it has a visible window on this display.
        if let activePID = config.activeAppPID {
            let candidate = VideoAppIdentity(
                pid: activePID,
                bundleIdentifier: config.activeAppBundleID ?? appByPID[activePID]?.bundleIdentifier
            )
            if !isOwnApp(bundleIdentifier: candidate.bundleIdentifier, ownBundleID: config.ownBundleID),
               !isNonRegularApp(identity: candidate, appByPID: appByPID) {
                let matchingPIDs = matchingAppPIDs(for: candidate, in: applications)
                if !matchingPIDs.isEmpty,
                   hasVisibleWindow(ownedBy: matchingPIDs, on: displayFrame, in: windows) {
                    return ResolvedVideoFilterPlan(
                        kind: .include(includedAppPIDs: matchingPIDs, resolvedActiveApp: candidate)
                    )
                }
            }
        }

        // 2. Keep the last active app on this display if the user focused another monitor or an overlay.
        if let lastActiveApp,
           !isOwnApp(bundleIdentifier: lastActiveApp.bundleIdentifier, ownBundleID: config.ownBundleID) {
            let matchingPIDs = matchingAppPIDs(for: lastActiveApp, in: applications)
            if !matchingPIDs.isEmpty,
               hasVisibleWindow(ownedBy: matchingPIDs, on: displayFrame, in: windows) {
                return ResolvedVideoFilterPlan(
                    kind: .include(includedAppPIDs: matchingPIDs, resolvedActiveApp: lastActiveApp)
                )
            }
        }

        // 3. Fall back to the frontmost regular app with a visible window on this display.
        for window in windows {
            guard isVisibleAppWindow(window, on: displayFrame),
                  let pid = window.owningPID,
                  let app = appByPID[pid],
                  app.activationKind == .regular,
                  !isOwnApp(bundleIdentifier: app.bundleIdentifier, ownBundleID: config.ownBundleID) else {
                continue
            }
            let identity = VideoAppIdentity(
                pid: app.pid,
                bundleIdentifier: app.bundleIdentifier.isEmpty ? nil : app.bundleIdentifier
            )
            let matchingPIDs = matchingAppPIDs(for: identity, in: applications)
            return ResolvedVideoFilterPlan(
                kind: .include(includedAppPIDs: matchingPIDs, resolvedActiveApp: identity)
            )
        }

        // 4. Empty desktop on this display: stay privacy-safe (blank) until an app appears.
        return ResolvedVideoFilterPlan(
            kind: .include(includedAppPIDs: [], resolvedActiveApp: nil)
        )
    }

    private static func resolveSelectedApp(
        applications: [CapturableAppSnapshot],
        config: VideoContentFilterConfig
    ) -> ResolvedVideoFilterPlan {
        let target = config.selectedAppBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return ResolvedVideoFilterPlan(
                kind: .include(includedAppPIDs: [], resolvedActiveApp: nil)
            )
        }

        let matchingPIDs = Set(
            applications.compactMap { app -> pid_t? in
                matchesBundleID(app.bundleIdentifier, target: target) ? app.pid : nil
            }
        )
        return ResolvedVideoFilterPlan(
            kind: .include(includedAppPIDs: matchingPIDs, resolvedActiveApp: nil)
        )
    }

    private static func isOwnApp(bundleIdentifier: String?, ownBundleID: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let ownBundleID, !ownBundleID.isEmpty else {
            return false
        }
        return matchesBundleID(bundleIdentifier, target: ownBundleID)
    }

    private static func isNonRegularApp(
        identity: VideoAppIdentity,
        appByPID: [pid_t: CapturableAppSnapshot]
    ) -> Bool {
        guard let app = appByPID[identity.pid] else { return false }
        return app.activationKind == .accessory || app.activationKind == .prohibited
    }

    private static func matchingAppPIDs(
        for identity: VideoAppIdentity,
        in applications: [CapturableAppSnapshot]
    ) -> Set<pid_t> {
        var pids = Set<pid_t>()
        for app in applications {
            if app.pid == identity.pid {
                pids.insert(app.pid)
            } else if let bundleID = identity.bundleIdentifier,
                      !bundleID.isEmpty,
                      matchesBundleID(app.bundleIdentifier, target: bundleID) {
                pids.insert(app.pid)
            }
        }
        return pids
    }

    private static func isVisibleAppWindow(
        _ window: CapturableWindowSnapshot,
        on displayFrame: CGRect
    ) -> Bool {
        guard window.isOnScreen,
              window.frame.width >= visibleAppWindowMinimumDimension,
              window.frame.height >= visibleAppWindowMinimumDimension,
              window.frame.intersects(displayFrame) else {
            return false
        }
        return true
    }

    private static func hasVisibleWindow(
        ownedBy pids: Set<pid_t>,
        on displayFrame: CGRect,
        in windows: [CapturableWindowSnapshot]
    ) -> Bool {
        windows.contains { window in
            guard let pid = window.owningPID, pids.contains(pid) else { return false }
            return isVisibleAppWindow(window, on: displayFrame)
        }
    }
}

/// Bridges ScreenCaptureKit objects and `NSWorkspace` activation policies with
/// `VideoOverlayClassifier`.
public enum VideoContentFilterBuilder {
    @MainActor
    public static func currentActivationKinds() -> [pid_t: AppActivationKind] {
        var map: [pid_t: AppActivationKind] = [:]
        for app in NSWorkspace.shared.runningApplications {
            map[app.processIdentifier] = AppActivationKind(policy: app.activationPolicy)
        }
        return map
    }

    public static func makeFilter(
        for display: SCDisplay,
        content: SCShareableContent,
        activationKinds: [pid_t: AppActivationKind],
        config: VideoContentFilterConfig,
        lastActiveApp: VideoAppIdentity?
    ) -> (filter: SCContentFilter, resolvedActiveApp: VideoAppIdentity?) {
        let appSnapshots = content.applications.map { app in
            CapturableAppSnapshot(
                pid: app.processID,
                bundleIdentifier: app.bundleIdentifier,
                activationKind: activationKinds[app.processID] ?? .unknown
            )
        }
        let windowSnapshots = content.windows.map { window in
            CapturableWindowSnapshot(
                windowID: window.windowID,
                owningPID: window.owningApplication?.processID,
                owningBundleIdentifier: window.owningApplication?.bundleIdentifier,
                frame: window.frame,
                windowLayer: window.windowLayer,
                isOnScreen: window.isOnScreen
            )
        }

        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display.frame,
            applications: appSnapshots,
            windows: windowSnapshots,
            config: config,
            lastActiveApp: lastActiveApp
        )

        switch plan.kind {
        case .fullDisplay:
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            filter.includeMenuBar = true
            return (filter, nil)

        case .exclude(let excludedPIDs, let excludedWindowIDs, let includeMenuBar):
            let excludedApps = content.applications.filter { excludedPIDs.contains($0.processID) }
            let exceptingWindows = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: exceptingWindows
            )
            filter.includeMenuBar = includeMenuBar
            return (filter, nil)

        case .include(let includedPIDs, let resolvedActiveApp):
            let includedApps = content.applications.filter { includedPIDs.contains($0.processID) }
            let filter = SCContentFilter(
                display: display,
                including: includedApps,
                exceptingWindows: []
            )
            filter.includeMenuBar = false
            return (filter, resolvedActiveApp)
        }
    }
}
