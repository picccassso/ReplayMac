import XCTest
@testable import UI

final class OnboardingStateTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testFreshInstallNeedsOnboarding() {
        XCTAssertFalse(
            OnboardingState.shouldTreatAsExistingInstallation(
                hasLegacyPreferences: false,
                hasSavedClips: false
            )
        )
    }

    func testStoredPreferencesIdentifyExistingInstall() {
        XCTAssertTrue(
            OnboardingState.shouldTreatAsExistingInstallation(
                hasLegacyPreferences: true,
                hasSavedClips: false
            )
        )
    }

    func testSavedClipsIdentifyExistingInstall() {
        XCTAssertTrue(
            OnboardingState.shouldTreatAsExistingInstallation(
                hasLegacyPreferences: false,
                hasSavedClips: true
            )
        )
    }

    func testSystemWindowStateDoesNotIdentifyExistingInstall() {
        XCTAssertFalse(
            OnboardingState.containsLegacyPreference(
                in: ["NSWindow Frame Settings", "com_apple_SwiftUI_Settings_selectedTabIndex"]
            )
        )
    }

    func testStoredAppPreferenceIdentifiesExistingInstall() {
        XCTAssertTrue(
            OnboardingState.containsLegacyPreference(
                in: ["NSWindow Frame Settings", "bufferDurationSeconds"]
            )
        )
    }

    @MainActor
    func testMigrationMarksStoredAppPreferencesComplete() throws {
        let (defaults, suiteName) = try makeDefaults()
        defaults.set(45, forKey: "bufferDurationSeconds")

        OnboardingState.migrateExistingInstallationIfNeeded(
            defaults: defaults,
            bundleIdentifier: suiteName,
            outputDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        XCTAssertEqual(defaults.object(forKey: "hasCompletedOnboarding") as? Bool, true)
    }

    @MainActor
    func testMigrationLeavesFreshInstallIncomplete() throws {
        let (defaults, suiteName) = try makeDefaults()

        OnboardingState.migrateExistingInstallationIfNeeded(
            defaults: defaults,
            bundleIdentifier: suiteName,
            outputDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        XCTAssertNil(defaults.object(forKey: "hasCompletedOnboarding"))
        XCTAssertEqual(
            defaults.object(forKey: "didEvaluateLegacyOnboardingMigration") as? Bool,
            true
        )
    }

    @MainActor
    func testRestartDuringOnboardingDoesNotBecomeLegacyInstallation() throws {
        let (defaults, suiteName) = try makeDefaults()
        let missingOutputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        OnboardingState.migrateExistingInstallationIfNeeded(
            defaults: defaults,
            bundleIdentifier: suiteName,
            outputDirectory: missingOutputDirectory
        )

        // Onboarding and normal launch code persist preferences before macOS
        // may restart the app to apply a privacy permission change.
        defaults.set(45, forKey: "bufferDurationSeconds")
        OnboardingState.migrateExistingInstallationIfNeeded(
            defaults: defaults,
            bundleIdentifier: suiteName,
            outputDirectory: missingOutputDirectory
        )

        XCTAssertNil(defaults.object(forKey: "hasCompletedOnboarding"))
    }

    @MainActor
    func testMigrationInitializesFullPresetForExistingInstallation() throws {
        let (defaults, suiteName) = try makeDefaults()
        defaults.set(true, forKey: "hasCompletedOnboarding")

        OnboardingState.migrateExistingInstallationIfNeeded(
            defaults: defaults,
            bundleIdentifier: suiteName,
            outputDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        let modules = (defaults.stringArray(forKey: "enabledFeatureModules") ?? [])
        XCTAssertEqual(Set(modules.compactMap(FeatureModule.init)), ExperiencePreset.full.modules)
        XCTAssertEqual(defaults.bool(forKey: "didInitializeExperiencePreset"), true)
    }

    @MainActor
    func testFreshInstallInitializesSimplePreset() throws {
        let (defaults, suiteName) = try makeDefaults()

        OnboardingState.migrateExistingInstallationIfNeeded(
            defaults: defaults,
            bundleIdentifier: suiteName,
            outputDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        let modules = (defaults.stringArray(forKey: "enabledFeatureModules") ?? [])
        XCTAssertEqual(Set(modules.compactMap(FeatureModule.init)), ExperiencePreset.simple.modules)
        XCTAssertEqual(defaults.bool(forKey: "didInitializeExperiencePreset"), true)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Unable to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
