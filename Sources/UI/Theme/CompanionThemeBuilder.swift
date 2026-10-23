import AppKit
import CompanionServer
import Defaults

/// Describes the active Appearance settings for the companion app, with every
/// colour resolved to hex so phones need no atmosphere table of their own.
public enum CompanionThemeBuilder {
    @MainActor
    public static func current() -> CompanionTheme {
        build(
            colorScheme: Defaults[.themeColorScheme],
            atmosphere: Defaults[.themeAtmosphere],
            accentMode: Defaults[.themeAccentMode],
            surfaceStyle: Defaults[.themeSurfaceStyle],
            useDualTone: Defaults[.themeUseDualToneAccent],
            customPrimaryHex: Defaults[.themePrimaryAccentHex],
            customSecondaryHex: Defaults[.themeSecondaryAccentHex],
            systemAccent: NSColor.controlAccentColor
        )
    }

    @MainActor
    public static func build(
        colorScheme: ThemeColorScheme,
        atmosphere: ThemeAtmosphere,
        accentMode: ThemeAccentMode,
        surfaceStyle: ThemeSurfaceStyle,
        useDualTone: Bool,
        customPrimaryHex: String,
        customSecondaryHex: String,
        systemAccent: NSColor
    ) -> CompanionTheme {
        let darkSystemAccent = hex(of: systemAccent, in: .darkAqua)
        let lightSystemAccent = hex(of: systemAccent, in: .aqua)

        func accents(systemAccentHex: String) -> (primary: String, secondary: String) {
            let primary: String
            let secondary: String
            switch accentMode {
            case .system:
                primary = systemAccentHex
                secondary = systemAccentHex
            case .atmosphere:
                primary = atmosphere == .native ? systemAccentHex : atmosphere.defaultPrimaryAccentHex
                secondary = atmosphere == .native ? systemAccentHex : atmosphere.defaultSecondaryAccentHex
            case .custom:
                primary = ColorHex.normalized(customPrimaryHex)
                secondary = ColorHex.normalized(customSecondaryHex, defaultHex: "#00A3FF")
            }
            return (primary, useDualTone ? secondary : primary)
        }

        let darkAccents = accents(systemAccentHex: darkSystemAccent)
        let lightAccents = accents(systemAccentHex: lightSystemAccent)

        return CompanionTheme(
            atmosphere: atmosphere.rawValue,
            atmosphereName: atmosphere.title,
            colorScheme: colorScheme.rawValue,
            accentMode: accentMode.rawValue,
            surfaceStyle: surfaceStyle.rawValue,
            dualTone: darkAccents.primary != darkAccents.secondary,
            dark: CompanionThemePalette(
                canvas: atmosphere.darkCanvasHex,
                card: atmosphere.darkCardHex,
                accent: darkAccents.primary,
                accentSecondary: darkAccents.secondary
            ),
            light: CompanionThemePalette(
                canvas: atmosphere.lightCanvasHex,
                card: atmosphere.lightCardHex,
                accent: lightAccents.primary,
                accentSecondary: lightAccents.secondary
            )
        )
    }

    /// Resolves a dynamic colour such as the system accent as it draws under `appearance`.
    @MainActor
    static func hex(of color: NSColor, in appearance: NSAppearance.Name) -> String {
        var resolved = ColorHex.hexString(from: color) ?? "#0A84FF"
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            if let hex = ColorHex.hexString(from: color) {
                resolved = hex
            }
        }
        return resolved
    }
}
