import XCTest
@testable import UI

final class FeatureModuleChangeTests: XCTestCase {
    private typealias Stored = FeatureModuleChange.StoredSettings

    private let noEffect = FeatureModuleChange(from: [], to: [], stored: Stored())

    private func change(
        from old: Set<FeatureModule>,
        to new: Set<FeatureModule>,
        _ configure: (inout Stored) -> Void = { _ in }
    ) -> FeatureModuleChange {
        var stored = Stored()
        configure(&stored)
        return FeatureModuleChange(from: old, to: new, stored: stored)
    }

    func testUnchangedModulesDoNothing() {
        // Covers an observer firing with old == new (for example an initial fire).
        let full = ExperiencePreset.full.modules
        let result = change(from: full, to: full) { stored in
            stored.autoRecordGamesEnabled = true
            stored.captureMode = CaptureMode.dualSideBySide.rawValue
        }
        XCTAssertEqual(result, noEffect)
    }

    func testUIOnlyModulesNeverTouchCapture() {
        for module in [FeatureModule.appearance, .sessionRecording, .quickSaveAndThumbnail, .captureProfiles] {
            let full = ExperiencePreset.full.modules
            XCTAssertEqual(change(from: full, to: full.subtracting([module])), noEffect, "\(module)")
            XCTAssertEqual(change(from: full.subtracting([module]), to: full), noEffect, "\(module)")
        }
    }

    func testSwitchingPresetsWithDefaultSettingsDoesNotRestartOrResumeCapture() {
        let result = change(from: ExperiencePreset.full.modules, to: ExperiencePreset.simple.modules)
        XCTAssertFalse(result.needsFullRestart)
        XCTAssertFalse(result.needsVideoReset)
        XCTAssertFalse(result.resumeAlwaysOnRecording)
    }

    func testDisablingAutoRecordGamesResumesAlwaysOnRecordingOnlyWhenItWasOn() {
        let full = ExperiencePreset.full.modules
        let withoutGames = full.subtracting([.autoRecordGames])

        let wasOn = change(from: full, to: withoutGames) { $0.autoRecordGamesEnabled = true }
        XCTAssertTrue(wasOn.reconcileGameAutoRecord)
        XCTAssertTrue(wasOn.resumeAlwaysOnRecording)

        let wasOff = change(from: full, to: withoutGames)
        XCTAssertEqual(wasOff, noEffect)

        let reenabled = change(from: withoutGames, to: full) { $0.autoRecordGamesEnabled = true }
        XCTAssertTrue(reenabled.reconcileGameAutoRecord)
        XCTAssertFalse(reenabled.resumeAlwaysOnRecording)
    }

    func testProVideoRestartsOnlyWhenCaptureShapeChanges() {
        let full = ExperiencePreset.full.modules
        let withoutPro = full.subtracting([.proVideo])

        XCTAssertEqual(change(from: full, to: withoutPro), noEffect)

        let dual = change(from: full, to: withoutPro) { $0.captureMode = CaptureMode.dualSideBySide.rawValue }
        XCTAssertTrue(dual.needsFullRestart)

        let hdr = change(from: withoutPro, to: full) { $0.captureHDR = true }
        XCTAssertTrue(hdr.needsFullRestart)

        let codec = change(from: full, to: withoutPro) { $0.videoCodec = VideoCodec.h264.rawValue }
        XCTAssertTrue(codec.reconcileCapture)
        XCTAssertTrue(codec.needsVideoReset)
        XCTAssertFalse(codec.needsFullRestart)

        let custom = change(from: full, to: withoutPro) { $0.captureResolution = CaptureResolution.custom.rawValue }
        XCTAssertTrue(custom.needsVideoReset)
        XCTAssertFalse(custom.needsFullRestart)
    }

    func testExtendedReplayReconcilesLightlyWhenTheLongBufferIsOn() {
        let full = ExperiencePreset.full.modules
        let withoutExtended = full.subtracting([.extendedReplay])

        XCTAssertEqual(change(from: full, to: withoutExtended), noEffect)

        let result = change(from: full, to: withoutExtended) { $0.longBufferEnabled = true }
        XCTAssertTrue(result.reconcileCapture)
        XCTAssertFalse(result.needsVideoReset)
        XCTAssertFalse(result.needsFullRestart)
    }

    func testAudioMixingRefreshesAudioWithoutRestarting() {
        let result = change(from: ExperiencePreset.balanced.modules, to: ExperiencePreset.simple.modules)
        XCTAssertTrue(result.refreshAudio)
        XCTAssertTrue(result.reconcileCapture)
        XCTAssertFalse(result.needsVideoReset)
        XCTAssertFalse(result.needsFullRestart)
    }

    func testSystemTuningResetsVideoOnlyForACustomQueueDepth() {
        let full = ExperiencePreset.full.modules
        let withoutTuning = full.subtracting([.systemAndFileTuning])

        let defaultDepth = change(from: full, to: withoutTuning)
        XCTAssertTrue(defaultDepth.syncMemoryCaps)
        XCTAssertFalse(defaultDepth.reconcileCapture)

        let customDepth = change(from: full, to: withoutTuning) { $0.queueDepth = 8 }
        XCTAssertTrue(customDepth.reconcileCapture)
        XCTAssertTrue(customDepth.needsVideoReset)
    }

    func testCompanionToggleReconcilesServer() {
        let full = ExperiencePreset.full.modules
        let result = change(from: full, to: full.subtracting([.companion]))
        XCTAssertTrue(result.reconcileCompanionServer)
        XCTAssertFalse(result.reconcileCapture)
    }
}
