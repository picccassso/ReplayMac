import XCTest
import Defaults
@testable import UI

final class DisplayPrioritySettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Defaults[.captureDisplayID] = ""
        Defaults[.captureDisplayID2] = ""
        Defaults[.captureDisplayPriorities] = []
    }

    override func tearDown() {
        Defaults[.captureDisplayID] = ""
        Defaults[.captureDisplayID2] = ""
        Defaults[.captureDisplayPriorities] = []
        super.tearDown()
    }

    func testCaptureDisplayPrioritiesFallsBackToCaptureDisplayID() {
        Defaults[.captureDisplayID] = "builtin:main"
        Defaults[.captureDisplayPriorities] = []

        XCTAssertEqual(AppSettings.captureDisplayPriorities, ["builtin:main"])
    }

    func testCaptureDisplayPrioritiesUsesStoredListWhenPresent() {
        Defaults[.captureDisplayID] = "builtin:main"
        Defaults[.captureDisplayPriorities] = ["edid:111:222:333", "builtin:main"]

        XCTAssertEqual(AppSettings.captureDisplayPriorities, ["edid:111:222:333", "builtin:main"])
    }

    func testCaptureDisplayPrioritiesReturnsEmptyWhenBothUnset() {
        Defaults[.captureDisplayID] = ""
        Defaults[.captureDisplayPriorities] = []

        XCTAssertEqual(AppSettings.captureDisplayPriorities, [])
    }

    func testCaptureProfileCodableWithAndWithoutPriorities() throws {
        // Legacy JSON without captureDisplayPriorities
        let legacyJSON = """
        {
            "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "name": "Legacy Profile",
            "createdAt": 0,
            "updatedAt": 0,
            "videoCodecRawValue": "hevc",
            "captureModeRawValue": "single",
            "captureDisplayID": "builtin:main",
            "captureDisplayID2": "",
            "dualCaptureSaveModeRawValue": "sideBySide",
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
        }
        """

        let decoder = JSONDecoder()
        let decodedLegacy = try decoder.decode(CaptureProfile.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decodedLegacy.captureDisplayID, "builtin:main")
        XCTAssertEqual(decodedLegacy.captureDisplayPriorities ?? [], [])

        // New profile with priorities
        var newProfile = decodedLegacy
        newProfile.captureDisplayPriorities = ["edid:999:888:777", "builtin:main"]

        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(newProfile)
        let roundTripped = try decoder.decode(CaptureProfile.self, from: encodedData)
        XCTAssertEqual(roundTripped.captureDisplayPriorities, ["edid:999:888:777", "builtin:main"])
    }
}
