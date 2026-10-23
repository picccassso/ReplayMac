import AppKit
import CompanionServer
import Defaults
import XCTest
@testable import UI

final class CompanionUITests: XCTestCase {
    @MainActor
    func testSelectingCompanionPageSetsSettingsTab() {
        let name = "CompanionUITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let state = MainWindowState(defaults: defaults)
        XCTAssertEqual(state.page, .home)
        XCTAssertFalse(state.hasVisitedSettings)

        state.select(.companion)
        XCTAssertEqual(state.page, .companion)
        XCTAssertEqual(state.settingsTab, .companion)
        XCTAssertTrue(state.hasVisitedSettings)
        XCTAssertTrue(state.isSettingsPage)
    }

    @MainActor
    func testCompanionServerConnectionStateTracking() {
        let name = "CompanionUITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let pairing = CompanionPairingManager(defaults: defaults, secretStore: InMemoryPairingSecretStore())
        let server = CompanionServer(pairingManager: pairing, defaults: defaults)

        XCTAssertEqual(server.connectedClientsCount, 0)
        XCTAssertTrue(server.connectedDeviceIds.isEmpty)
        XCTAssertFalse(server.isDeviceConnected(id: "dev-1"))
    }

    @MainActor
    func testCompanionPairingDeviceResolution() {
        let name = "CompanionUITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let pairing = CompanionPairingManager(defaults: defaults, secretStore: InMemoryPairingSecretStore())
        pairing.approveDevice(id: "phone-1", name: "Alex's iPhone")

        let device = pairing.device(for: "phone-1")
        XCTAssertNotNil(device)
        XCTAssertEqual(device?.name, "Alex's iPhone")
    }

    func testCompanionVolumeClampingAndProfileApplication() throws {
        let originalSysVol = Defaults[.systemAudioVolume]
        let originalMicVol = Defaults[.microphoneVolume]
        let originalProfilesJSON = Defaults[.captureProfilesJSON]
        let originalFrameRate = Defaults[.frameRate]
        let originalBitrate = Defaults[.bitrateMbps]
        defer {
            Defaults[.systemAudioVolume] = originalSysVol
            Defaults[.microphoneVolume] = originalMicVol
            Defaults[.captureProfilesJSON] = originalProfilesJSON
            Defaults[.frameRate] = originalFrameRate
            Defaults[.bitrateMbps] = originalBitrate
        }

        AppSettings.setSystemAudioVolume(1.5)
        XCTAssertEqual(AppSettings.systemAudioVolume, 1.0, accuracy: 0.001)
        AppSettings.setSystemAudioVolume(-0.2)
        XCTAssertEqual(AppSettings.systemAudioVolume, 0.0, accuracy: 0.001)
        AppSettings.setMicrophoneVolume(0.65)
        XCTAssertEqual(AppSettings.microphoneVolume, 0.65, accuracy: 0.001)

        let profileId = UUID()
        let profile = CaptureProfile(
            id: profileId,
            name: "Companion Test Profile",
            createdAt: Date(),
            updatedAt: Date(),
            captureHDR: false,
            videoCodecRawValue: "hevc",
            captureModeRawValue: "single",
            captureDisplayID: "",
            captureDisplayID2: "",
            captureDisplayPriorities: [],
            dualCaptureSaveModeRawValue: "side_by_side",
            captureResolutionRawValue: "native",
            customCaptureWidth: 1920,
            customCaptureHeight: 1080,
            frameRate: 120,
            bitrateMbps: 42.0,
            qualityPresetRawValue: "custom",
            captureSystemAudio: true,
            captureMicrophone: true,
            mergeAudioTracks: true,
            microphoneID: "",
            excludeOwnAppAudio: true,
            perAppAudioEnabled: false,
            perAppAudioBundleID: "",
            mutedAudioAppBundleIDs: ["com.hnc.Discord"],
            systemAudioVolume: 0.75,
            microphoneVolume: 0.55,
            memoryCapMB: 1536,
            queueDepth: 5,
            longBufferEnabled: true,
            longBufferDurationMinutes: 10
        )

        let data = try JSONEncoder().encode([profile])
        Defaults[.captureProfilesJSON] = String(decoding: data, as: UTF8.self)

        let loaded = AppSettings.loadCaptureProfiles()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, profileId)

        XCTAssertTrue(AppSettings.applyCaptureProfile(id: profileId.uuidString))
        XCTAssertEqual(AppSettings.frameRate, 120)
        XCTAssertEqual(AppSettings.bitrateMbps, 42.0, accuracy: 0.01)
        XCTAssertEqual(AppSettings.systemAudioVolume, 0.75, accuracy: 0.01)
        XCTAssertEqual(AppSettings.microphoneVolume, 0.55, accuracy: 0.01)
        XCTAssertEqual(AppSettings.mutedAudioAppBundleIDs, ["com.hnc.Discord"])
        XCTAssertTrue(AppSettings.isCaptureProfileActive(profile))
    }
}
