import CoreGraphics
import XCTest
@testable import Capture

final class VideoContentFilterTests: XCTestCase {
    private let display1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let display2 = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    private let ownBundleID = "com.replaycap.ReplayMac"

    // MARK: - Full Display

    func testFullDisplayResolvesUnfilteredAndDoesNotSplitAudio() {
        let config = VideoContentFilterConfig(mode: .fullDisplay, ownBundleID: ownBundleID)
        XCTAssertFalse(config.excludesOtherApplications)

        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: [
                CapturableAppSnapshot(pid: 10, bundleIdentifier: "com.apple.notificationcenterui", activationKind: .accessory),
                CapturableAppSnapshot(pid: 20, bundleIdentifier: "com.example.game", activationKind: .regular)
            ],
            windows: [],
            config: config
        )
        XCTAssertEqual(plan.kind, .fullDisplay)
    }

    // MARK: - Hide Overlays

    func testHideOverlaysExcludesSystemOverlaysAndAccessoryUtilitiesEvenWithoutWindows() {
        let apps = [
            CapturableAppSnapshot(pid: 1, bundleIdentifier: "com.apple.notificationcenterui", activationKind: .accessory),
            CapturableAppSnapshot(pid: 2, bundleIdentifier: "com.apple.OSDUIHelper", activationKind: .prohibited),
            CapturableAppSnapshot(pid: 3, bundleIdentifier: "com.apple.controlcenter", activationKind: .accessory),
            CapturableAppSnapshot(pid: 4, bundleIdentifier: "com.apple.Spotlight", activationKind: .accessory),
            CapturableAppSnapshot(pid: 5, bundleIdentifier: "com.apple.Siri", activationKind: .accessory),
            // Third-party notch widget and mic-mute HUD (currently no windows on screen — transient HUD!)
            CapturableAppSnapshot(pid: 10, bundleIdentifier: "com.thirdparty.NotchWidget", activationKind: .accessory),
            CapturableAppSnapshot(pid: 11, bundleIdentifier: "com.thirdparty.MicMuteHUD", activationKind: .accessory),
            // Protected shell processes that must remain visible
            CapturableAppSnapshot(pid: 20, bundleIdentifier: "com.apple.dock", activationKind: .accessory),
            CapturableAppSnapshot(pid: 21, bundleIdentifier: "com.apple.finder", activationKind: .regular),
            CapturableAppSnapshot(pid: 22, bundleIdentifier: "com.apple.WindowManager", activationKind: .accessory),
            CapturableAppSnapshot(pid: 23, bundleIdentifier: "com.apple.SystemUIServer", activationKind: .accessory),
            // Regular user app
            CapturableAppSnapshot(pid: 30, bundleIdentifier: "com.valvesoftware.Game", activationKind: .regular),
            // ReplayMac itself
            CapturableAppSnapshot(pid: 40, bundleIdentifier: ownBundleID, activationKind: .regular)
        ]

        let windows = [
            // ReplayMac's normal main window (should stay visible)
            CapturableWindowSnapshot(
                windowID: 400,
                owningPID: 40,
                owningBundleIdentifier: ownBundleID,
                frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                windowLayer: 0,
                isOnScreen: true
            ),
            // ReplayMac's floating saved-clip thumbnail toast (should be hidden)
            CapturableWindowSnapshot(
                windowID: 401,
                owningPID: 40,
                owningBundleIdentifier: ownBundleID,
                frame: CGRect(x: 1600, y: 860, width: 280, height: 180),
                windowLayer: 3,
                isOnScreen: true
            )
        ]

        let config = VideoContentFilterConfig(
            mode: .hideOverlays,
            hideMenuBar: true,
            hideFloatingUtilityApps: true,
            hiddenBundleIDs: [],
            ownBundleID: ownBundleID
        )
        XCTAssertTrue(config.excludesOtherApplications)

        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: apps,
            windows: windows,
            config: config
        )

        XCTAssertEqual(
            plan.kind,
            .exclude(
                excludedAppPIDs: [1, 2, 3, 4, 5, 10, 11],
                excludedWindowIDs: [401],
                includeMenuBar: false
            )
        )
    }

    func testHideOverlaysKeepsAccessoryProcessOwningLargeNormalWindow() {
        let apps = [
            CapturableAppSnapshot(pid: 50, bundleIdentifier: "org.winehq.WineHelper", activationKind: .accessory),
            CapturableAppSnapshot(pid: 51, bundleIdentifier: "com.thirdparty.NotchWidget", activationKind: .accessory)
        ]
        let windows = [
            // Game rendered via accessory helper at normal window layer
            CapturableWindowSnapshot(
                windowID: 500,
                owningPID: 50,
                owningBundleIdentifier: "org.winehq.WineHelper",
                frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
                windowLayer: 0,
                isOnScreen: true
            ),
            // Notch widget at elevated status-bar layer
            CapturableWindowSnapshot(
                windowID: 501,
                owningPID: 51,
                owningBundleIdentifier: "com.thirdparty.NotchWidget",
                frame: CGRect(x: 500, y: 0, width: 880, height: 310),
                windowLayer: 25,
                isOnScreen: true
            )
        ]

        let config = VideoContentFilterConfig(
            mode: .hideOverlays,
            hideMenuBar: false,
            hideFloatingUtilityApps: true,
            ownBundleID: ownBundleID
        )

        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: apps,
            windows: windows,
            config: config
        )

        XCTAssertEqual(
            plan.kind,
            .exclude(
                excludedAppPIDs: [51],
                excludedWindowIDs: [],
                includeMenuBar: true
            )
        )
    }

    func testHideOverlaysRespectsHideFloatingUtilityAppsToggleAndCustomHiddenList() {
        let apps = [
            CapturableAppSnapshot(pid: 1, bundleIdentifier: "com.apple.notificationcenterui", activationKind: .accessory),
            CapturableAppSnapshot(pid: 10, bundleIdentifier: "com.thirdparty.NotchWidget", activationKind: .accessory),
            CapturableAppSnapshot(pid: 30, bundleIdentifier: "com.hnc.Discord", activationKind: .regular),
            CapturableAppSnapshot(pid: 31, bundleIdentifier: "com.hnc.Discord.helper", activationKind: .prohibited)
        ]

        let config = VideoContentFilterConfig(
            mode: .hideOverlays,
            hideMenuBar: false,
            hideFloatingUtilityApps: false,
            hiddenBundleIDs: ["COM.HNC.DISCORD"],
            ownBundleID: ownBundleID
        )

        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: apps,
            windows: [],
            config: config
        )

        XCTAssertEqual(
            plan.kind,
            .exclude(
                excludedAppPIDs: [1, 30, 31],
                excludedWindowIDs: [],
                includeMenuBar: true
            )
        )
    }

    // MARK: - Active App Only

    func testActiveAppSelectsFrontmostRegularAppAndChildHelpers() {
        let apps = [
            CapturableAppSnapshot(pid: 100, bundleIdentifier: "com.google.Chrome", activationKind: .regular),
            CapturableAppSnapshot(pid: 101, bundleIdentifier: "com.google.Chrome.helper", activationKind: .prohibited),
            CapturableAppSnapshot(pid: 200, bundleIdentifier: "com.spotify.client", activationKind: .regular)
        ]
        let windows = [
            CapturableWindowSnapshot(
                windowID: 1000,
                owningPID: 100,
                owningBundleIdentifier: "com.google.Chrome",
                frame: CGRect(x: 50, y: 50, width: 1200, height: 800),
                windowLayer: 0,
                isOnScreen: true
            ),
            CapturableWindowSnapshot(
                windowID: 2000,
                owningPID: 200,
                owningBundleIdentifier: "com.spotify.client",
                frame: CGRect(x: 100, y: 100, width: 1000, height: 700),
                windowLayer: 0,
                isOnScreen: true
            )
        ]

        let config = VideoContentFilterConfig(
            mode: .activeApp,
            activeAppPID: 100,
            activeAppBundleID: "com.google.Chrome",
            ownBundleID: ownBundleID
        )

        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: apps,
            windows: windows,
            config: config
        )

        XCTAssertEqual(
            plan.kind,
            .include(
                includedAppPIDs: [100, 101],
                resolvedActiveApp: VideoAppIdentity(pid: 100, bundleIdentifier: "com.google.Chrome")
            )
        )
    }

    func testActiveAppPreservesLastActiveAppOnDisplay1WhenMonitor2AppActivates() {
        let apps = [
            CapturableAppSnapshot(pid: 100, bundleIdentifier: "com.game.Title", activationKind: .regular),
            CapturableAppSnapshot(pid: 200, bundleIdentifier: "com.tinyspeck.slackmacgap", activationKind: .regular)
        ]
        let windows = [
            // Slack on Monitor 2 (newly activated)
            CapturableWindowSnapshot(
                windowID: 2000,
                owningPID: 200,
                owningBundleIdentifier: "com.tinyspeck.slackmacgap",
                frame: CGRect(x: 2000, y: 100, width: 1400, height: 900),
                windowLayer: 0,
                isOnScreen: true
            ),
            // Game on Monitor 1 (previously active on Monitor 1)
            CapturableWindowSnapshot(
                windowID: 1000,
                owningPID: 100,
                owningBundleIdentifier: "com.game.Title",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                windowLayer: 0,
                isOnScreen: true
            )
        ]

        let gameIdentity = VideoAppIdentity(pid: 100, bundleIdentifier: "com.game.Title")
        let config = VideoContentFilterConfig(
            mode: .activeApp,
            activeAppPID: 200,
            activeAppBundleID: "com.tinyspeck.slackmacgap",
            ownBundleID: ownBundleID
        )

        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: apps,
            windows: windows,
            config: config,
            lastActiveApp: gameIdentity
        )

        XCTAssertEqual(
            plan.kind,
            .include(includedAppPIDs: [100], resolvedActiveApp: gameIdentity)
        )
    }

    func testActiveAppIgnoresOwnAppAndAccessoryAppsAndFallsBackByZOrder() {
        let apps = [
            CapturableAppSnapshot(pid: 40, bundleIdentifier: ownBundleID, activationKind: .regular),
            CapturableAppSnapshot(pid: 50, bundleIdentifier: "com.thirdparty.NotchWidget", activationKind: .accessory),
            CapturableAppSnapshot(pid: 100, bundleIdentifier: "com.apple.Safari", activationKind: .regular),
            CapturableAppSnapshot(pid: 200, bundleIdentifier: "com.apple.Notes", activationKind: .regular)
        ]
        let windows = [
            CapturableWindowSnapshot(
                windowID: 400,
                owningPID: 40,
                owningBundleIdentifier: ownBundleID,
                frame: CGRect(x: 200, y: 200, width: 800, height: 600),
                windowLayer: 0,
                isOnScreen: true
            ),
            CapturableWindowSnapshot(
                windowID: 500,
                owningPID: 50,
                owningBundleIdentifier: "com.thirdparty.NotchWidget",
                frame: CGRect(x: 500, y: 0, width: 880, height: 310),
                windowLayer: 25,
                isOnScreen: true
            ),
            // Safari is frontmost regular non-own app on display1
            CapturableWindowSnapshot(
                windowID: 1000,
                owningPID: 100,
                owningBundleIdentifier: "com.apple.Safari",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                windowLayer: 0,
                isOnScreen: true
            ),
            CapturableWindowSnapshot(
                windowID: 2000,
                owningPID: 200,
                owningBundleIdentifier: "com.apple.Notes",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                windowLayer: 0,
                isOnScreen: true
            )
        ]

        // Active app is ReplayMac itself and no lastActiveApp yet
        let config = VideoContentFilterConfig(
            mode: .activeApp,
            activeAppPID: 40,
            activeAppBundleID: ownBundleID,
            ownBundleID: ownBundleID
        )

        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: apps,
            windows: windows,
            config: config,
            lastActiveApp: nil
        )

        XCTAssertEqual(
            plan.kind,
            .include(
                includedAppPIDs: [100],
                resolvedActiveApp: VideoAppIdentity(pid: 100, bundleIdentifier: "com.apple.Safari")
            )
        )
    }

    func testActiveAppMatchesUnsignedGameByPIDWhenBundleIDIsEmpty() {
        let apps = [
            CapturableAppSnapshot(pid: 777, bundleIdentifier: "", activationKind: .regular)
        ]
        let windows = [
            CapturableWindowSnapshot(
                windowID: 7770,
                owningPID: 777,
                owningBundleIdentifier: "",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                windowLayer: 0,
                isOnScreen: true
            )
        ]

        let config = VideoContentFilterConfig(
            mode: .activeApp,
            activeAppPID: 777,
            activeAppBundleID: nil,
            ownBundleID: ownBundleID
        )

        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: apps,
            windows: windows,
            config: config
        )

        XCTAssertEqual(
            plan.kind,
            .include(
                includedAppPIDs: [777],
                resolvedActiveApp: VideoAppIdentity(pid: 777, bundleIdentifier: "")
            )
        )
    }

    func testActiveAppReturnsPrivacySafeEmptyInclusionOnEmptyDesktop() {
        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: [
                CapturableAppSnapshot(pid: 40, bundleIdentifier: ownBundleID, activationKind: .regular)
            ],
            windows: [],
            config: VideoContentFilterConfig(mode: .activeApp, ownBundleID: ownBundleID)
        )

        XCTAssertEqual(plan.kind, .include(includedAppPIDs: [], resolvedActiveApp: nil))
    }

    // MARK: - Selected App Only

    func testSelectedAppIncludesMatchingBundleAndHelpers() {
        let apps = [
            CapturableAppSnapshot(pid: 10, bundleIdentifier: "com.microsoft.VSCode", activationKind: .regular),
            CapturableAppSnapshot(pid: 11, bundleIdentifier: "com.microsoft.VSCode.helper", activationKind: .prohibited),
            CapturableAppSnapshot(pid: 20, bundleIdentifier: "com.apple.Safari", activationKind: .regular)
        ]

        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: apps,
            windows: [],
            config: VideoContentFilterConfig(
                mode: .selectedApp,
                selectedAppBundleID: "com.microsoft.vscode",
                ownBundleID: ownBundleID
            )
        )

        XCTAssertEqual(plan.kind, .include(includedAppPIDs: [10, 11], resolvedActiveApp: nil))
    }

    func testSelectedAppReturnsEmptyInclusionWhenAppNotRunning() {
        let plan = VideoOverlayClassifier.resolve(
            displayFrame: display1,
            applications: [
                CapturableAppSnapshot(pid: 20, bundleIdentifier: "com.apple.Safari", activationKind: .regular)
            ],
            windows: [],
            config: VideoContentFilterConfig(
                mode: .selectedApp,
                selectedAppBundleID: "com.example.NotRunningGame",
                ownBundleID: ownBundleID
            )
        )

        XCTAssertEqual(plan.kind, .include(includedAppPIDs: [], resolvedActiveApp: nil))
    }
}
