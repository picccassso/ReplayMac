import Defaults
import Foundation
import Save

/// Owns first-run state and the one-time migration for installations that
/// predate onboarding.
@MainActor
public enum OnboardingState {
    private static let completionKey = "hasCompletedOnboarding"
    private static let migrationEvaluationKey = "didEvaluateLegacyOnboardingMigration"

    /// Marks an established installation as complete without showing first-run
    /// setup. This must run at the very start of application launch, before new
    /// defaults can be persisted.
    public static func migrateExistingInstallationIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        outputDirectory: URL = ClipMetadata.defaultOutputDirectory
    ) {
        guard let bundleIdentifier else { return }

        let domain = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]

        if domain["didInitializeExperiencePreset"] == nil {
            let isExisting = (domain[completionKey] as? Bool == true)
                || shouldTreatAsExistingInstallation(
                    hasLegacyPreferences: containsLegacyPreference(in: Set(domain.keys)),
                    hasSavedClips: fileManager.fileExists(atPath: outputDirectory.path(percentEncoded: false))
                )
            // Write through Defaults so the stored format matches what
            // `Defaults[.enabledFeatureModules]` decodes; raw strings written
            // with `defaults.set` read back as an empty set.
            let modulesKey = Defaults.Key<Set<FeatureModule>>(
                Defaults.Keys.enabledFeatureModules.name,
                default: Defaults.Keys.enabledFeatureModules.defaultValue,
                suite: defaults
            )
            Defaults[modulesKey] = isExisting ? ExperiencePreset.full.modules : ExperiencePreset.simple.modules
            defaults.set(true, forKey: "didInitializeExperiencePreset")
        }

        guard domain[completionKey] == nil else { return }
        // A fresh installation may be restarted while onboarding is still in
        // progress (for example, after changing Screen Recording permission).
        // Never reinterpret preferences written by that partial setup as
        // evidence of an installation that predates onboarding.
        guard domain[migrationEvaluationKey] == nil else { return }

        let hasLegacyPreferences = containsLegacyPreference(in: Set(domain.keys))
        let hasSavedClips = fileManager.fileExists(
            atPath: outputDirectory.path(percentEncoded: false)
        )

        if shouldTreatAsExistingInstallation(
            hasLegacyPreferences: hasLegacyPreferences,
            hasSavedClips: hasSavedClips
        ) {
            defaults.set(true, forKey: completionKey)
        }

        defaults.set(true, forKey: migrationEvaluationKey)
    }

    nonisolated static func shouldTreatAsExistingInstallation(
        hasLegacyPreferences: Bool,
        hasSavedClips: Bool
    ) -> Bool {
        hasLegacyPreferences || hasSavedClips
    }

    nonisolated static func containsLegacyPreference(in keys: Set<String>) -> Bool {
        keys.contains { key in
            key != "hasCompletedOnboarding"
                && key != "didEvaluateLegacyOnboardingMigration"
                && key != "didInitializeExperiencePreset"
                && key != "enabledFeatureModules"
                && !key.hasPrefix("NS")
                && !key.hasPrefix("com_apple_")
        }
    }
}
