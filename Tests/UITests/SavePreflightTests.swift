import XCTest
@testable import UI

final class SavePreflightTests: XCTestCase {
    func testBlocksWhenNotRecording() {
        let failure = SavePreflight.failure(
            isRecording: false,
            bufferedSeconds: 30,
            saveInProgress: false
        )

        XCTAssertEqual(failure, .notRecording)
    }

    func testBlocksWhenBufferEmpty() {
        let failure = SavePreflight.failure(
            isRecording: true,
            bufferedSeconds: 0.5,
            saveInProgress: false
        )

        XCTAssertEqual(failure, .bufferEmpty)
    }

    /// A session recording that owns the capture pipeline keeps the replay
    /// buffers empty on purpose. Reporting `.bufferEmpty` there would tell the
    /// user to wait for something that is never going to arrive.
    func testReportsReplayBufferOffRatherThanStillFilling() {
        let failure = SavePreflight.failure(
            isRecording: true,
            bufferedSeconds: 0,
            saveInProgress: false,
            replayBufferEnabled: false
        )

        XCTAssertEqual(failure, .replayBufferUnavailable)
    }

    func testReplayBufferOffDisablesBothReplaySaveActions() {
        XCTAssertFalse(SavePreflight.canSaveQuickReplay(
            isRecording: true,
            bufferedSeconds: 30,
            saveInProgress: false,
            replayBufferEnabled: false
        ))
        XCTAssertFalse(SavePreflight.canSaveLongReplay(
            isRecording: true,
            saveInProgress: false,
            replayBufferEnabled: false
        ))
    }

    /// An in-flight save still takes priority, so the user is told to wait
    /// rather than being sent to a setting that is not the reason.
    func testSaveInProgressOutranksReplayBufferOff() {
        let failure = SavePreflight.failure(
            isRecording: true,
            bufferedSeconds: 0,
            saveInProgress: true,
            replayBufferEnabled: false
        )

        XCTAssertEqual(failure, .saveInProgress)
    }

    func testBlocksWhenSaveInProgress() {
        let failure = SavePreflight.failure(
            isRecording: true,
            bufferedSeconds: 30,
            saveInProgress: true
        )

        XCTAssertEqual(failure, .saveInProgress)
    }

    func testBothReplaySaveActionsAreDisabledWhileSaving() {
        XCTAssertFalse(SavePreflight.canSaveQuickReplay(
            isRecording: true,
            bufferedSeconds: 30,
            saveInProgress: true
        ))
        XCTAssertFalse(SavePreflight.canSaveLongReplay(
            isRecording: true,
            saveInProgress: true
        ))

        XCTAssertTrue(SavePreflight.canSaveQuickReplay(
            isRecording: true,
            bufferedSeconds: 30,
            saveInProgress: false
        ))
        XCTAssertTrue(SavePreflight.canSaveLongReplay(
            isRecording: true,
            saveInProgress: false
        ))
    }

    func testAllowsSaveWhenReady() {
        let failure = SavePreflight.failure(
            isRecording: true,
            bufferedSeconds: 5,
            saveInProgress: false
        )

        XCTAssertNil(failure)
    }

    func testBufferedSecondsUsesPrimaryVideoForNormalSave() {
        let bufferedSeconds = SavePreflight.bufferedSeconds(
            primaryVideo: 8,
            dualDisplay1: 3,
            dualDisplay2: 4,
            isSeparateDualSave: false
        )

        XCTAssertEqual(bufferedSeconds, 8)
    }

    func testBufferedSecondsUsesShortestDualBufferForSeparateDualSave() {
        let bufferedSeconds = SavePreflight.bufferedSeconds(
            primaryVideo: 0,
            dualDisplay1: 6,
            dualDisplay2: 4,
            isSeparateDualSave: true
        )

        XCTAssertEqual(bufferedSeconds, 4)
    }

    func testSeparateDualSaveCanPassPreflightWhenPrimaryBufferIsEmpty() {
        let bufferedSeconds = SavePreflight.bufferedSeconds(
            primaryVideo: 0,
            dualDisplay1: 2,
            dualDisplay2: 2.5,
            isSeparateDualSave: true
        )
        let failure = SavePreflight.failure(
            isRecording: true,
            bufferedSeconds: bufferedSeconds,
            saveInProgress: false
        )

        XCTAssertNil(failure)
    }

    func testEstimatedClipBytesScalesWithBitrateDurationAndStreams() {
        // 25 Mbps for 30s ≈ 93.75 MB before overhead/streams.
        let single = SavePreflight.estimatedClipBytes(
            bitrateMbps: 25,
            durationSeconds: 30,
            streamCount: 1,
            overhead: 1.0
        )
        XCTAssertEqual(single, Int64(25 * 1_000_000 / 8 * 30))

        let dual = SavePreflight.estimatedClipBytes(
            bitrateMbps: 25,
            durationSeconds: 30,
            streamCount: 2,
            overhead: 1.0
        )
        XCTAssertEqual(dual, single * 2)
    }

    func testEstimatedClipBytesIsZeroForInvalidInput() {
        XCTAssertEqual(SavePreflight.estimatedClipBytes(bitrateMbps: 0, durationSeconds: 30), 0)
        XCTAssertEqual(SavePreflight.estimatedClipBytes(bitrateMbps: 25, durationSeconds: 0), 0)
    }

    func testDiskFailureWhenSpaceBelowEstimatePlusMargin() {
        let failure = SavePreflight.diskFailure(
            estimatedClipBytes: 100 * 1024 * 1024,
            availableCapacityBytes: 150 * 1024 * 1024,
            safetyMarginBytes: 200 * 1024 * 1024
        )

        XCTAssertEqual(failure, .insufficientDiskSpace)
    }

    func testDiskFailureNilWhenEnoughSpace() {
        let failure = SavePreflight.diskFailure(
            estimatedClipBytes: 100 * 1024 * 1024,
            availableCapacityBytes: 5 * 1024 * 1024 * 1024,
            safetyMarginBytes: 200 * 1024 * 1024
        )

        XCTAssertNil(failure)
    }

    func testDiskFailureNilWhenEstimateUnknown() {
        let failure = SavePreflight.diskFailure(
            estimatedClipBytes: 0,
            availableCapacityBytes: 0
        )

        XCTAssertNil(failure)
    }

    func testResolvedCapacityFallsBackToStandardCapacityWhenImportantUsageIsZero() {
        // External APFS volumes report 0 for volumeAvailableCapacityForImportantUsage
        // while reporting their true free space in volumeAvailableCapacity.
        let fiveHundredGB = 500 * 1024 * 1024 * 1024
        let capacity = SavePreflight.resolvedAvailableCapacityBytes(
            importantUsage: 0,
            standardCapacity: fiveHundredGB
        )

        XCTAssertEqual(capacity, Int64(fiveHundredGB))
        XCTAssertNil(SavePreflight.diskFailure(
            estimatedClipBytes: 150 * 1024 * 1024,
            availableCapacityBytes: capacity ?? 0
        ))
    }

    func testResolvedCapacityPreservesZeroWhenVolumeIsGenuinelyFull() {
        let capacity = SavePreflight.resolvedAvailableCapacityBytes(
            importantUsage: 0,
            standardCapacity: 0
        )

        XCTAssertEqual(capacity, 0)
        XCTAssertEqual(
            SavePreflight.diskFailure(
                estimatedClipBytes: 50 * 1024 * 1024,
                availableCapacityBytes: capacity ?? 0
            ),
            .insufficientDiskSpace
        )
    }

    func testResolvedCapacityUsesImportantUsageWhenGreaterThanStandardCapacity() {
        let important: Int64 = 120 * 1024 * 1024 * 1024
        let standard: Int = 80 * 1024 * 1024 * 1024

        XCTAssertEqual(
            SavePreflight.resolvedAvailableCapacityBytes(
                importantUsage: important,
                standardCapacity: standard
            ),
            important
        )
    }

    func testExistingProbeURLWalksUpToMountedVolumeRootInsteadOfFallback() throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fakeVolumesRoot = sandboxRoot.appendingPathComponent("Volumes", isDirectory: true)
        let mountedDrive = fakeVolumesRoot.appendingPathComponent("ExternalAPFS", isDirectory: true)
        let uncreatedLeaf = mountedDrive
            .appendingPathComponent("Clips", isDirectory: true)
            .appendingPathComponent("ReplayMac", isDirectory: true)
        let fallbackHome = sandboxRoot.appendingPathComponent("Home", isDirectory: true)

        try FileManager.default.createDirectory(at: mountedDrive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let probe = SavePreflight.existingProbeURL(
            for: uncreatedLeaf,
            fallbackURL: fallbackHome,
            volumesRootURL: fakeVolumesRoot
        )

        XCTAssertEqual(probe, mountedDrive.standardizedFileURL)
    }

    func testUnmountedExternalVolumeNameDetectsMissingMountAndAllowsMountedVolume() throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fakeVolumesRoot = sandboxRoot.appendingPathComponent("Volumes", isDirectory: true)
        let mountedDrive = fakeVolumesRoot.appendingPathComponent("MountedSSD", isDirectory: true)
        try FileManager.default.createDirectory(at: mountedDrive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let mountedClipFolder = mountedDrive.appendingPathComponent("ReplayMac", isDirectory: true)
        XCTAssertNil(
            SavePreflight.unmountedExternalVolumeName(
                for: mountedClipFolder,
                volumesRootURL: fakeVolumesRoot
            )
        )

        let unmountedClipFolder = fakeVolumesRoot
            .appendingPathComponent("DisconnectedSSD", isDirectory: true)
            .appendingPathComponent("ReplayMac", isDirectory: true)
        XCTAssertEqual(
            SavePreflight.unmountedExternalVolumeName(
                for: unmountedClipFolder,
                volumesRootURL: fakeVolumesRoot
            ),
            "DisconnectedSSD"
        )
    }
}
