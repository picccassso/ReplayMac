import XCTest
import Defaults
import Capture
@testable import UI

final class CameraSettingsTests: XCTestCase {
    /// Runs `body` with all camera-related (and HDR interplay) defaults saved
    /// and restored afterwards, so tests don't leak state into each other.
    private func withSavedCameraDefaults(_ body: () -> Void) {
        let overlay = Defaults[.cameraOverlayEnabled]
        let device = Defaults[.cameraDeviceID]
        let position = Defaults[.cameraPosition]
        let size = Defaults[.cameraSize]
        let border = Defaults[.cameraBorderEnabled]
        let resolution = Defaults[.cameraResolution]
        let hdr = Defaults[.captureHDR]
        let codec = Defaults[.videoCodec]
        let mode = Defaults[.captureMode]
        let saveMode = Defaults[.dualCaptureSaveMode]
        let profilesJSON = Defaults[.captureProfilesJSON]
        defer {
            Defaults[.cameraOverlayEnabled] = overlay
            Defaults[.cameraDeviceID] = device
            Defaults[.cameraPosition] = position
            Defaults[.cameraSize] = size
            Defaults[.cameraBorderEnabled] = border
            Defaults[.cameraResolution] = resolution
            Defaults[.captureHDR] = hdr
            Defaults[.videoCodec] = codec
            Defaults[.captureMode] = mode
            Defaults[.dualCaptureSaveMode] = saveMode
            Defaults[.captureProfilesJSON] = profilesJSON
        }
        body()
    }

    func testCameraDefaultsMatchSpec() {
        XCTAssertEqual(Defaults.Keys.cameraOverlayEnabled.defaultValue, false)
        XCTAssertEqual(Defaults.Keys.cameraDeviceID.defaultValue, "")
        XCTAssertEqual(Defaults.Keys.cameraPosition.defaultValue, CameraOverlayPosition.topLeft.rawValue)
        XCTAssertEqual(Defaults.Keys.cameraPosition.defaultValue, "top_left")
        XCTAssertEqual(Defaults.Keys.cameraSize.defaultValue, CameraOverlaySize.small.rawValue)
        XCTAssertEqual(Defaults.Keys.cameraSize.defaultValue, "small")
        XCTAssertEqual(Defaults.Keys.cameraBorderEnabled.defaultValue, true)
        XCTAssertEqual(Defaults.Keys.cameraResolution.defaultValue, CameraCaptureResolution.hd720p30.rawValue)
        XCTAssertEqual(Defaults.Keys.cameraResolution.defaultValue, "720p30")
    }

    func testCameraEnumFallbacksOnGarbageRawValues() {
        withSavedCameraDefaults {
            Defaults[.cameraPosition] = "garbage"
            Defaults[.cameraSize] = "huge"
            Defaults[.cameraResolution] = "8k"
            XCTAssertEqual(AppSettings.cameraPositionEnum, .topLeft)
            XCTAssertEqual(AppSettings.cameraSizeEnum, .small)
            XCTAssertEqual(AppSettings.cameraResolutionEnum, .hd720p30)

            let layout = AppSettings.cameraOverlayLayout
            XCTAssertEqual(layout.position, .topLeft)
            XCTAssertEqual(layout.size, .small)
            XCTAssertEqual(layout.borderEnabled, true)
        }
    }

    func testCameraAccessorsReadDefaults() {
        withSavedCameraDefaults {
            Defaults[.cameraOverlayEnabled] = true
            Defaults[.cameraDeviceID] = "cam-1"
            Defaults[.cameraPosition] = CameraOverlayPosition.bottomRight.rawValue
            Defaults[.cameraSize] = CameraOverlaySize.large.rawValue
            Defaults[.cameraBorderEnabled] = false
            Defaults[.cameraResolution] = CameraCaptureResolution.hd1080p30.rawValue

            XCTAssertTrue(AppSettings.cameraOverlayEnabled)
            XCTAssertEqual(AppSettings.cameraDeviceID, "cam-1")
            XCTAssertEqual(AppSettings.cameraPositionEnum, .bottomRight)
            XCTAssertEqual(AppSettings.cameraSizeEnum, .large)
            XCTAssertFalse(AppSettings.cameraBorderEnabled)
            XCTAssertEqual(AppSettings.cameraResolutionEnum, .hd1080p30)
            XCTAssertEqual(
                AppSettings.cameraOverlayLayout,
                CameraOverlayLayout(position: .bottomRight, size: .large, borderEnabled: false)
            )
        }
    }

    func testCameraOverlayForcesSDR() {
        withSavedCameraDefaults {
            Defaults[.captureHDR] = true
            Defaults[.videoCodec] = "h264"
            Defaults[.captureMode] = CaptureMode.single.rawValue
            Defaults[.dualCaptureSaveMode] = DualCaptureSaveMode.sideBySide.rawValue

            Defaults[.cameraOverlayEnabled] = false
            XCTAssertEqual(AppSettings.isHDRCaptureActive, CaptureManager.supportsHDRCapture)

            Defaults[.cameraOverlayEnabled] = true
            XCTAssertFalse(AppSettings.isHDRCaptureActive)
            XCTAssertEqual(AppSettings.effectiveVideoCodec, "h264")

            Defaults[.cameraOverlayEnabled] = false
            XCTAssertEqual(AppSettings.effectiveVideoCodec,
                           CaptureManager.supportsHDRCapture ? "hevc" : "h264")
        }
    }

    func testCaptureProfileJSONRoundTripWithCameraFields() throws {
        var profile = profileMatchingCurrentDefaults()
        profile.cameraOverlayEnabled = true
        profile.cameraDeviceID = "cam-42"
        profile.cameraPosition = CameraOverlayPosition.topRight.rawValue
        profile.cameraSize = CameraOverlaySize.medium.rawValue
        profile.cameraBorderEnabled = false
        profile.cameraResolution = CameraCaptureResolution.hd1080p30.rawValue

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CaptureProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.cameraOverlayEnabled, true)
        XCTAssertEqual(decoded.cameraDeviceID, "cam-42")
        XCTAssertEqual(decoded.cameraPosition, "top_right")
        XCTAssertEqual(decoded.cameraSize, "medium")
        XCTAssertEqual(decoded.cameraBorderEnabled, false)
        XCTAssertEqual(decoded.cameraResolution, "1080p30")
    }

    func testCaptureProfileBackCompatWithoutCameraFields() throws {
        // Profiles saved before the camera overlay existed have no camera keys.
        let legacyJSON = """
        [{
            "id": "0B9A2F2E-1C4D-4E5F-8A9B-0C1D2E3F4A5B",
            "name": "Legacy",
            "createdAt": 700000000,
            "updatedAt": 700000000,
            "captureHDR": false,
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
            "memoryCapMB": 1536,
            "queueDepth": 5,
            "longBufferEnabled": false,
            "longBufferDurationMinutes": 5
        }]
        """
        let profiles = try JSONDecoder().decode([CaptureProfile].self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(profiles.count, 1)
        XCTAssertNil(profiles[0].cameraOverlayEnabled)
        XCTAssertNil(profiles[0].cameraDeviceID)
        XCTAssertNil(profiles[0].cameraPosition)
        XCTAssertNil(profiles[0].cameraSize)
        XCTAssertNil(profiles[0].cameraBorderEnabled)
        XCTAssertNil(profiles[0].cameraResolution)

        // Re-encoding must not invent camera keys.
        let reencoded = String(decoding: try JSONEncoder().encode(profiles), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("cameraOverlayEnabled"))
        XCTAssertFalse(reencoded.contains("cameraResolution"))
    }

    func testIsCaptureProfileActiveConsidersCameraFields() {
        withSavedCameraDefaults {
            Defaults[.cameraOverlayEnabled] = true
            Defaults[.cameraPosition] = CameraOverlayPosition.bottomLeft.rawValue

            var profile = profileMatchingCurrentDefaults()
            // Old profiles without camera fields stay active.
            XCTAssertTrue(AppSettings.isCaptureProfileActive(profile))

            profile.cameraOverlayEnabled = true
            profile.cameraPosition = CameraOverlayPosition.bottomLeft.rawValue
            XCTAssertTrue(AppSettings.isCaptureProfileActive(profile))

            profile.cameraOverlayEnabled = false
            XCTAssertFalse(AppSettings.isCaptureProfileActive(profile))

            profile.cameraOverlayEnabled = true
            profile.cameraPosition = CameraOverlayPosition.topLeft.rawValue
            XCTAssertFalse(AppSettings.isCaptureProfileActive(profile))
        }
    }

    func testApplyCaptureProfileAppliesCameraFields() {
        withSavedCameraDefaults {
            Defaults[.cameraOverlayEnabled] = false
            Defaults[.cameraDeviceID] = ""
            Defaults[.cameraPosition] = CameraOverlayPosition.topLeft.rawValue
            Defaults[.cameraSize] = CameraOverlaySize.small.rawValue
            Defaults[.cameraBorderEnabled] = true
            Defaults[.cameraResolution] = CameraCaptureResolution.hd720p30.rawValue

            var profile = profileMatchingCurrentDefaults()
            profile.cameraOverlayEnabled = true
            profile.cameraDeviceID = "cam-7"
            profile.cameraPosition = CameraOverlayPosition.topRight.rawValue
            profile.cameraSize = CameraOverlaySize.large.rawValue
            profile.cameraBorderEnabled = false
            profile.cameraResolution = CameraCaptureResolution.hd1080p30.rawValue
            Defaults[.captureProfilesJSON] = String(
                decoding: try! JSONEncoder().encode([profile]), as: UTF8.self
            )

            XCTAssertTrue(AppSettings.applyCaptureProfile(id: profile.id.uuidString))
            XCTAssertTrue(Defaults[.cameraOverlayEnabled])
            XCTAssertEqual(Defaults[.cameraDeviceID], "cam-7")
            XCTAssertEqual(Defaults[.cameraPosition], "top_right")
            XCTAssertEqual(Defaults[.cameraSize], "large")
            XCTAssertFalse(Defaults[.cameraBorderEnabled])
            XCTAssertEqual(Defaults[.cameraResolution], "1080p30")

            // A legacy profile without camera fields leaves them untouched.
            Defaults[.cameraOverlayEnabled] = false
            Defaults[.cameraDeviceID] = "keep-me"
            let legacy = profileMatchingCurrentDefaults()
            Defaults[.captureProfilesJSON] = String(
                decoding: try! JSONEncoder().encode([legacy]), as: UTF8.self
            )
            XCTAssertTrue(AppSettings.applyCaptureProfile(id: legacy.id.uuidString))
            XCTAssertFalse(Defaults[.cameraOverlayEnabled])
            XCTAssertEqual(Defaults[.cameraDeviceID], "keep-me")
        }
    }

    private func profileMatchingCurrentDefaults() -> CaptureProfile {
        CaptureProfile(
            id: UUID(),
            name: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            captureHDR: Defaults[.captureHDR],
            videoCodecRawValue: Defaults[.videoCodec],
            captureModeRawValue: Defaults[.captureMode],
            captureDisplayID: Defaults[.captureDisplayID],
            captureDisplayID2: Defaults[.captureDisplayID2],
            captureDisplayPriorities: Defaults[.captureDisplayPriorities],
            dualCaptureSaveModeRawValue: Defaults[.dualCaptureSaveMode],
            captureResolutionRawValue: Defaults[.captureResolution],
            customCaptureWidth: Defaults[.customCaptureWidth],
            customCaptureHeight: Defaults[.customCaptureHeight],
            frameRate: Defaults[.frameRate],
            bitrateMbps: Defaults[.bitrateMbps],
            qualityPresetRawValue: Defaults[.qualityPreset],
            captureSystemAudio: Defaults[.captureSystemAudio],
            captureMicrophone: Defaults[.captureMicrophone],
            mergeAudioTracks: Defaults[.mergeAudioTracks],
            microphoneID: Defaults[.microphoneID],
            excludeOwnAppAudio: Defaults[.excludeOwnAppAudio],
            perAppAudioEnabled: Defaults[.perAppAudioEnabled],
            perAppAudioBundleID: Defaults[.perAppAudioBundleID],
            mutedAudioAppBundleIDs: Defaults[.mutedAudioAppBundleIDs],
            systemAudioVolume: Defaults[.systemAudioVolume],
            microphoneVolume: Defaults[.microphoneVolume],
            memoryCapMB: Defaults[.memoryCapMB],
            queueDepth: Defaults[.queueDepth],
            longBufferEnabled: Defaults[.longBufferEnabled],
            longBufferDurationMinutes: Defaults[.longBufferDurationMinutes]
        )
    }
}
