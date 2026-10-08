import XCTest
@testable import CompanionServer

final class CompanionServerProtocolTests: XCTestCase {
    func testClientHelloDecoding() throws {
        let json = """
        {
            "type": "hello",
            "deviceId": "test-device-123",
            "deviceName": "Pixel 8 Pro",
            "clientVersion": "1.0.0"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(CompanionClientMessage.self, from: json)
        XCTAssertEqual(message.type, "hello")
        XCTAssertEqual(message.deviceId, "test-device-123")
        XCTAssertEqual(message.deviceName, "Pixel 8 Pro")
        XCTAssertEqual(message.clientVersion, "1.0.0")
    }

    func testClientActionDecoding() throws {
        let json = """
        {
            "type": "action",
            "action": "saveReplay"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(CompanionClientMessage.self, from: json)
        XCTAssertEqual(message.type, "action")
        XCTAssertEqual(message.action, "saveReplay")
        XCTAssertEqual(CompanionClientAction(rawValue: message.action!), .saveReplay)
    }

    func testClientThumbnailRequestDecoding() throws {
        let json = """
        {
            "type": "get_thumbnail",
            "clipId": "1234-5678-uuid"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(CompanionClientMessage.self, from: json)
        XCTAssertEqual(message.type, "get_thumbnail")
        XCTAssertEqual(message.clipId, "1234-5678-uuid")
    }

    func testServerStateSnapshotEncoding() throws {
        let clip = CompanionClipSummary(
            id: "uuid-1",
            filename: "Replay_test.mp4",
            kind: "replay",
            savedAt: 1728394800,
            duration: 30.0,
            fileSize: 1024000,
            hasThumbnail: true
        )

        let snapshot = CompanionStateSnapshot(
            isRecording: true,
            isSessionRecording: false,
            saveStatus: "idle",
            recordingElapsedSeconds: 15.0,
            extendedBufferElapsedSeconds: 15.0,
            sessionElapsedSeconds: 0,
            bufferedSeconds: 15.0,
            bufferDurationSeconds: 30,
            bufferMemoryBytes: 52428800,
            bufferMemoryFormatted: "50 MB",
            longBufferEnabled: true,
            longBufferDurationSeconds: 300,
            capturedDisplayName: "Built-in Display",
            isMicrophoneEnabled: true,
            isMicrophoneMuted: false,
            isSystemAudioEnabled: true,
            isSystemAudioMuted: false,
            recentClips: [clip]
        )

        let data = try JSONEncoder().encode(snapshot)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["type"] as? String, "state_snapshot")
        XCTAssertEqual(dict?["isRecording"] as? Bool, true)
        XCTAssertEqual(dict?["saveStatus"] as? String, "idle")
        XCTAssertEqual(dict?["bufferDurationSeconds"] as? Int, 30)
        XCTAssertEqual(dict?["bufferMemoryFormatted"] as? String, "50 MB")

        let clipsArray = dict?["recentClips"] as? [[String: Any]]
        XCTAssertEqual(clipsArray?.count, 1)
        XCTAssertEqual(clipsArray?.first?["filename"] as? String, "Replay_test.mp4")
        XCTAssertEqual(clipsArray?.first?["hasThumbnail"] as? Bool, true)
    }

    func testServerTelemetryTickEncoding() throws {
        let tick = CompanionTelemetryTick(
            recordingElapsedSeconds: 22.0,
            extendedBufferElapsedSeconds: 22.0,
            sessionElapsedSeconds: 0,
            bufferedSeconds: 22.0,
            bufferMemoryBytes: 60000000,
            bufferMemoryFormatted: "57 MB"
        )

        let data = try JSONEncoder().encode(tick)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["type"] as? String, "telemetry_tick")
        XCTAssertEqual(dict?["recordingElapsedSeconds"] as? Double, 22.0)
        XCTAssertEqual(dict?["bufferedSeconds"] as? Double, 22.0)
    }

    func testServerAuthResponseEncoding() throws {
        let auth = CompanionAuthResponse(status: "approved", serverName: "Alex Mac", serverVersion: "1.7.3")
        let data = try JSONEncoder().encode(auth)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["type"] as? String, "auth_response")
        XCTAssertEqual(dict?["status"] as? String, "approved")
        XCTAssertEqual(dict?["serverName"] as? String, "Alex Mac")
    }

    func testThumbnailResponseEncoding() throws {
        let resp = CompanionThumbnailResponse(clipId: "test-clip", thumbnailBase64: "dGVzdA==")
        let data = try JSONEncoder().encode(resp)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["type"] as? String, "thumbnail_response")
        XCTAssertEqual(dict?["clipId"] as? String, "test-clip")
        XCTAssertEqual(dict?["thumbnailBase64"] as? String, "dGVzdA==")
    }
}

@MainActor
final class CompanionPairingManagerTests: XCTestCase {
    var userDefaults: UserDefaults!
    var pairingManager: CompanionPairingManager!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "CompanionPairingTests-\(UUID().uuidString)")!
        pairingManager = CompanionPairingManager(defaults: userDefaults)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: userDefaults.description)
        super.tearDown()
    }

    func testApproveAndCheckDevice() {
        XCTAssertFalse(pairingManager.isDeviceApproved(id: "dev-1"))
        pairingManager.approveDevice(id: "dev-1", name: "Pixel Tablet")
        XCTAssertTrue(pairingManager.isDeviceApproved(id: "dev-1"))
        XCTAssertEqual(pairingManager.pairedDevices.count, 1)
        XCTAssertEqual(pairingManager.pairedDevices.first?.name, "Pixel Tablet")
    }

    func testRevokeDevice() {
        pairingManager.approveDevice(id: "dev-1", name: "Device 1")
        pairingManager.approveDevice(id: "dev-2", name: "Device 2")
        XCTAssertEqual(pairingManager.pairedDevices.count, 2)

        var revokedCalled = false
        pairingManager.onDeviceRevoked = { id in
            if id == "dev-1" { revokedCalled = true }
        }

        pairingManager.revokeDevice(id: "dev-1")
        XCTAssertFalse(pairingManager.isDeviceApproved(id: "dev-1"))
        XCTAssertTrue(pairingManager.isDeviceApproved(id: "dev-2"))
        XCTAssertTrue(revokedCalled)
    }

    func testRevokeAllDevices() {
        pairingManager.approveDevice(id: "dev-1", name: "Device 1")
        pairingManager.approveDevice(id: "dev-2", name: "Device 2")

        var revokedCount = 0
        pairingManager.onDeviceRevoked = { _ in revokedCount += 1 }

        pairingManager.revokeAllDevices()
        XCTAssertTrue(pairingManager.pairedDevices.isEmpty)
        XCTAssertEqual(revokedCount, 2)
    }

    func testPromptApprovalHandlerAllowed() async {
        pairingManager.promptHandler = { id, name in
            return true
        }

        let result = await pairingManager.promptApprovalForDevice(id: "dev-new", name: "Galaxy S24")
        XCTAssertTrue(result)
        XCTAssertTrue(pairingManager.isDeviceApproved(id: "dev-new"))
    }

    func testPromptApprovalHandlerDenied() async {
        pairingManager.promptHandler = { id, name in
            return false
        }

        let result = await pairingManager.promptApprovalForDevice(id: "dev-denied", name: "Unknown")
        XCTAssertFalse(result)
        XCTAssertFalse(pairingManager.isDeviceApproved(id: "dev-denied"))
    }
}

@MainActor
final class CompanionServerLifecycleTests: XCTestCase {
    func testServerStartAndStop() throws {
        let server = CompanionServer()
        XCTAssertFalse(server.isRunning)

        // Start on test port 7380
        try server.start(port: 7380)
        XCTAssertEqual(server.listeningPort, 7380)

        server.stop()
        XCTAssertFalse(server.isRunning)
    }

    func testIPResolutionNonEmpty() {
        let ips = CompanionServer.resolveLocalIPAddresses()
        XCTAssertFalse(ips.isEmpty)
    }
}
