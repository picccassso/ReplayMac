import AppKit
import CompanionServer
import XCTest
@testable import UI

@MainActor
final class CompanionThemeBuilderTests: XCTestCase {
    private let systemBlue = NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)

    private func build(
        atmosphere: ThemeAtmosphere = .native,
        accentMode: ThemeAccentMode = .atmosphere,
        surfaceStyle: ThemeSurfaceStyle = .glass,
        useDualTone: Bool = true,
        primary: String = "#00E5CC",
        secondary: String = "#00A3FF"
    ) -> CompanionTheme {
        CompanionThemeBuilder.build(
            colorScheme: .system,
            atmosphere: atmosphere,
            accentMode: accentMode,
            surfaceStyle: surfaceStyle,
            useDualTone: useDualTone,
            customPrimaryHex: primary,
            customSecondaryHex: secondary,
            systemAccent: systemBlue
        )
    }

    func testAtmosphereModeSendsTheAtmosphereColours() {
        let theme = build(atmosphere: .deepOcean, surfaceStyle: .tintedGlass)
        XCTAssertEqual(theme.atmosphere, "deep_ocean")
        XCTAssertEqual(theme.atmosphereName, "Deep Ocean")
        XCTAssertEqual(theme.surfaceStyle, "tinted_glass")
        XCTAssertEqual(theme.dark.canvas, "#0A101D")
        XCTAssertEqual(theme.dark.card, "#121C30")
        XCTAssertEqual(theme.dark.accent, "#38BDF8")
        XCTAssertEqual(theme.dark.accentSecondary, "#6366F1")
        XCTAssertEqual(theme.light.canvas, "#EEF4FA")
        XCTAssertTrue(theme.dualTone)
    }

    func testNativeAndSystemModesSendTheResolvedSystemAccent() {
        let native = build(atmosphere: .native)
        XCTAssertEqual(native.dark.accent, "#0A84FF")
        XCTAssertEqual(native.dark.accentSecondary, "#0A84FF")
        XCTAssertFalse(native.dualTone)

        let system = build(atmosphere: .carbonStudio, accentMode: .system)
        XCTAssertEqual(system.dark.accent, "#0A84FF")
        XCTAssertEqual(system.dark.canvas, "#131315")
        XCTAssertFalse(system.dualTone)
    }

    func testCustomAccentsAreNormalisedAndDualToneFollowsTheToggle() {
        let custom = build(accentMode: .custom, primary: "ff6b2c", secondary: "#ffb800")
        XCTAssertEqual(custom.dark.accent, "#FF6B2C")
        XCTAssertEqual(custom.dark.accentSecondary, "#FFB800")
        XCTAssertTrue(custom.dualTone)

        let singleTone = build(accentMode: .custom, useDualTone: false, primary: "#FF6B2C", secondary: "#FFB800")
        XCTAssertEqual(singleTone.dark.accentSecondary, "#FF6B2C")
        XCTAssertFalse(singleTone.dualTone)
    }
}

