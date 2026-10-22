import AppKit
import Defaults
import SwiftUI
import XCTest
@testable import UI

final class ThemeTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        AppSettings.resetThemeToDefaults()
    }

    func testColorHexParsingAndNormalization() {
        XCTAssertEqual(ColorHex.normalized("#00e5cc"), "#00E5CC")
        XCTAssertEqual(ColorHex.normalized("ff6b2c"), "#FF6B2C")
        XCTAssertEqual(ColorHex.normalized("invalid", defaultHex: "#123456"), "#123456")

        let rgba = ColorHex.parseRGBA("#38BDF8")
        XCTAssertNotNil(rgba)
        if let rgba {
            XCTAssertEqual(rgba.r, 0x38 / 255.0, accuracy: 0.005)
            XCTAssertEqual(rgba.g, 0xBD / 255.0, accuracy: 0.005)
            XCTAssertEqual(rgba.b, 0xF8 / 255.0, accuracy: 0.005)
            XCTAssertEqual(rgba.a, 1.0, accuracy: 0.005)
        }

        let nsColor = ColorHex.nsColor(from: "#F43F5E")
        XCTAssertEqual(ColorHex.hexString(from: nsColor), "#F43F5E")
    }

    @MainActor
    func testThemeResolutionAndResetToDefaults() {
        AppSettings.resetThemeToDefaults()
        XCTAssertEqual(AppTheme.colorScheme, .system)
        XCTAssertEqual(AppTheme.atmosphere, .native)
        XCTAssertEqual(AppTheme.accentMode, .atmosphere)
        XCTAssertEqual(AppTheme.surfaceStyle, .glass)
        XCTAssertFalse(AppTheme.hasDualToneAccent)

        Defaults[.themeAtmosphere] = .pitchBlack
        Defaults[.themeColorScheme] = .dark
        Defaults[.themeSurfaceStyle] = .matte
        Defaults[.themeUseDualToneAccent] = true

        XCTAssertEqual(AppTheme.atmosphere, .pitchBlack)
        XCTAssertEqual(AppTheme.colorScheme.swiftUIColorScheme, .dark)
        XCTAssertEqual(AppTheme.colorScheme.nsAppearance?.name, .darkAqua)
        XCTAssertTrue(AppTheme.hasDualToneAccent)

        Defaults[.themeAccentMode] = .custom
        Defaults[.themePrimaryAccentHex] = "#FF6B2C"
        Defaults[.themeSecondaryAccentHex] = "#FFB800"
        XCTAssertTrue(AppTheme.hasDualToneAccent)

        Defaults[.themeSecondaryAccentHex] = "#FF6B2C"
        XCTAssertFalse(AppTheme.hasDualToneAccent)

        Defaults[.themeAccentMode] = .system
        XCTAssertFalse(AppTheme.hasDualToneAccent)

        AppSettings.resetThemeToDefaults()
        XCTAssertEqual(Defaults[.themeAtmosphere], .native)
        XCTAssertEqual(Defaults[.themeColorScheme], .system)
        XCTAssertEqual(Defaults[.themeSurfaceStyle], .glass)
    }

    @MainActor
    func testAppearancePageRoutingInMainWindowState() {
        let suiteName = "ThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = MainWindowState(defaults: defaults)
        state.presentEditor = nil
        state.select(.appearance)

        XCTAssertEqual(state.page, .appearance)
        XCTAssertEqual(state.settingsTab, .appearance)
        XCTAssertTrue(state.isSettingsPage)
        XCTAssertTrue(state.hasVisitedSettings)
        XCTAssertEqual(MainWindowPage.appearance.title, "Appearance")
    }

    func testCaptureProfileThemeSnapshotBackwardCompatibilityAndApplication() throws {
        let previousProfilesJSON = Defaults[.captureProfilesJSON]
        defer {
            Defaults[.captureProfilesJSON] = previousProfilesJSON
            AppSettings.resetThemeToDefaults()
        }

        // 1. Legacy JSON without `themeSnapshot` decodes cleanly with nil snapshot
        let legacyJSON = """
        [
          {
            "bitrateMbps": 25,
            "captureDisplayID": "",
            "captureDisplayID2": "",
            "captureMicrophone": false,
            "captureModeRawValue": "single",
            "captureResolutionRawValue": "native",
            "captureSystemAudio": true,
            "createdAt": 1000,
            "customCaptureHeight": 1080,
            "customCaptureWidth": 1920,
            "dualCaptureSaveModeRawValue": "side_by_side",
            "excludeOwnAppAudio": true,
            "frameRate": 60,
            "id": "11111111-2222-3333-4444-555555555555",
            "longBufferDurationMinutes": 5,
            "longBufferEnabled": false,
            "memoryCapMB": 1536,
            "microphoneID": "",
            "microphoneVolume": 1,
            "name": "Legacy Profile",
            "perAppAudioBundleID": "",
            "perAppAudioEnabled": false,
            "qualityPresetRawValue": "quality",
            "queueDepth": 5,
            "systemAudioVolume": 1,
            "updatedAt": 1000,
            "videoCodecRawValue": "hevc"
          }
        ]
        """
        let decodedLegacy = try JSONDecoder().decode([CaptureProfile].self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decodedLegacy.count, 1)
        XCTAssertNil(decodedLegacy[0].themeSnapshot)

        // 2. Profile with a linked theme applies and checks active state accurately
        Defaults[.themeAtmosphere] = .arenaBoost
        Defaults[.themeColorScheme] = .dark
        Defaults[.themeSurfaceStyle] = .matte
        Defaults[.themeAccentMode] = .custom
        Defaults[.themePrimaryAccentHex] = "#F43F5E"
        Defaults[.themeSecondaryAccentHex] = "#A855F7"
        Defaults[.themeUseDualToneAccent] = true

        var themedProfile = decodedLegacy[0]
        themedProfile.themeSnapshot = AppSettings.currentThemeSnapshot()
        XCTAssertTrue(themedProfile.summary.contains("Arena Boost theme"))

        let encoded = try JSONEncoder().encode([themedProfile])
        Defaults[.captureProfilesJSON] = String(decoding: encoded, as: UTF8.self)

        // Reset theme to defaults and verify profile is no longer considered active until applied
        AppSettings.resetThemeToDefaults()
        XCTAssertFalse(AppSettings.isCaptureProfileActive(themedProfile))

        // Apply profile and confirm theme is restored
        XCTAssertTrue(AppSettings.applyCaptureProfile(id: themedProfile.id.uuidString))
        XCTAssertEqual(Defaults[.themeAtmosphere], .arenaBoost)
        XCTAssertEqual(Defaults[.themeColorScheme], .dark)
        XCTAssertEqual(Defaults[.themeSurfaceStyle], .matte)
        XCTAssertEqual(Defaults[.themeAccentMode], .custom)
        XCTAssertEqual(Defaults[.themePrimaryAccentHex], "#F43F5E")
        XCTAssertEqual(Defaults[.themeSecondaryAccentHex], "#A855F7")
    }
}
