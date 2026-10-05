import SwiftUI

public enum AppTheme {
    // Resolve the system colour dynamically, including changes while open.
    public static var accent: Color { Color(nsColor: .controlAccentColor) }
    public static var accentSecondary: Color { accent }
    public static let brandAccent = Color.teal

    public static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
    public static let backgroundSecondary = Color(nsColor: .secondarySystemFill).opacity(0.5)

    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary

    public static let success = Color.green
    public static let danger = Color.red

    public static let cornerRadiusSmall: CGFloat = 8
    public static let cornerRadiusMedium: CGFloat = 12
    public static let cornerRadiusLarge: CGFloat = 18
}

/// Native styles let macOS render glass using the user's appearance and
/// accessibility preferences. Earlier systems keep their standard controls.
public struct AccentButtonStyle: PrimitiveButtonStyle {
    public init() {}

    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, *) {
            Button(configuration)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .buttonBorderShape(.roundedRectangle(radius: AppTheme.cornerRadiusSmall))
                .buttonStyle(.glassProminent)
        } else {
            Button(configuration)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .buttonBorderShape(.roundedRectangle(radius: AppTheme.cornerRadiusSmall))
                .buttonStyle(.borderedProminent)
        }
    }
}

struct AppButtonStyle: PrimitiveButtonStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, *) {
            Button(configuration).buttonStyle(.glass)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

// MARK: - Floating glass surfaces
//
// There is no public API for reading the user's Liquid Glass preference
// (Clear/Tinted, or the macOS 27 intensity control). System-drawn glass
// follows it automatically, along with Reduce Transparency and Increase
// Contrast, so custom surfaces use `glassEffect` rather than painting their
// own translucency.

/// Groups nearby glass shapes so macOS 26 can blend and morph them together.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// A floating Liquid Glass panel, or a material card before macOS 26.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = AppTheme.cornerRadiusLarge) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
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
}
