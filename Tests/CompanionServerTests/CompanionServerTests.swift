import XCTest
@testable import CompanionServer

final class CompanionServerProtocolTests: XCTestCase {
    func testClientHelloDecoding() throws {
        let json = """
        {
            "type": "hello",
            "deviceId": "test-device-123",
            "deviceName": "Pixel 8 Pro",
            "clientVersion": "1.0.0",
            "protocolVersion": 2
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(CompanionClientMessage.self, from: json)
        XCTAssertEqual(message.type, "hello")
        XCTAssertEqual(message.protocolVersion, 2)
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

    func testExtendedStateSnapshotRoundTripAndDefaults() throws {
        let app = CompanionAudioApp(bundleId: "com.hnc.Discord", name: "Discord", isMuted: true, isRunning: true)
        let display = CompanionDisplayInfo(id: "builtin:main", name: "Built-in Display", isActive: true, isConnected: true)
        let profile = CompanionProfileSummary(id: "prof-1", name: "Gaming", summary: "120 fps · 35 Mbps", isActive: true)

        let snapshot = CompanionStateSnapshot(
            isRecording: true,
            isSessionRecording: false,
            saveStatus: "idle",
            recordingElapsedSeconds: 10,
            extendedBufferElapsedSeconds: 10,
            sessionElapsedSeconds: 0,
            bufferedSeconds: 10,
            bufferDurationSeconds: 30,
            bufferMemoryBytes: 1024,
            bufferMemoryFormatted: "1 KB",
            longBufferEnabled: false,
            longBufferDurationSeconds: 300,
            capturedDisplayName: "Built-in Display",
            isMicrophoneEnabled: true,
            isMicrophoneMuted: false,
            isSystemAudioEnabled: true,
            isSystemAudioMuted: false,
            microphoneVolume: 0.8,
            systemAudioVolume: 0.65,
            perAppAudioEnabled: false,
            audioApps: [app],
            displays: [display],
            profiles: [profile],
            recentClips: []
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CompanionStateSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.microphoneVolume, 0.8, accuracy: 0.001)
        XCTAssertEqual(decoded.systemAudioVolume, 0.65, accuracy: 0.001)
        XCTAssertFalse(decoded.perAppAudioEnabled)
        XCTAssertEqual(decoded.audioApps, [app])
        XCTAssertEqual(decoded.displays, [display])
        XCTAssertEqual(decoded.profiles, [profile])

        // Legacy payload without new fields decodes with sensible defaults
        let legacyJSON = """
        {
            "type": "state_snapshot",
            "isRecording": false,
            "isSessionRecording": false,
            "saveStatus": "idle"
        }
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(CompanionStateSnapshot.self, from: legacyJSON)
        XCTAssertEqual(legacy.microphoneVolume, 1.0)
        XCTAssertEqual(legacy.systemAudioVolume, 1.0)
        XCTAssertFalse(legacy.perAppAudioEnabled)
        XCTAssertTrue(legacy.audioApps.isEmpty)
        XCTAssertTrue(legacy.displays.isEmpty)
        XCTAssertTrue(legacy.profiles.isEmpty)
    }
}

@MainActor
final class CompanionPairingManagerTests: XCTestCase {
    var userDefaults: UserDefaults!
    var pairingManager: CompanionPairingManager!
    var secretStore: InMemoryPairingSecretStore!

    override func setUp() async throws {
        try await super.setUp()
        userDefaults = UserDefaults(suiteName: "CompanionPairingTests-\(UUID().uuidString)")!
        secretStore = InMemoryPairingSecretStore()
        pairingManager = CompanionPairingManager(defaults: userDefaults, secretStore: secretStore)
    }

    override func tearDown() async throws {
        userDefaults?.removePersistentDomain(forName: userDefaults.description)
        try await super.tearDown()
    }

    func testApproveAndCheckDevice() {
        XCTAssertFalse(pairingManager.isDeviceApproved(id: "dev-1"))
        pairingManager.approveDevice(id: "dev-1", name: "Pixel Tablet")
        XCTAssertTrue(pairingManager.isDeviceApproved(id: "dev-1"))
        XCTAssertEqual(pairingManager.pairedDevices.count, 1)
        XCTAssertEqual(pairingManager.pairedDevices.first?.name, "Pixel Tablet")
    }

    func testApproveDeviceUpdatesName() {
        pairingManager.approveDevice(id: "dev-1", name: "Old Name")
        XCTAssertEqual(pairingManager.pairedDevices.first?.name, "Old Name")
        pairingManager.approveDevice(id: "dev-1", name: "New Name")
        XCTAssertEqual(pairingManager.pairedDevices.first?.name, "New Name")
        XCTAssertEqual(pairingManager.pairedDevices.count, 1)
    }

    func testRenameDeviceAndPreserveCustomName() {
        pairingManager.approveDevice(id: "dev-1", name: "Hardware Name")
        XCTAssertEqual(pairingManager.pairedDevices.first?.name, "Hardware Name")

        var renamedId: String?
        var renamedNewName: String?
        pairingManager.onDeviceRenamed = { id, name in
            renamedId = id
            renamedNewName = name
        }

        pairingManager.renameDevice(id: "dev-1", newName: "My Custom Phone")
        XCTAssertEqual(pairingManager.pairedDevices.first?.name, "My Custom Phone")
        XCTAssertEqual(renamedId, "dev-1")
        XCTAssertEqual(renamedNewName, "My Custom Phone")

        // Reconnect with hardware name does not overwrite custom name
        pairingManager.approveDevice(id: "dev-1", name: "Hardware Name")
        XCTAssertEqual(pairingManager.pairedDevices.first?.name, "My Custom Phone")
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

    func testApprovingIssuesAFreshSecretEachTime() {
        XCTAssertNil(pairingManager.secret(for: "dev-1"))
        let first = pairingManager.approveDevice(id: "dev-1", name: "Phone")
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(pairingManager.secret(for: "dev-1"), first)

        let second = pairingManager.approveDevice(id: "dev-1", name: "Phone")
        XCTAssertNotEqual(first, second, "Re-pairing must invalidate the old secret")
        XCTAssertEqual(pairingManager.secret(for: "dev-1"), second)
    }

    func testSecretsSurviveRelaunchAndRevokeRemovesThem() {
        let secret = pairingManager.approveDevice(id: "dev-1", name: "Phone")
        XCTAssertEqual(CompanionPairingManager(defaults: userDefaults, secretStore: secretStore).secret(for: "dev-1"), secret)

        pairingManager.revokeDevice(id: "dev-1")
        XCTAssertNil(pairingManager.secret(for: "dev-1"))
        XCTAssertNil(CompanionPairingManager(defaults: userDefaults, secretStore: secretStore).secret(for: "dev-1"))
    }

    // MARK: - Keychain migration

    private struct StoreFailure: Error {}

    func testSecretsAreSavedToTheStoreNotUserDefaults() {
        let secret = pairingManager.approveDevice(id: "dev-1", name: "Phone")
        XCTAssertEqual(secretStore.storedSecrets?["dev-1"], secret.base64EncodedString())
        XCTAssertNil(userDefaults.object(forKey: CompanionPairingManager.secretsDefaultsKey))
    }

    func testLegacySecretsMoveToStoreAndOldKeyIsRemoved() {
        let defaults = UserDefaults(suiteName: "CompanionPairingMigration-\(UUID().uuidString)")!
        let secret = Data(repeating: 7, count: 32)
        seedLegacyPairing(in: defaults, id: "dev-1", secret: secret)

        let store = InMemoryPairingSecretStore()
        let manager = CompanionPairingManager(defaults: defaults, secretStore: store)

        XCTAssertEqual(manager.secret(for: "dev-1"), secret, "Phones paired before the move keep working")
        XCTAssertEqual(store.storedSecrets?["dev-1"], secret.base64EncodedString())
        XCTAssertNil(defaults.object(forKey: CompanionPairingManager.secretsDefaultsKey))
    }

    func testFailedStoreWriteKeepsLegacySecrets() {
        let defaults = UserDefaults(suiteName: "CompanionPairingMigration-\(UUID().uuidString)")!
        let secret = Data(repeating: 9, count: 32)
        seedLegacyPairing(in: defaults, id: "dev-1", secret: secret)

        let store = InMemoryPairingSecretStore()
        store.saveError = StoreFailure()
        let manager = CompanionPairingManager(defaults: defaults, secretStore: store)

        XCTAssertEqual(manager.secret(for: "dev-1"), secret)
        XCTAssertNil(store.storedSecrets)
        XCTAssertEqual(
            defaults.dictionary(forKey: CompanionPairingManager.secretsDefaultsKey) as? [String: String],
            ["dev-1": secret.base64EncodedString()],
            "The old key must survive until the store has the secrets"
        )

        // A later save that also fails still keeps every secret recoverable.
        let second = manager.approveDevice(id: "dev-2", name: "Tablet")
        let fallback = defaults.dictionary(forKey: CompanionPairingManager.secretsDefaultsKey) as? [String: String]
        XCTAssertEqual(fallback?["dev-2"], second.base64EncodedString())

        // Once the store works again the next launch moves everything over.
        store.saveError = nil
        let relaunched = CompanionPairingManager(defaults: defaults, secretStore: store)
        XCTAssertEqual(relaunched.secret(for: "dev-1"), secret)
        XCTAssertEqual(relaunched.secret(for: "dev-2"), second)
        XCTAssertNil(defaults.object(forKey: CompanionPairingManager.secretsDefaultsKey))
    }

    func testCustomDefaultsNeverUseTheKeychain() {
        let defaults = UserDefaults(suiteName: "CompanionPairingMigration-\(UUID().uuidString)")!
        let manager = CompanionPairingManager(defaults: defaults)
        XCTAssertTrue(manager.secretStore is InMemoryPairingSecretStore)
        let secret = manager.approveDevice(id: "dev-1", name: "Phone")
        XCTAssertEqual(manager.secret(for: "dev-1"), secret)
        XCTAssertNil(defaults.object(forKey: CompanionPairingManager.secretsDefaultsKey))
    }

    private func seedLegacyPairing(in defaults: UserDefaults, id: String, secret: Data) {
        let devices = [PairedDevice(id: id, name: "Phone")]
        defaults.set(try! JSONEncoder().encode(devices), forKey: CompanionPairingManager.userDefaultsKey)
        defaults.set([id: secret.base64EncodedString()], forKey: CompanionPairingManager.secretsDefaultsKey)
    }

    func testPromptHandlerReceivesCodeAndDecides() async {
        var seen: (String, String, String)?
        pairingManager.promptHandler = { id, name, code in
            seen = (id, name, code)
            return true
        }

        let result = await pairingManager.requestApproval(id: "dev-new", name: "Galaxy S24", code: "0420")
        XCTAssertEqual(result, .approved)
        XCTAssertEqual(seen?.0, "dev-new")
        XCTAssertEqual(seen?.1, "Galaxy S24")
        XCTAssertEqual(seen?.2, "0420")
        XCTAssertFalse(pairingManager.isDeviceApproved(id: "dev-new"), "Approval alone must not pair")
        XCTAssertFalse(pairingManager.isPromptActive)
    }

    func testPromptDenied() async {
        pairingManager.promptHandler = { _, _, _ in false }
        let result = await pairingManager.requestApproval(id: "dev-denied", name: "Unknown", code: "1111")
        XCTAssertEqual(result, .denied)
        XCTAssertFalse(pairingManager.isDeviceApproved(id: "dev-denied"))
    }

    func testPromptTimesOut() async {
        pairingManager.promptTimeout = 0.1
        pairingManager.promptHandler = { _, _, _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return true
        }
        let result = await pairingManager.requestApproval(id: "dev-slow", name: "Phone", code: "1234")
        XCTAssertEqual(result, .timedOut)
        XCTAssertFalse(pairingManager.isPromptActive)
    }

    func testOnlyOnePromptAtATime() async {
        pairingManager.promptHandler = { _, _, _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return true
        }
        let manager: CompanionPairingManager = pairingManager
        async let first = manager.requestApproval(id: "phone-a", name: "Phone A", code: "1111")
        try? await Task.sleep(nanoseconds: 20_000_000)
        let second = await manager.requestApproval(id: "phone-b", name: "Phone B", code: "2222")

        XCTAssertEqual(second, .cancelled)
        let firstResult = await first
        XCTAssertEqual(firstResult, .approved)
    }

    func testCancelPromptDismissesIt() async {
        pairingManager.promptHandler = { _, _, _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return true
        }
        let manager: CompanionPairingManager = pairingManager
        async let result = manager.requestApproval(id: "phone-a", name: "Phone A", code: "1111")
        try? await Task.sleep(nanoseconds: 20_000_000)
        manager.cancelPrompt(for: "someone-else")
        XCTAssertTrue(manager.isPromptActive)
        manager.cancelPrompt(for: "phone-a")
        let outcome = await result
        XCTAssertEqual(outcome, .cancelled)
    }
}

@MainActor
final class CompanionServerLifecycleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var pairing: CompanionPairingManager!

    override func setUp() async throws {
        try await super.setUp()
        defaults = makeTestDefaults()
        pairing = CompanionPairingManager(defaults: defaults, secretStore: InMemoryPairingSecretStore())
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaults.description)
        try await super.tearDown()
    }

    func testServerStartAndStop() throws {
        let server = CompanionServer(pairingManager: pairing, defaults: defaults)
        XCTAssertFalse(server.isRunning)

        try server.start(port: 7380)
        XCTAssertEqual(server.listeningPort, 7380)
        XCTAssertNil(server.lastError)

        server.stop()
        XCTAssertFalse(server.isRunning)
    }

    func testPortInUseIsReported() async throws {
        let first = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { first.stop() }

        let second = CompanionServer(pairingManager: CompanionPairingManager(defaults: makeTestDefaults(), secretStore: InMemoryPairingSecretStore()), defaults: makeTestDefaults())
        try? second.start(port: first.listeningPort)
        try await waitUntil { second.lastError != nil }
        XCTAssertFalse(second.isRunning)
        XCTAssertTrue(second.lastError?.contains("already in use") == true, second.lastError ?? "")
    }

    func testIPResolutionNonEmpty() {
        let ips = CompanionServer.resolveLocalIPAddresses()
        XCTAssertFalse(ips.isEmpty)
    }

    func testEndToEndSignInAndAction() async throws {
        let secret = pairing.approveDevice(id: "test-device-1", name: "Pixel 8")
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }
        var actionReceived = false
        server.onToggleBuffer = { actionReceived = true }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "test-device-1")
        let auth = try await client.signIn(secret: secret)
        XCTAssertEqual(auth.status, "approved")
        XCTAssertNil(auth.pairingSecret, "The secret is only sent when pairing")
        let snapshot = try await client.receive(CompanionStateSnapshot.self)
        XCTAssertEqual(snapshot.type, "state_snapshot")

        try await client.send(CompanionClientMessage(type: "action", action: "toggleBuffer"))
        try await waitUntil { actionReceived }
        XCTAssertEqual(server.connectedClientsCount, 1)

        client.close()
        try await waitUntil { server.connectedClientsCount == 0 }
    }

    func testClipActionsAndThumbnail() async throws {
        let secret = pairing.approveDevice(id: "test-device-1", name: "Pixel 8")
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }
        var revealedId: String?
        var deletedId: String?
        server.onRevealClip = { revealedId = $0 }
        server.onDeleteClip = { deletedId = $0 }
        server.onGetThumbnail = { _ in Data("sample-thumb-bytes".utf8) }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "test-device-1")
        defer { client.close() }
        _ = try await client.signIn(secret: secret)
        _ = try await client.receiveData() // snapshot

        try await client.send(CompanionClientMessage(type: "action", action: "reveal_clip", clipId: "clip-123"))
        try await client.send(CompanionClientMessage(type: "delete_clip", clipId: "clip-del-999"))
        try await waitUntil { revealedId != nil && deletedId != nil }
        XCTAssertEqual(revealedId, "clip-123")
        XCTAssertEqual(deletedId, "clip-del-999")

        try await client.send(CompanionClientMessage(type: "get_thumbnail", clipId: "clip-thumb-1"))
        let thumb = try await client.receive(CompanionThumbnailResponse.self)
        XCTAssertEqual(thumb.clipId, "clip-thumb-1")
        XCTAssertEqual(thumb.thumbnailBase64, Data("sample-thumb-bytes".utf8).base64EncodedString())
    }

    func testNewDevicePairsWithCodeAndReceivesSecret() async throws {
        var promptedCode: String?
        pairing.promptHandler = { _, _, code in
            promptedCode = code
            return true
        }
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "unapproved-dev", deviceName: "Galaxy")
        defer { client.close() }
        try await client.sendHello()

        let pending = try await client.receive(CompanionAuthResponse.self)
        XCTAssertEqual(pending.status, "pending")
        XCTAssertEqual(pending.pairingCode?.count, 4)

        let approved = try await client.receive(CompanionAuthResponse.self)
        XCTAssertEqual(approved.status, "approved")
        XCTAssertEqual(promptedCode, pending.pairingCode, "Phone and Mac must show the same code")
        let secret = try XCTUnwrap(approved.pairingSecret.flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(secret, pairing.secret(for: "unapproved-dev"))
        do {
            let received = try await client.receiveType()
            XCTAssertEqual(received, "state_snapshot")
        }

        // The secret works for the next connection, with no prompt.
        pairing.promptHandler = { _, _, _ in
            XCTFail("A paired phone must not prompt again")
            return false
        }
        let again = CompanionTestClient(port: server.listeningPort, deviceId: "unapproved-dev", deviceName: "Galaxy")
        defer { again.close() }
        let auth = try await again.signIn(secret: secret)
        XCTAssertEqual(auth.status, "approved")
    }

    func testWrongProofIsDeniedAndDoesNotKickTheRealPhone() async throws {
        let secret = pairing.approveDevice(id: "phone-1", name: "Real Phone")
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let realPhone = CompanionTestClient(port: server.listeningPort, deviceId: "phone-1")
        defer { realPhone.close() }
        do {
            let received = try await realPhone.signIn(secret: secret).status
            XCTAssertEqual(received, "approved")
        }
        try await waitUntil { server.connectedClientsCount == 1 }

        // Someone who sniffed the device id but has no secret.
        let impostor = CompanionTestClient(port: server.listeningPort, deviceId: "phone-1")
        let verdict = try await impostor.signIn(secret: Data(repeating: 7, count: 32))
        XCTAssertEqual(verdict.status, "denied")
        XCTAssertEqual(verdict.reason, "invalid_proof")
        let closed = await impostor.isClosedByServer()
        XCTAssertTrue(closed)

        XCTAssertEqual(server.connectedClientsCount, 1, "The real phone must stay connected")
        XCTAssertTrue(pairing.isDeviceApproved(id: "phone-1"), "A failed attempt must not unpair the real phone")
    }

    func testUnauthorizedActionRejected() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }
        var actionRun = false
        server.onToggleBuffer = { actionRun = true }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "nobody")
        defer { client.close() }
        try await client.send(CompanionClientMessage(type: "action", action: "toggleBuffer"))

        let error = try await client.receive(CompanionErrorMessage.self)
        XCTAssertEqual(error.message, "Device not authorized")
        XCTAssertEqual(error.code, "not_authorized")
        XCTAssertFalse(actionRun)
    }

    func testConnectedDeviceIdsTrackedOnSignInAndDisconnect() async throws {
        let secret = pairing.approveDevice(id: "dev-tracking-1", name: "Pixel 8 Pro")
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }
        XCTAssertFalse(server.isDeviceConnected(id: "dev-tracking-1"))

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "dev-tracking-1")
        _ = try await client.signIn(secret: secret)
        try await waitUntil { server.isDeviceConnected(id: "dev-tracking-1") }

        client.close()
        try await waitUntil { !server.isDeviceConnected(id: "dev-tracking-1") }
    }

    func testExtendedClipAudioAndSetupActions() async throws {
        let secret = pairing.approveDevice(id: "test-device-ext", name: "iPhone 16 Pro")
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        var trimmedId: String?
        var copiedId: String?
        var receivedVolume: (String, Double)?
        var toggledBundleId: String?
        var unmutedAll = false
        var selectedDisplayId: String?
        var appliedProfileId: String?

        server.onTrimClip = { trimmedId = $0 }
        server.onCopyClip = { copiedId = $0 }
        server.onSetVolume = { receivedVolume = ($0, $1) }
        server.onToggleAppMute = { toggledBundleId = $0 }
        server.onUnmuteAllApps = { unmutedAll = true }
        server.onSelectDisplay = { selectedDisplayId = $0 }
        server.onApplyProfile = { appliedProfileId = $0 }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "test-device-ext")
        defer { client.close() }
        _ = try await client.signIn(secret: secret)
        _ = try await client.receiveData() // initial snapshot

        try await client.send(CompanionClientMessage(type: "trim_clip", action: "trim_clip", clipId: "clip-trim-1"))
        try await client.send(CompanionClientMessage(type: "copy_clip", action: "copy_clip", clipId: "clip-copy-2"))
        try await client.send(CompanionClientMessage(type: "set_volume", action: "set_volume", target: "microphone", volume: 0.42))
        try await client.send(CompanionClientMessage(type: "toggle_app_mute", action: "toggle_app_mute", bundleId: "com.hnc.Discord"))
        try await client.send(CompanionClientMessage(type: "unmute_all_apps", action: "unmute_all_apps"))
        try await client.send(CompanionClientMessage(type: "select_display", action: "select_display", displayId: "builtin:main"))
        try await client.send(CompanionClientMessage(type: "apply_profile", action: "apply_profile", profileId: "profile-uuid-1"))

        try await waitUntil {
            trimmedId != nil &&
            copiedId != nil &&
            receivedVolume != nil &&
            toggledBundleId != nil &&
            unmutedAll &&
            selectedDisplayId != nil &&
            appliedProfileId != nil
        }

        XCTAssertEqual(trimmedId, "clip-trim-1")
        XCTAssertEqual(copiedId, "clip-copy-2")
        XCTAssertEqual(receivedVolume?.0, "microphone")
        XCTAssertEqual(receivedVolume?.1 ?? 0, 0.42, accuracy: 0.001)
        XCTAssertEqual(toggledBundleId, "com.hnc.Discord")
        XCTAssertTrue(unmutedAll)
        XCTAssertEqual(selectedDisplayId, "builtin:main")
        XCTAssertEqual(appliedProfileId, "profile-uuid-1")
    }
}
