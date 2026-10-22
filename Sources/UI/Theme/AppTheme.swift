import AppKit
import Combine
import Defaults
import SwiftUI

public enum AppTheme {
    public static var colorScheme: ThemeColorScheme {
        Defaults[.themeColorScheme]
    }

    public static var atmosphere: ThemeAtmosphere {
        Defaults[.themeAtmosphere]
    }

    public static var accentMode: ThemeAccentMode {
        Defaults[.themeAccentMode]
    }

    public static var surfaceStyle: ThemeSurfaceStyle {
        Defaults[.themeSurfaceStyle]
    }

    public static var useDualToneAccent: Bool {
        Defaults[.themeUseDualToneAccent]
    }

    public static var hasDualToneAccent: Bool {
        guard useDualToneAccent else { return false }
        switch accentMode {
        case .system:
            return false
        case .atmosphere:
            return atmosphere != .native
        case .custom:
            return ColorHex.normalized(Defaults[.themePrimaryAccentHex])
                != ColorHex.normalized(Defaults[.themeSecondaryAccentHex], defaultHex: "#00A3FF")
        }
    }

    // Resolve the active accent colour dynamically.
    public static var accent: Color {
        resolveAccent(
            atmosphere: atmosphere,
            accentMode: accentMode,
            customPrimaryHex: Defaults[.themePrimaryAccentHex]
        )
    }

    public static var accentSecondary: Color {
        resolveSecondaryAccent(
            atmosphere: atmosphere,
            accentMode: accentMode,
            useDualTone: useDualToneAccent,
            customPrimaryHex: Defaults[.themePrimaryAccentHex],
            customSecondaryHex: Defaults[.themeSecondaryAccentHex]
        )
    }

    public static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static var horizontalAccentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    public static var backgroundPrimary: Color {
        resolveBackgroundPrimary(for: atmosphere)
    }

    public static var backgroundSecondary: Color {
        resolveBackgroundSecondary(for: atmosphere, surfaceStyle: surfaceStyle)
    }

    public static var cardBorderColor: Color {
        switch surfaceStyle {
        case .glass:
            return atmosphere == .native
                ? Color(nsColor: .separatorColor).opacity(0.5)
                : accent.opacity(0.14)
        case .tintedGlass:
            return accent.opacity(0.24)
        case .matte:
            return Color(nsColor: dynamicNSColor(
                dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09),
                light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.09)
            ))
        }
    }

    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary

    public static let success = Color.green
    public static let danger = Color.red

    public static let cornerRadiusSmall: CGFloat = 8
    public static let cornerRadiusMedium: CGFloat = 12
    public static let cornerRadiusLarge: CGFloat = 18

    // MARK: - Resolution Helpers

    public static func resolveAccent(
        atmosphere: ThemeAtmosphere,
        accentMode: ThemeAccentMode,
        customPrimaryHex: String
    ) -> Color {
        switch accentMode {
        case .system:
            return Color(nsColor: .controlAccentColor)
        case .atmosphere:
            guard atmosphere != .native else {
                return Color(nsColor: .controlAccentColor)
            }
            return ColorHex.color(from: atmosphere.defaultPrimaryAccentHex)
        case .custom:
            return ColorHex.color(from: customPrimaryHex)
        }
    }

    public static func resolveSecondaryAccent(
        atmosphere: ThemeAtmosphere,
        accentMode: ThemeAccentMode,
        useDualTone: Bool,
        customPrimaryHex: String,
        customSecondaryHex: String
    ) -> Color {
        guard useDualTone else {
            return resolveAccent(atmosphere: atmosphere, accentMode: accentMode, customPrimaryHex: customPrimaryHex)
        }
        switch accentMode {
        case .system:
            return Color(nsColor: .controlAccentColor)
        case .atmosphere:
            guard atmosphere != .native else {
                return Color(nsColor: .controlAccentColor)
            }
            return ColorHex.color(from: atmosphere.defaultSecondaryAccentHex)
        case .custom:
            return ColorHex.color(from: customSecondaryHex)
        }
    }

    public static func resolveBackgroundPrimary(for atmosphere: ThemeAtmosphere) -> Color {
        guard atmosphere != .native else {
            return Color(nsColor: .windowBackgroundColor)
        }
        let dark = ColorHex.nsColor(from: atmosphere.darkCanvasHex, fallback: .windowBackgroundColor)
        let light = ColorHex.nsColor(from: atmosphere.lightCanvasHex, fallback: .windowBackgroundColor)
        return Color(nsColor: dynamicNSColor(dark: dark, light: light))
    }

    public static func resolveBackgroundSecondary(
        for atmosphere: ThemeAtmosphere,
        surfaceStyle: ThemeSurfaceStyle
    ) -> Color {
        guard atmosphere != .native else {
            let base = Color(nsColor: .secondarySystemFill)
            return surfaceStyle == .matte ? base.opacity(0.85) : base.opacity(0.5)
        }
        let dark = ColorHex.nsColor(from: atmosphere.darkCardHex, fallback: .controlBackgroundColor)
        let light = ColorHex.nsColor(from: atmosphere.lightCardHex, fallback: .controlBackgroundColor)
        let resolved = Color(nsColor: dynamicNSColor(dark: dark, light: light))
        switch surfaceStyle {
        case .glass:
            return resolved.opacity(0.72)
        case .tintedGlass:
            return resolved.opacity(0.86)
        case .matte:
            return resolved
        }
    }

    internal static func dynamicNSColor(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            let isDark = (match == .darkAqua || match == .vibrantDark)
            return isDark ? dark : light
        }
    }
}

/// Coordinates reactive theme updates across SwiftUI views and synchronizes
/// `NSWindow.appearance` for open application windows.
@MainActor
public final class ThemeController: ObservableObject {
    public static let shared = ThemeController()

    @Published public private(set) var revision: UInt64 = 0
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var observations: [Defaults.Observation] = []

    private init() {
        observations = [
            Defaults.observe(.themeColorScheme, options: []) { [weak self] _ in
                Task { @MainActor in self?.handleThemeChanged() }
            },
            Defaults.observe(.themeAtmosphere, options: []) { [weak self] _ in
                Task { @MainActor in self?.handleThemeChanged() }
            },
            Defaults.observe(.themeAccentMode, options: []) { [weak self] _ in
                Task { @MainActor in self?.handleThemeChanged() }
            },
            Defaults.observe(.themePrimaryAccentHex, options: []) { [weak self] _ in
                Task { @MainActor in self?.handleThemeChanged() }
            },
            Defaults.observe(.themeSecondaryAccentHex, options: []) { [weak self] _ in
                Task { @MainActor in self?.handleThemeChanged() }
            },
            Defaults.observe(.themeUseDualToneAccent, options: []) { [weak self] _ in
                Task { @MainActor in self?.handleThemeChanged() }
            },
            Defaults.observe(.themeSurfaceStyle, options: []) { [weak self] _ in
                Task { @MainActor in self?.handleThemeChanged() }
            }
        ]
    }

    public func registerWindow(_ window: NSWindow) {
        if !windows.contains(window) {
            windows.add(window)
        }
        applyAppearance(to: window)
    }

    public func refresh() {
        handleThemeChanged()
    }

    private func handleThemeChanged() {
        revision &+= 1
        for window in windows.allObjects {
            applyAppearance(to: window)
        }
    }

    private func applyAppearance(to window: NSWindow) {
        let targetAppearance = AppTheme.colorScheme.nsAppearance
        if window.appearance != targetAppearance {
            window.appearance = targetAppearance
        }
    }
}

/// Native styles let macOS render glass using the user's appearance and
/// accessibility preferences. When dual-tone accents or custom surfaces are
/// active, prominent buttons pick up the theme's gradient.
public struct AccentButtonStyle: PrimitiveButtonStyle {
    public init() {}

    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
        if AppTheme.hasDualToneAccent {
            DualToneButton(configuration: configuration)
        } else if #available(macOS 26, *), AppTheme.surfaceStyle != .matte {
            Button(configuration)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .buttonBorderShape(.roundedRectangle(radius: AppTheme.cornerRadiusSmall))
                .buttonStyle(.glassProminent)
                .tint(AppTheme.accent)
        } else {
            Button(configuration)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .buttonBorderShape(.roundedRectangle(radius: AppTheme.cornerRadiusSmall))
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
        }
    }

    private struct DualToneButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isPressed = false

        var body: some View {
            Button(action: configuration.trigger) {
                configuration.label
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        AppTheme.horizontalAccentGradient,
                        in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous)
                    )
                    .opacity(isEnabled ? (isPressed ? 0.8 : 1.0) : 0.45)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
        }
    }
}

struct AppButtonStyle: PrimitiveButtonStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, *), AppTheme.surfaceStyle != .matte {
            Button(configuration).buttonStyle(.glass)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

// MARK: - Floating glass & themed surfaces
//
// There is no public API for reading the user's Liquid Glass preference
// (Clear/Tinted, or the macOS 27 intensity control). System-drawn glass
// follows it automatically, along with Reduce Transparency and Increase
// Contrast, so custom surfaces use `glassEffect` in Liquid Glass mode and
// layer atmosphere tints or opaque studio surfaces when requested.

/// Groups nearby glass shapes so macOS 26 can blend and morph them together.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *), AppTheme.surfaceStyle != .matte {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// A floating Liquid Glass panel, tinted glass panel, or solid matte studio card.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = AppTheme.cornerRadiusLarge) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch AppTheme.surfaceStyle {
        case .matte:
            self.background(AppTheme.backgroundSecondary, in: shape)
                .overlay(shape.strokeBorder(AppTheme.cardBorderColor, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        case .tintedGlass:
            if #available(macOS 26, *) {
                self.background(
                    LinearGradient(
                        colors: [
                            AppTheme.backgroundSecondary.opacity(0.75),
                            AppTheme.accent.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: shape
                )
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(AppTheme.cardBorderColor, lineWidth: 0.75))
            } else {
                self.background(.regularMaterial, in: shape)
                    .background(AppTheme.backgroundSecondary.opacity(0.75), in: shape)
                    .overlay(shape.strokeBorder(AppTheme.cardBorderColor, lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
            }
        case .glass:
            if #available(macOS 26, *) {
                if AppTheme.atmosphere == .native {
                    self.glassEffect(.regular, in: shape)
                } else {
                    self.background(AppTheme.backgroundSecondary.opacity(0.35), in: shape)
                        .glassEffect(.regular, in: shape)
                        .overlay(shape.strokeBorder(AppTheme.cardBorderColor, lineWidth: 0.5))
                }
            } else {
                self.background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            }
        }
    }

    /// Compact status capsule used for export progress and paused edits.
    func floatingPill() -> some View {
        self.font(.system(size: 12, design: .rounded))
            .controlSize(.small)
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .glassPanel(cornerRadius: 22)
    }

    /// Pins content to the bottom edge. On macOS 26 content scrolls beneath it
    /// with the system scroll edge effect; earlier systems inset the content.
    @ViewBuilder
    func floatingBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            self.safeAreaBar(edge: .bottom, spacing: 0) { bar() }
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) { bar() }
        }
    }

    /// Subscribes a root window view to `ThemeController`, synchronizes its
    /// `NSWindow.appearance`, and applies the active accent tint and color scheme.
    public func themedWindowRoot() -> some View {
        modifier(ThemedWindowRootModifier())
    }
}

private struct ThemedWindowRootModifier: ViewModifier {
    @ObservedObject private var themeController = ThemeController.shared

    func body(content: Content) -> some View {
        let _ = themeController.revision
        content
            .tint(AppTheme.accent)
            .preferredColorScheme(AppTheme.colorScheme.swiftUIColorScheme)
            .background(ThemeWindowRegistrar())
    }
}

private struct ThemeWindowRegistrar: NSViewRepresentable {
    func makeNSView(context: Context) -> RegistrarView {
        RegistrarView()
    }

    func updateNSView(_ nsView: RegistrarView, context: Context) {
        if let window = nsView.window {
            ThemeController.shared.registerWindow(window)
        }
    }

    final class RegistrarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                MainActor.assumeIsolated {
                    ThemeController.shared.registerWindow(window)
                }
            }
        }
    }
}
