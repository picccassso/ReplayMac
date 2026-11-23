import XCTest
import Defaults
import Capture
@testable import UI

final class VideoFilterSettingsTests: XCTestCase {
    private func withSavedVideoFilterDefaults(_ body: () -> Void) {
        let mode = Defaults[.videoCaptureFilterMode]
        let hideMenuBar = Defaults[.hideMenuBarInRecording]
        let hideFloating = Defaults[.hideFloatingUtilityApps]
        let hiddenApps = Defaults[.hiddenVideoAppBundleIDs]
        let selectedApp = Defaults[.selectedVideoAppBundleID]
        let profilesJSON = Defaults[.captureProfilesJSON]
        defer {
            Defaults[.videoCaptureFilterMode] = mode
            Defaults[.hideMenuBarInRecording] = hideMenuBar
            Defaults[.hideFloatingUtilityApps] = hideFloating
            Defaults[.hiddenVideoAppBundleIDs] = hiddenApps
            Defaults[.selectedVideoAppBundleID] = selectedApp
            Defaults[.captureProfilesJSON] = profilesJSON
        }
        body()
    }

    func testDefaultValuesMatchSpec() {
        XCTAssertEqual(Defaults.Keys.videoCaptureFilterMode.defaultValue, VideoCaptureFilterMode.fullDisplay.rawValue)
        XCTAssertEqual(Defaults.Keys.hideMenuBarInRecording.defaultValue, false)
        XCTAssertEqual(Defaults.Keys.hideFloatingUtilityApps.defaultValue, true)
        XCTAssertEqual(Defaults.Keys.hiddenVideoAppBundleIDs.defaultValue, [])
        XCTAssertEqual(Defaults.Keys.selectedVideoAppBundleID.defaultValue, "")
    }

    func testGarbageRawValueFallsBackToFullDisplay() {
        withSavedVideoFilterDefaults {
            Defaults[.videoCaptureFilterMode] = "invalid_mode"
            XCTAssertEqual(AppSettings.videoCaptureFilterModeEnum, .fullDisplay)
            XCTAssertFalse(AppSettings.videoFilterRequiresSplitSystemAudio)
        }
    }

    func testSplitAudioPolicyTracksFilterMode() {
        withSavedVideoFilterDefaults {
            Defaults[.videoCaptureFilterMode] = VideoCaptureFilterMode.fullDisplay.rawValue
            XCTAssertFalse(AppSettings.videoFilterRequiresSplitSystemAudio)

            Defaults[.videoCaptureFilterMode] = VideoCaptureFilterMode.hideOverlays.rawValue
            XCTAssertTrue(AppSettings.videoFilterRequiresSplitSystemAudio)

            Defaults[.videoCaptureFilterMode] = VideoCaptureFilterMode.activeApp.rawValue
            XCTAssertTrue(AppSettings.videoFilterRequiresSplitSystemAudio)

            Defaults[.videoCaptureFilterMode] = VideoCaptureFilterMode.selectedApp.rawValue
            XCTAssertTrue(AppSettings.videoFilterRequiresSplitSystemAudio)
        }
    }

    func testHideUnhideVideoAppHelpersDedupeCaseInsensitively() {
        withSavedVideoFilterDefaults {
            Defaults[.hiddenVideoAppBundleIDs] = []

            AppSettings.hideVideoApp("  ")
            XCTAssertTrue(AppSettings.hiddenVideoAppBundleIDs.isEmpty)

            AppSettings.hideVideoApp(" com.example.Notch ")
            AppSettings.hideVideoApp("COM.EXAMPLE.NOTCH")
            XCTAssertEqual(AppSettings.hiddenVideoAppBundleIDs, ["com.example.Notch"])
            XCTAssertTrue(AppSettings.isVideoAppHidden("com.example.notch"))

            AppSettings.hideVideoApp("com.example.Slack")
            AppSettings.unhideVideoApp("COM.EXAMPLE.NOTCH")
            XCTAssertEqual(AppSettings.hiddenVideoAppBundleIDs, ["com.example.Slack"])

            AppSettings.unhideAllVideoApps()
            XCTAssertTrue(AppSettings.hiddenVideoAppBundleIDs.isEmpty)
        }
    }

    func testCaptureProfileBackwardCompatibleDecodingAndRoundTrip() throws {
        withSavedVideoFilterDefaults {
            // Legacy profile JSON without any video-filter fields must still decode cleanly.
            let legacyJSON = """
            [{
              "id": "11111111-2222-3333-4444-555555555555",
              "name": "Legacy",
              "createdAt": 0,
              "updatedAt": 0,
              "videoCodecRawValue": "hevc",
              "captureModeRawValue": "single",
              "captureDisplayID": "",
              "captureDisplayID2": "",
              "dualCaptureSaveModeRawValue": "side_by_side",
              "captureResolutionRawValue": "native",
              "customCaptureWidth": 1920,
              "customCaptureHeight": 1080,
              "frameRate": 60,
              "bitrateMbps": 25,
              "qualityPresetRawValue": "quality",
              "captureSystemAudio": true,
              "captureMicrophone": false,
              "microphoneID": "",
              "excludeOwnAppAudio": true,
              "perAppAudioEnabled": false,
              "perAppAudioBundleID": "",
              "systemAudioVolume": 1.0,
              "microphoneVolume": 1.0,
              "memoryCapMB": 512,
              "queueDepth": 3,
              "longBufferEnabled": false,
              "longBufferDurationMinutes": 5
            }]
            """
            let decoded = try! JSONDecoder().decode([CaptureProfile].self, from: Data(legacyJSON.utf8))
            XCTAssertEqual(decoded.count, 1)
            XCTAssertNil(decoded[0].videoCaptureFilterModeRawValue)
            XCTAssertNil(decoded[0].hideMenuBarInRecording)
            XCTAssertNil(decoded[0].hideFloatingUtilityApps)
            XCTAssertNil(decoded[0].hiddenVideoAppBundleIDs)
            XCTAssertNil(decoded[0].selectedVideoAppBundleID)

            // Applying a profile with video filter settings restores all new keys.
            var updated = decoded[0]
            updated.videoCaptureFilterModeRawValue = VideoCaptureFilterMode.hideOverlays.rawValue
            updated.hideMenuBarInRecording = true
            updated.hideFloatingUtilityApps = false
            updated.hiddenVideoAppBundleIDs = ["com.hnc.Discord"]
            updated.selectedVideoAppBundleID = "com.apple.Safari"

            let encoded = try! JSONEncoder().encode([updated])
            Defaults[.captureProfilesJSON] = String(decoding: encoded, as: UTF8.self)

            XCTAssertTrue(AppSettings.applyCaptureProfile(id: updated.id.uuidString))
            XCTAssertEqual(AppSettings.videoCaptureFilterModeEnum, .hideOverlays)
            XCTAssertEqual(AppSettings.hideMenuBarInRecording, true)
            XCTAssertEqual(AppSettings.hideFloatingUtilityApps, false)
            XCTAssertEqual(AppSettings.hiddenVideoAppBundleIDs, ["com.hnc.Discord"])
            XCTAssertEqual(AppSettings.selectedVideoAppBundleID, "com.apple.Safari")
        }
    }
}
