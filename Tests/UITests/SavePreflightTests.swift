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

    func testBlocksWhenSaveInProgress() {
        let failure = SavePreflight.failure(
            isRecording: true,
            bufferedSeconds: 30,
            saveInProgress: true
        )

        XCTAssertEqual(failure, .saveInProgress)
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
}
