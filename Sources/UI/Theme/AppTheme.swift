import SwiftUI

public enum AppTheme {
    public static let accent = Color.teal
    public static let accentSecondary = Color.cyan

    public static let backgroundPrimary = Color(NSColor.controlBackgroundColor)
    public static let backgroundSecondary = Color(NSColor.secondarySystemFill).opacity(0.5)

    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary

    public static let success = Color.green
    public static let danger = Color.red

    public static let cornerRadiusSmall: CGFloat = 8
    public static let cornerRadiusMedium: CGFloat = 12
    public static let cornerRadiusLarge: CGFloat = 16

    public static let shadowSmall = ShadowStyle(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    public static let shadowMedium = ShadowStyle(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)

    public struct ShadowStyle: Sendable {
        public let color: Color
        public let radius: CGFloat
        public let x: CGFloat
        public let y: CGFloat

        public func apply<V: View>(to view: V) -> some View {
            view.shadow(color: color, radius: radius, x: x, y: y)
        }
    }
}

public struct AccentButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [AppTheme.accent, AppTheme.accentSecondary],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

public struct GlassCardModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 3)
    }
}

public struct PulsingDotModifier: ViewModifier {
    @State private var isPulsing = false

    public init() {}

    public func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { proxy in
                    Circle()
                        .fill(AppTheme.danger)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(isPulsing ? 1.6 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.4)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: isPulsing)
                        .onAppear { isPulsing = true }
                }
            )
    }
}

public extension View {
    func glassCard() -> some View {
        modifier(GlassCardModifier())
    }

    func pulsingDot() -> some View {
        modifier(PulsingDotModifier())
    }
}
