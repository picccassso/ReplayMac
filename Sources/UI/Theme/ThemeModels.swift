import AppKit
import Defaults
import Foundation
import SwiftUI

public enum ThemeColorScheme: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case system
    case dark
    case light

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    public var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .dark: "moon.stars.fill"
        case .light: "sun.max.fill"
        }
    }

    public var swiftUIColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    @MainActor
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}

public enum ThemeAtmosphere: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case native
    case pitchBlack = "pitch_black"
    case carbonStudio = "carbon_studio"
    case deepOcean = "deep_ocean"
    case arenaBoost = "arena_boost"
    case nordicFrost = "nordic_frost"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .native: "Native"
        case .pitchBlack: "Pitch Black"
        case .carbonStudio: "Carbon Studio"
        case .deepOcean: "Deep Ocean"
        case .arenaBoost: "Arena Boost"
        case .nordicFrost: "Nordic Frost"
        }
    }

    public var subtitle: String {
        switch self {
        case .native: "macOS system surfaces"
        case .pitchBlack: "Zero-glow OLED canvas"
        case .carbonStudio: "Warm broadcast console"
        case .deepOcean: "Abyssal midnight slate"
        case .arenaBoost: "High-energy twilight"
        case .nordicFrost: "Crisp arctic slate"
        }
    }

    public var darkCanvasHex: String {
        switch self {
        case .native: "#1E1E1E"
        case .pitchBlack: "#07080A"
        case .carbonStudio: "#131315"
        case .deepOcean: "#0A101D"
        case .arenaBoost: "#110D1C"
        case .nordicFrost: "#171C24"
        }
    }

    public var darkCardHex: String {
        switch self {
        case .native: "#2A2A2C"
        case .pitchBlack: "#111318"
        case .carbonStudio: "#1D1E22"
        case .deepOcean: "#121C30"
        case .arenaBoost: "#1B152C"
        case .nordicFrost: "#222936"
        }
    }

    public var lightCanvasHex: String {
        switch self {
        case .native: "#F5F5F7"
        case .pitchBlack: "#F4F5F7"
        case .carbonStudio: "#F3F2EE"
        case .deepOcean: "#EEF4FA"
        case .arenaBoost: "#F6F2FA"
        case .nordicFrost: "#ECEFF4"
        }
    }

    public var lightCardHex: String {
        switch self {
        case .native: "#FFFFFF"
        case .pitchBlack: "#FFFFFF"
        case .carbonStudio: "#EAE8E1"
        case .deepOcean: "#E1ECF7"
        case .arenaBoost: "#EDE5F6"
        case .nordicFrost: "#E5E9F0"
        }
    }

    public var defaultPrimaryAccentHex: String {
        switch self {
        case .native: "#007AFF"
        case .pitchBlack: "#00E5CC"
        case .carbonStudio: "#FF6B2C"
        case .deepOcean: "#38BDF8"
        case .arenaBoost: "#F43F5E"
        case .nordicFrost: "#88C0D0"
        }
    }

    public var defaultSecondaryAccentHex: String {
        switch self {
        case .native: "#007AFF"
        case .pitchBlack: "#00A3FF"
        case .carbonStudio: "#FFB800"
        case .deepOcean: "#6366F1"
        case .arenaBoost: "#A855F7"
        case .nordicFrost: "#5E81AC"
        }
    }
}

public enum ThemeAccentMode: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case atmosphere
    case system
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .atmosphere: "Atmosphere Default"
        case .system: "macOS System"
        case .custom: "Custom"
        }
    }
}

public enum ThemeSurfaceStyle: String, CaseIterable, Identifiable, Codable, Sendable, Defaults.Serializable {
    case glass
    case tintedGlass = "tinted_glass"
    case matte

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .tintedGlass: "Tinted Glass"
        case .matte: "Solid Matte"
        }
    }

    public var subtitle: String {
        switch self {
        case .glass: "System-drawn translucency that blends with your desktop."
        case .tintedGlass: "Translucent panels subtly infused with your active atmosphere and accent."
        case .matte: "Opaque studio surfaces with crisp borders and zero desktop wallpaper bleed-through."
        }
    }
}

public struct ThemeSwatch: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let primaryHex: String
    public let secondaryHex: String

    public init(id: String, title: String, primaryHex: String, secondaryHex: String) {
        self.id = id
        self.title = title
        self.primaryHex = primaryHex
        self.secondaryHex = secondaryHex
    }

    public static let all: [ThemeSwatch] = [
        ThemeSwatch(id: "teal", title: "Electric Teal", primaryHex: "#00E5CC", secondaryHex: "#00A3FF"),
        ThemeSwatch(id: "blue", title: "Cobalt Pulse", primaryHex: "#38BDF8", secondaryHex: "#3B82F6"),
        ThemeSwatch(id: "indigo", title: "Ultraviolet", primaryHex: "#6366F1", secondaryHex: "#A855F7"),
        ThemeSwatch(id: "arena", title: "Boost Magenta", primaryHex: "#F43F5E", secondaryHex: "#A855F7"),
        ThemeSwatch(id: "crimson", title: "Apex Crimson", primaryHex: "#EF4444", secondaryHex: "#F97316"),
        ThemeSwatch(id: "ember", title: "Studio Ember", primaryHex: "#FF6B2C", secondaryHex: "#FFB800"),
        ThemeSwatch(id: "amber", title: "Solar Gold", primaryHex: "#F59E0B", secondaryHex: "#FACC15"),
        ThemeSwatch(id: "emerald", title: "Pitch Mint", primaryHex: "#10B981", secondaryHex: "#06B6D4"),
        ThemeSwatch(id: "frost", title: "Glacier", primaryHex: "#88C0D0", secondaryHex: "#5E81AC")
    ]
}

public struct ProfileThemeSnapshot: Codable, Equatable, Sendable {
    public var colorSchemeRawValue: String
    public var atmosphereRawValue: String
    public var accentModeRawValue: String
    public var primaryAccentHex: String
    public var secondaryAccentHex: String
    public var useDualToneAccent: Bool
    public var surfaceStyleRawValue: String

    public init(
        colorSchemeRawValue: String,
        atmosphereRawValue: String,
        accentModeRawValue: String,
        primaryAccentHex: String,
        secondaryAccentHex: String,
        useDualToneAccent: Bool,
        surfaceStyleRawValue: String
    ) {
        self.colorSchemeRawValue = colorSchemeRawValue
        self.atmosphereRawValue = atmosphereRawValue
        self.accentModeRawValue = accentModeRawValue
        self.primaryAccentHex = primaryAccentHex
        self.secondaryAccentHex = secondaryAccentHex
        self.useDualToneAccent = useDualToneAccent
        self.surfaceStyleRawValue = surfaceStyleRawValue
    }

    public var summary: String {
        let atmosphere = (ThemeAtmosphere(rawValue: atmosphereRawValue) ?? .native).title
        let scheme = (ThemeColorScheme(rawValue: colorSchemeRawValue) ?? .system).title
        let surface = (ThemeSurfaceStyle(rawValue: surfaceStyleRawValue) ?? .glass).title
        let accent: String
        switch ThemeAccentMode(rawValue: accentModeRawValue) ?? .atmosphere {
        case .atmosphere:
            accent = "Theme accent"
        case .system:
            accent = "System accent"
        case .custom:
            accent = useDualToneAccent
                ? "\(ColorHex.normalized(primaryAccentHex)) → \(ColorHex.normalized(secondaryAccentHex))"
                : ColorHex.normalized(primaryAccentHex)
        }
        return "\(atmosphere) · \(scheme) · \(surface) · \(accent)"
    }
}

public enum ColorHex {
    public static func normalized(_ hex: String, defaultHex: String = "#00E5CC") -> String {
        guard let rgba = parseRGBA(hex) else {
            return defaultHex
        }
        let r = Int((rgba.r * 255).rounded())
        let g = Int((rgba.g * 255).rounded())
        let b = Int((rgba.b * 255).rounded())
        return String(format: "#%02X%02X%02X", min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))
    }

    public static func parseRGBA(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard trimmed.count == 6 || trimmed.count == 8,
              let value = UInt64(trimmed, radix: 16) else {
            return nil
        }
        if trimmed.count == 6 {
            let r = CGFloat((value & 0xFF0000) >> 16) / 255.0
            let g = CGFloat((value & 0x00FF00) >> 8) / 255.0
            let b = CGFloat(value & 0x0000FF) / 255.0
            return (r, g, b, 1.0)
        } else {
            let r = CGFloat((value & 0xFF000000) >> 24) / 255.0
            let g = CGFloat((value & 0x00FF0000) >> 16) / 255.0
            let b = CGFloat((value & 0x0000FF00) >> 8) / 255.0
            let a = CGFloat(value & 0x000000FF) / 255.0
            return (r, g, b, a)
        }
    }

    public static func nsColor(from hex: String, fallback: NSColor = .controlAccentColor) -> NSColor {
        guard let rgba = parseRGBA(hex) else { return fallback }
        return NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    public static func color(from hex: String, fallback: Color = Color(nsColor: .controlAccentColor)) -> Color {
        guard let rgba = parseRGBA(hex) else { return fallback }
        return Color(.sRGB, red: Double(rgba.r), green: Double(rgba.g), blue: Double(rgba.b), opacity: Double(rgba.a))
    }

    public static func hexString(from color: Color) -> String? {
        let nsColor = NSColor(color)
        return hexString(from: nsColor)
    }

    public static func hexString(from nsColor: NSColor) -> String? {
        guard let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let r = Int((min(max(srgb.redComponent, 0), 1) * 255).rounded())
        let g = Int((min(max(srgb.greenComponent, 0), 1) * 255).rounded())
        let b = Int((min(max(srgb.blueComponent, 0), 1) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
