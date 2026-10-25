import AppKit
import Branding
import Defaults
import SwiftUI

/// Preset selection cards displayed in Onboarding and Settings → General.
public struct ExperiencePresetCardsView: View {
    @Default(.enabledFeatureModules) private var enabledFeatureModules
    @Binding private var isPresentingCustomiser: Bool
    private let showsHeader: Bool

    public init(
        isPresentingCustomiser: Binding<Bool>,
        showsHeader: Bool = true
    ) {
        self._isPresentingCustomiser = isPresentingCustomiser
        self.showsHeader = showsHeader
    }

    private var activePreset: ExperiencePreset {
        ExperiencePreset.resolve(from: enabledFeatureModules)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App Experience")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text("Choose how simple or feature-packed \(AppBranding.name) feels.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    Spacer()

                    if activePreset == .custom {
                        Text("Custom (\(enabledFeatureModules.count)/\(FeatureModule.allCases.count) modules)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AppTheme.accent.opacity(0.15))
                            .foregroundStyle(AppTheme.accent)
                            .clipShape(Capsule())
                    }
                }
            }

            HStack(spacing: 10) {
                ForEach(ExperiencePreset.selectablePresets) { preset in
                    presetCard(preset)
                }
            }

            HStack {
                if activePreset == .custom {
                    Label(
                        "You have customised features enabled. Selecting a preset above will replace them.",
                        systemImage: "slider.horizontal.3"
                    )
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()

                Button {
                    isPresentingCustomiser = true
                } label: {
                    Label("Customise Features…", systemImage: "checklist")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .buttonStyle(.link)
            }
            .padding(.top, 2)
        }
    }

    private func presetCard(_ preset: ExperiencePreset) -> some View {
        let isSelected = activePreset == preset

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                AppSettings.applyExperiencePreset(preset)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: preset.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textSecondary)

                    Spacer(minLength: 0)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textSecondary.opacity(0.4))
                }

                Text(preset.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(preset.subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous)
                    .fill(isSelected ? AppTheme.accent.opacity(0.12) : AppTheme.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous)
                    .stroke(isSelected ? AppTheme.accent : Color.secondary.opacity(0.15), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Modal sheet that allows users to toggle each of the 10 feature modules individually.
public struct FeatureCustomiserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Default(.enabledFeatureModules) private var enabledFeatureModules
    @State private var selectedCategory: FeatureCategory = .video

    public init() {}

    private var activePreset: ExperiencePreset {
        ExperiencePreset.resolve(from: enabledFeatureModules)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 14)

            presetQuickPicker
                .padding(.horizontal, 28)
                .padding(.bottom, 18)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                categorySidebar
                    .frame(width: 290, height: 340, alignment: .top)
                    .background(AppTheme.backgroundSecondary.opacity(0.45))

                Divider()
                    .frame(height: 340)

                categoryDetailPane(selectedCategory)
                    .frame(maxWidth: .infinity, minHeight: 340, alignment: .topLeading)
            }

            Divider()

            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(AppTheme.backgroundSecondary)
        }
        .frame(width: 780)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppTheme.backgroundPrimary)
        .themedWindowRoot()
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Customise Features")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("Tailor ReplayMac to your workflow. Changes apply instantly without losing saved configurations.")
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var presetQuickPicker: some View {
        HStack(spacing: 4) {
            ForEach(ExperiencePreset.selectablePresets) { preset in
                let isCurrent = activePreset == preset
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        AppSettings.applyExperiencePreset(preset)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: preset.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(preset.title)
                            .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        isCurrent
                            ? RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppTheme.accent.opacity(0.18))
                            : RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.clear)
                    )
                    .foregroundStyle(isCurrent ? AppTheme.accent : AppTheme.textSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isCurrent ? AppTheme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
                    // Unselected segments have a clear background, which a plain
                    // button ignores for clicks; make the whole segment clickable.
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(AppTheme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(FeatureCategory.allCases) { category in
                categorySidebarRow(category)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func categorySidebarRow(_ category: FeatureCategory) -> some View {
        let isSelected = selectedCategory == category
        let modules = FeatureModule.allCases.filter { $0.category == category }
        let enabledCount = modules.filter { enabledFeatureModules.contains($0) }.count

        return Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textSecondary)
                    .frame(width: 18)

                Text(category.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                // Badge keeps its natural size so a long category name can never
                // squeeze it into a vertical stack of characters.
                Text("\(enabledCount)/\(modules.count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 22)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(enabledCount > 0 ? AppTheme.accent.opacity(0.16) : Color.primary.opacity(0.06))
                    )
                    .foregroundStyle(enabledCount > 0 ? AppTheme.accent : AppTheme.textSecondary.opacity(0.75))
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AppTheme.accent.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? AppTheme.accent.opacity(0.32) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func categoryDetailPane(_ category: FeatureCategory) -> some View {
        let modules = FeatureModule.allCases.filter { $0.category == category }

        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(category.subtitle)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                ForEach(modules) { module in
                    moduleRow(module)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
    }

    private func moduleRow(_ module: FeatureModule) -> some View {
        let isEnabled = enabledFeatureModules.contains(module)

        // Icon badge, text and switch sit in fixed columns inside a standalone
        // interactive card so each item has clear visual boundaries and breathing room.
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled ? AppTheme.accent.opacity(0.15) : Color.primary.opacity(0.05))
                    .frame(width: 36, height: 36)

                Image(systemName: module.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isEnabled ? AppTheme.accent : AppTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(module.title)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(module.detail)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(module.title, isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        AppSettings.setFeatureEnabled(module, newValue)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(AppTheme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isEnabled ? AppTheme.accent.opacity(0.45) : Color.secondary.opacity(0.14),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                AppSettings.setFeatureEnabled(module, !isEnabled)
            }
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(activePreset == .custom ? AppTheme.accent : AppTheme.success)
                    .frame(width: 6, height: 6)

                if activePreset == .custom {
                    Text("Custom · \(enabledFeatureModules.count) of \(FeatureModule.allCases.count) features enabled")
                } else if activePreset == .simple {
                    Text("Simple Mode · Core clipping & themes")
                } else if activePreset == .balanced {
                    Text("Balanced Mode · 5 features enabled")
                } else {
                    Text("Full Mode · All 10 features enabled")
                }
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(AppTheme.textSecondary)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(AccentButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }
}
