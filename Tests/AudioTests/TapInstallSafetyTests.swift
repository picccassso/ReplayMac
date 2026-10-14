import AVFoundation
import XCTest
import ObjCExceptionCatcher
@testable import Audio

/// AVAudioEngine reports some failures by raising Objective-C exceptions,
/// which abort the app unless they are turned into Swift errors first.
final class TapInstallSafetyTests: XCTestCase {
    func testRaisedExceptionBecomesAnError() {
        XCTAssertThrowsError(try RCObjCException.performCatching {
            NSException(name: .internalInconsistencyException, reason: "required condition is false", userInfo: nil).raise()
        }) { error in
            XCTAssertEqual((error as NSError).domain, RCObjCExceptionErrorDomain)
            XCTAssertEqual(error.localizedDescription, "required condition is false")
        }
    }

    func testBlockThatDoesNotRaiseRunsNormally() throws {
        var ran = false
        try RCObjCException.performCatching { ran = true }
        XCTAssertTrue(ran)
    }

    func testRefusedTapIsAnErrorInsteadOfACrash() throws {
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        try XCTSkipIf(format.sampleRate == 0, "No audio output device on this machine")

        try MicCapture.installTapCatchingExceptions(on: mixer, bufferSize: 1024, format: format) { _, _ in }
        defer { mixer.removeTap(onBus: 0) }

        // A second tap on the same bus makes AVAudioEngine raise.
        XCTAssertThrowsError(
            try MicCapture.installTapCatchingExceptions(on: mixer, bufferSize: 1024, format: format) { _, _ in }
        ) { error in
            guard case MicCaptureError.tapInstallFailed = error else {
                return XCTFail("Expected tapInstallFailed, got \(error)")
            }
        }
    }

    func testMatchesBundleIDExactAndChildHelperProcesses() {
        XCTAssertTrue(PerAppAudioCapture.matchesBundleID("com.spotify.client", target: "com.spotify.client"))
        XCTAssertTrue(PerAppAudioCapture.matchesBundleID("COM.SPOTIFY.CLIENT", target: "com.spotify.client"))
        XCTAssertTrue(PerAppAudioCapture.matchesBundleID("com.hnc.Discord.helper", target: "com.hnc.Discord"))
        XCTAssertTrue(PerAppAudioCapture.matchesBundleID("com.hnc.Discord.helper.Renderer", target: "com.hnc.Discord"))

        // Sibling bundle IDs without a dot boundary must not match.
        XCTAssertFalse(PerAppAudioCapture.matchesBundleID("com.apple.FinalCutTrial", target: "com.apple.FinalCut"))
        XCTAssertFalse(PerAppAudioCapture.matchesBundleID("com.apple.Safari", target: "com.spotify.client"))
        XCTAssertFalse(PerAppAudioCapture.matchesBundleID("", target: "com.spotify.client"))
        XCTAssertFalse(PerAppAudioCapture.matchesBundleID("com.spotify.client", target: ""))

        XCTAssertTrue(
            PerAppAudioCapture.matchesAnyBundleID(
                "com.google.Chrome.helper",
                in: ["com.spotify.client", "com.google.Chrome"]
            )
        )
        XCTAssertFalse(
            PerAppAudioCapture.matchesAnyBundleID(
                "com.apple.Music",
                in: ["com.spotify.client", "com.google.Chrome"]
            )
        )
    }
}
