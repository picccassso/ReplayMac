import Defaults
import XCTest
@testable import UI

final class ExperiencePresetTests: XCTestCase {
    private var originalModules: Set<FeatureModule> = []
    private var originalLongBuffer: Bool = false
    private var originalCompanion: Bool = false
    private var originalAutoRecordGames: Bool = false
    private var originalCaptureHDR: Bool = false
    private var originalCaptureMode: String = ""
    private var originalPerAppAudio: Bool = false
    private var originalShowClipThumbnail: Bool = false

    override func setUp() {
        super.setUp()
        originalModules = Defaults[.enabledFeatureModules]
        originalLongBuffer = Defaults[.longBufferEnabled]
        originalCompanion = Defaults[.companionServerEnabled]
        originalAutoRecordGames = Defaults[.autoRecordGamesEnabled]
        originalCaptureHDR = Defaults[.captureHDR]
        originalCaptureMode = Defaults[.captureMode]
        originalPerAppAudio = Defaults[.perAppAudioEnabled]
        originalShowClipThumbnail = Defaults[.showClipThumbnailAfterSave]
    }

    override func tearDown() {
        Defaults.reset(.enabledFeatureModules)
        Defaults[.longBufferEnabled] = originalLongBuffer
        Defaults[.companionServerEnabled] = originalCompanion
        Defaults[.autoRecordGamesEnabled] = originalAutoRecordGames
        Defaults[.captureHDR] = originalCaptureHDR
        Defaults[.captureMode] = originalCaptureMode
        Defaults[.perAppAudioEnabled] = originalPerAppAudio
        Defaults[.showClipThumbnailAfterSave] = originalShowClipThumbnail
        super.tearDown()
    }

    func testSimplePresetIncludesAppearance() {
        XCTAssertTrue(ExperiencePreset.simple.modules.contains(.appearance))
        XCTAssertEqual(ExperiencePreset.simple.modules, [.appearance])
    }

    func testPresetResolutions() {
        XCTAssertEqual(ExperiencePreset.resolve(from: ExperiencePreset.simple.modules), .simple)
        XCTAssertEqual(ExperiencePreset.resolve(from: ExperiencePreset.balanced.modules), .balanced)
        XCTAssertEqual(ExperiencePreset.resolve(from: ExperiencePreset.full.modules), .full)

        // Adding one module to Simple transitions to Custom
        var customSet = ExperiencePreset.simple.modules
        customSet.insert(.sessionRecording)
        XCTAssertEqual(ExperiencePreset.resolve(from: customSet), .custom)

        // Removing one module from Full transitions to Custom
        var fullMinusOne = ExperiencePreset.full.modules
        fullMinusOne.remove(.companion)
        XCTAssertEqual(ExperiencePreset.resolve(from: fullMinusOne), .custom)
    }

    func testApplyExperiencePreset() {
        AppSettings.applyExperiencePreset(.simple)
        XCTAssertEqual(AppSettings.enabledFeatureModules, ExperiencePreset.simple.modules)
        XCTAssertEqual(AppSettings.experiencePreset, .simple)

        AppSettings.applyExperiencePreset(.balanced)
        XCTAssertEqual(AppSettings.enabledFeatureModules, ExperiencePreset.balanced.modules)
        XCTAssertEqual(AppSettings.experiencePreset, .balanced)

        AppSettings.applyExperiencePreset(.full)
        XCTAssertEqual(AppSettings.enabledFeatureModules, ExperiencePreset.full.modules)
        XCTAssertEqual(AppSettings.experiencePreset, .full)
    }

    func testSetIndividualFeatureModuleSwitchesPresetToCustom() {
        AppSettings.applyExperiencePreset(.simple)
        XCTAssertEqual(AppSettings.experiencePreset, .simple)

        AppSettings.setFeatureEnabled(.sessionRecording, true)
        XCTAssertTrue(AppSettings.isFeatureEnabled(.sessionRecording))
        XCTAssertEqual(AppSettings.experiencePreset, .custom)

        AppSettings.setFeatureEnabled(.sessionRecording, false)
        XCTAssertFalse(AppSettings.isFeatureEnabled(.sessionRecording))
        XCTAssertEqual(AppSettings.experiencePreset, .simple)
    }

    func testNonDestructiveRuntimeSuspensionForExtendedReplay() {
        Defaults[.longBufferEnabled] = true

        AppSettings.applyExperiencePreset(.full)
        XCTAssertTrue(AppSettings.longBufferEnabled)

        AppSettings.applyExperiencePreset(.simple)
        // Suspended at runtime because module is disabled
        XCTAssertFalse(AppSettings.longBufferEnabled)
        // But underlying Defaults value is preserved
        XCTAssertTrue(Defaults[.longBufferEnabled])

        AppSettings.applyExperiencePreset(.full)
        // Automatically restored
        XCTAssertTrue(AppSettings.longBufferEnabled)
    }

    func testNonDestructiveRuntimeSuspensionForCompanionServer() {
        Defaults[.companionServerEnabled] = true

        AppSettings.applyExperiencePreset(.full)
        XCTAssertTrue(AppSettings.companionServerEnabled)

        AppSettings.applyExperiencePreset(.simple)
        XCTAssertFalse(AppSettings.companionServerEnabled)
        XCTAssertTrue(Defaults[.companionServerEnabled])

        AppSettings.applyExperiencePreset(.full)
        XCTAssertTrue(AppSettings.companionServerEnabled)
    }

    func testNonDestructiveRuntimeSuspensionForAutoRecordGames() {
        Defaults[.autoRecordGamesEnabled] = true

        AppSettings.applyExperiencePreset(.full)
        XCTAssertTrue(AppSettings.autoRecordGamesEnabled)

        AppSettings.applyExperiencePreset(.simple)
        XCTAssertFalse(AppSettings.autoRecordGamesEnabled)
        XCTAssertTrue(Defaults[.autoRecordGamesEnabled])

        AppSettings.applyExperiencePreset(.balanced)
        XCTAssertTrue(AppSettings.autoRecordGamesEnabled)
    }

    func testNonDestructiveRuntimeSuspensionForProVideo() {
        Defaults[.captureHDR] = true
        Defaults[.captureMode] = CaptureMode.dualSideBySide.rawValue

        AppSettings.applyExperiencePreset(.full)
        XCTAssertTrue(AppSettings.captureHDR)
        XCTAssertEqual(AppSettings.captureMode, CaptureMode.dualSideBySide.rawValue)

        AppSettings.applyExperiencePreset(.simple)
        XCTAssertFalse(AppSettings.captureHDR)
        XCTAssertEqual(AppSettings.captureMode, CaptureMode.single.rawValue)
        XCTAssertTrue(Defaults[.captureHDR])
        XCTAssertEqual(Defaults[.captureMode], CaptureMode.dualSideBySide.rawValue)

        AppSettings.applyExperiencePreset(.full)
        XCTAssertTrue(AppSettings.captureHDR)
        XCTAssertEqual(AppSettings.captureMode, CaptureMode.dualSideBySide.rawValue)
    }

    func testNonDestructiveRuntimeSuspensionForAudioMixing() {
        Defaults[.perAppAudioEnabled] = true

        AppSettings.applyExperiencePreset(.full)
        XCTAssertTrue(AppSettings.perAppAudioEnabled)

        AppSettings.applyExperiencePreset(.simple)
        XCTAssertFalse(AppSettings.perAppAudioEnabled)
        XCTAssertTrue(Defaults[.perAppAudioEnabled])

        AppSettings.applyExperiencePreset(.balanced)
        XCTAssertTrue(AppSettings.perAppAudioEnabled)
    }
}
