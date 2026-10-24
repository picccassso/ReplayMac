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

    public init() {}

    private var activePreset: ExperiencePreset {
        ExperiencePreset.resolve(from: enabledFeatureModules)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)

            presetQuickPicker
                .padding(.horizontal, 22)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(FeatureCategory.allCases) { category in
                        categorySection(category)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            .defaultScrollAnchor(.top)

            Divider()

            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(AppTheme.backgroundSecondary)
        }
        .frame(width: 560, height: 620)
        .background(AppTheme.backgroundPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .themedWindowRoot()
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Customise Features")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Tailor ReplayMac to your workflow. Changes apply instantly without losing saved configurations.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var presetQuickPicker: some View {
        HStack(spacing: 0) {
            ForEach(ExperiencePreset.selectablePresets) { preset in
                let isCurrent = activePreset == preset
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        AppSettings.applyExperiencePreset(preset)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: preset.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(preset.title)
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .medium, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        isCurrent
                            ? RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AppTheme.accent.opacity(0.18))
                            : RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.clear)
                    )
                    .foregroundStyle(isCurrent ? AppTheme.accent : AppTheme.textSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isCurrent ? AppTheme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(AppTheme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func categorySection(_ category: FeatureCategory) -> some View {
        let modules = FeatureModule.allCases.filter { $0.category == category }
        guard !modules.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Text(category.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 2)

                VStack(spacing: 0) {
                    ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                        moduleRow(module)

                        if index < modules.count - 1 {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .background(AppTheme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
            }
        )
    }

    private func moduleRow(_ module: FeatureModule) -> some View {
        let isEnabled = enabledFeatureModules.contains(module)

        return Toggle(isOn: Binding(
            get: { isEnabled },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.15)) {
                    AppSettings.setFeatureEnabled(module, newValue)
                }
            }
        )) {
            HStack(spacing: 11) {
                Image(systemName: module.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isEnabled ? AppTheme.accent : AppTheme.textSecondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text(module.detail)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 7)
        }
        .toggleStyle(.switch)
        .controlSize(.regular)
        .padding(.horizontal, 12)
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
