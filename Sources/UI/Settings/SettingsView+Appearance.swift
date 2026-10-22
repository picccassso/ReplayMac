import AppKit
import Defaults
import SwiftUI

extension SettingsView {
    var appearanceTab: some View {
        Form {
            Section {
                ThemeLivePreviewCard()
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            } header: {
                Text("Live Preview")
            }

            Section {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3),
                    spacing: 10
                ) {
                    ForEach(ThemeAtmosphere.allCases) { atmosphere in
                        AtmospherePresetCard(
                            atmosphere: atmosphere,
                            isSelected: themeAtmosphere == atmosphere
                        ) {
                            themeAtmosphere = atmosphere
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Atmosphere")
            } footer: {
                Text("Atmospheres tune window canvases and card surfaces. Pitch Black and Carbon Studio are designed for dark-room gaming on a second display.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Section {
                Picker("Appearance", selection: $themeColorScheme) {
                    ForEach(ThemeColorScheme.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Surface style", selection: $themeSurfaceStyle) {
                    ForEach(ThemeSurfaceStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Mode & Surfaces")
            } footer: {
                Text(themeSurfaceStyle.subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Section {
                Picker("Accent source", selection: $themeAccentMode) {
                    ForEach(ThemeAccentMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Studio presets")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)

                    HStack(spacing: 10) {
                        ForEach(ThemeSwatch.all) { swatch in
                            SwatchButton(
                                swatch: swatch,
                                isSelected: isSwatchSelected(swatch)
                            ) {
                                themeAccentMode = .custom
                                themePrimaryAccentHex = swatch.primaryHex
                                themeSecondaryAccentHex = swatch.secondaryHex
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.vertical, 2)

                if themeAccentMode != .system {
                    Toggle("Dual-tone gradient", isOn: $themeUseDualToneAccent)
                        .help("Blends the primary and secondary accent across prominent action tiles, buttons, and empty-state emblems.")
                }

                if themeAccentMode == .custom {
                    HStack(spacing: 12) {
                        ColorPicker("Primary accent", selection: primaryAccentColorBinding, supportsOpacity: false)
                        Spacer()
                        Text(ColorHex.normalized(themePrimaryAccentHex))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    if themeUseDualToneAccent {
                        HStack(spacing: 12) {
                            ColorPicker("Secondary accent", selection: secondaryAccentColorBinding, supportsOpacity: false)
                            Spacer()
                            Button("Swap", systemImage: "arrow.up.arrow.down") {
                                let primary = themePrimaryAccentHex
                                themePrimaryAccentHex = themeSecondaryAccentHex
                                themeSecondaryAccentHex = primary
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Swap primary and secondary accent colors")

                            Text(ColorHex.normalized(themeSecondaryAccentHex, defaultHex: "#00A3FF"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
            } header: {
                Text("Accent & Gradient")
            } footer: {
                Text("Link different themes to individual Capture Profiles in Settings → Profiles.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Section {
                HStack {
                    Button("Reset Appearance to Default") {
                        AppSettings.resetThemeToDefaults()
                    }
                    .disabled(isDefaultAppearance)

                    Spacer()

                    Button("Open Profiles…") {
                        selectedTab = .profiles
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isDefaultAppearance: Bool {
        themeColorScheme == .system
            && themeAtmosphere == .native
            && themeAccentMode == .atmosphere
            && themeSurfaceStyle == .glass
            && themeUseDualToneAccent == true
    }

    private func isSwatchSelected(_ swatch: ThemeSwatch) -> Bool {
        guard themeAccentMode == .custom else { return false }
        let primaryMatches = ColorHex.normalized(themePrimaryAccentHex) == ColorHex.normalized(swatch.primaryHex)
        if !themeUseDualToneAccent {
            return primaryMatches
        }
        let secondaryMatches = ColorHex.normalized(themeSecondaryAccentHex, defaultHex: "#00A3FF")
            == ColorHex.normalized(swatch.secondaryHex)
        return primaryMatches && secondaryMatches
    }

    private var primaryAccentColorBinding: Binding<Color> {
        Binding(
            get: { ColorHex.color(from: themePrimaryAccentHex) },
            set: { newColor in
                if let hex = ColorHex.hexString(from: newColor) {
                    themePrimaryAccentHex = hex
                }
            }
        )
    }

    private var secondaryAccentColorBinding: Binding<Color> {
        Binding(
            get: { ColorHex.color(from: themeSecondaryAccentHex) },
            set: { newColor in
                if let hex = ColorHex.hexString(from: newColor) {
                    themeSecondaryAccentHex = hex
                }
            }
        )
    }
}

// MARK: - Live Preview Card

private struct ThemeLivePreviewCard: View {
    @ObservedObject private var themeController = ThemeController.shared

    var body: some View {
        let _ = themeController.revision
        VStack(alignment: .leading, spacing: 12) {
            // Miniature status card
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(AppTheme.danger)
                        .frame(width: 9, height: 9)
                        .overlay {
                            Circle()
                                .stroke(AppTheme.danger.opacity(0.45), lineWidth: 3)
                                .scaleEffect(1.5)
                        }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replay buffer running")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("04:12 · Built-in Retina Display")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    Spacer()

                    HStack(spacing: 5) {
                        Circle()
                            .fill(AppTheme.success)
                            .frame(width: 6, height: 6)
                        Text("Ready")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.success)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.success.opacity(0.14), in: Capsule())
                }

                // Buffer fill bar showing accent / dual-tone gradient
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(AppTheme.horizontalAccentGradient)
                            .frame(width: proxy.size.width * 0.78)
                    }
                }
                .frame(height: 6)
            }
            .padding(14)
            .glassPanel(cornerRadius: AppTheme.cornerRadiusMedium)

            // Sample tiles & clip badge row
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Save Last 30s")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(
                    AppTheme.horizontalAccentGradient,
                    in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                )

                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text("Microphone On")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(
                    AppTheme.backgroundSecondary,
                    in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                        .strokeBorder(AppTheme.cardBorderColor, lineWidth: 1)
                )

                HStack(spacing: 6) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text("Overtime_Clutch.mp4")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text("ranked")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.accent.opacity(0.14), in: Capsule())
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 42)
                .background(
                    AppTheme.backgroundSecondary,
                    in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                        .strokeBorder(AppTheme.cardBorderColor, lineWidth: 1)
                )
            }
        }
        .padding(14)
        .background(
            AppTheme.backgroundPrimary,
            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusLarge, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(AppTheme.cardBorderColor, lineWidth: 1)
        )
    }
}

// MARK: - Atmosphere Preset Card

private struct AtmospherePresetCard: View {
    let atmosphere: ThemeAtmosphere
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var environmentColorScheme
    @State private var isHovering = false

    private var usesDarkPreview: Bool {
        switch AppTheme.colorScheme {
        case .dark: true
        case .light: false
        case .system: environmentColorScheme == .dark
        }
    }

    private var canvasColor: Color {
        ColorHex.color(from: usesDarkPreview ? atmosphere.darkCanvasHex : atmosphere.lightCanvasHex)
    }

    private var cardColor: Color {
        ColorHex.color(from: usesDarkPreview ? atmosphere.darkCardHex : atmosphere.lightCardHex)
    }

    private var primaryAccent: Color {
        atmosphere == .native
            ? Color(nsColor: .controlAccentColor)
            : ColorHex.color(from: atmosphere.defaultPrimaryAccentHex)
    }

    private var secondaryAccent: Color {
        atmosphere == .native
            ? Color(nsColor: .controlAccentColor)
            : ColorHex.color(from: atmosphere.defaultSecondaryAccentHex)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // Miniature surface + accent preview
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(canvasColor)
                        .frame(height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )

                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(cardColor)
                            .frame(width: 48, height: 24)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [primaryAccent, secondaryAccent],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: 26, height: 6)
                                    .padding(.leading, 6)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color.white.opacity(usesDarkPreview ? 0.1 : 0.25), lineWidth: 0.5)
                            )

                        Spacer()

                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [primaryAccent, secondaryAccent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 14, height: 14)
                    }
                    .padding(8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(atmosphere.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                    Text(atmosphere.subtitle)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .background(
                isSelected
                    ? AppTheme.accent.opacity(0.12)
                    : (isHovering ? AppTheme.backgroundSecondary.opacity(0.6) : AppTheme.backgroundSecondary.opacity(0.25)),
                in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
                    .strokeBorder(
                        isSelected ? AppTheme.accent : AppTheme.cardBorderColor,
                        lineWidth: isSelected ? 1.5 : 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(atmosphere.title), \(atmosphere.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Swatch Button

private struct SwatchButton: View {
    let swatch: ThemeSwatch
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            ColorHex.color(from: swatch.primaryHex),
                            ColorHex.color(from: swatch.secondaryHex)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 24, height: 24)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 1)
                    }
                }
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.primary : Color.white.opacity(0.25),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(swatch.title)
        .accessibilityLabel(swatch.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
