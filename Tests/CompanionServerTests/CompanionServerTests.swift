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

    override func setUp() async throws {
        try await super.setUp()
        userDefaults = UserDefaults(suiteName: "CompanionPairingTests-\(UUID().uuidString)")!
        pairingManager = CompanionPairingManager(defaults: userDefaults)
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

    func testConcurrentApprovalPromptsCoalesced() async {
        var handlerCallCount = 0
        pairingManager.promptHandler = { id, name in
            handlerCallCount += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
            return true
        }

        // A local main-actor manager, so `async let` doesn't capture the test case.
        let manager: CompanionPairingManager = pairingManager
        async let first = manager.promptApprovalForDevice(id: "concurrent-dev", name: "Phone A")
        async let second = manager.promptApprovalForDevice(id: "concurrent-dev", name: "Phone A")

        let (res1, res2) = await (first, second)
        XCTAssertTrue(res1)
        XCTAssertTrue(res2)
        XCTAssertEqual(handlerCallCount, 1)
        XCTAssertTrue(pairingManager.isDeviceApproved(id: "concurrent-dev"))
    }
}

@MainActor
final class CompanionServerLifecycleTests: XCTestCase {
    func testServerStartAndStop() throws {
        let server = CompanionServer()
        XCTAssertFalse(server.isRunning)

        try server.start(port: 7380)
        XCTAssertEqual(server.listeningPort, 7380)

        server.stop()
        XCTAssertFalse(server.isRunning)
    }

    func testIPResolutionNonEmpty() {
        let ips = CompanionServer.resolveLocalIPAddresses()
        XCTAssertFalse(ips.isEmpty)
    }

    func testEndToEndWebSocketHandshakeAndAction() async throws {
        let defaults = UserDefaults(suiteName: "CompanionTest-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let pairing = CompanionPairingManager(defaults: defaults)
        pairing.approveDevice(id: "test-device-1", name: "Pixel 8")

        let server = CompanionServer(pairingManager: pairing)
        var actionReceived = false
        server.onToggleBuffer = {
            actionReceived = true
        }
        server.snapshotProvider = {
            CompanionStateSnapshot.empty
        }

        try server.start(port: 7388)
        defer { server.stop() }

        for _ in 0..<20 {
            if server.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(server.isRunning)

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: URL(string: "ws://127.0.0.1:7388")!)
        wsTask.resume()

        // Send hello
        let helloMsg = CompanionClientMessage(type: "hello", deviceId: "test-device-1", deviceName: "Pixel 8")
        let helloData = try JSONEncoder().encode(helloMsg)
        let helloStr = String(data: helloData, encoding: .utf8)!
        try await wsTask.send(.string(helloStr))

        // Receive auth response
        let msg1 = try await wsTask.receive()
        let authData: Data
        switch msg1 {
        case .string(let str): authData = str.data(using: .utf8)!
        case .data(let d): authData = d
        @unknown default: fatalError()
        }
        let auth = try JSONDecoder().decode(CompanionAuthResponse.self, from: authData)
        XCTAssertEqual(auth.status, "approved")

        // Receive initial state snapshot
        let msg2 = try await wsTask.receive()
        let snapData: Data
        switch msg2 {
        case .string(let str): snapData = str.data(using: .utf8)!
        case .data(let d): snapData = d
        @unknown default: fatalError()
        }
        let snapshot = try JSONDecoder().decode(CompanionStateSnapshot.self, from: snapData)
        XCTAssertEqual(snapshot.type, "state_snapshot")

        // Send action
        let actionMsg = CompanionClientMessage(type: "action", action: "toggleBuffer")
        let actionData = try JSONEncoder().encode(actionMsg)
        let actionStr = String(data: actionData, encoding: .utf8)!
        try await wsTask.send(.string(actionStr))

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(actionReceived)
        XCTAssertEqual(server.connectedClientsCount, 1)

        // Disconnect
        wsTask.cancel(with: .normalClosure, reason: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.connectedClientsCount, 0)
    }

    func testActionWithRevealClip() async throws {
        let defaults = UserDefaults(suiteName: "CompanionTest-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let pairing = CompanionPairingManager(defaults: defaults)
        pairing.approveDevice(id: "test-device-1", name: "Pixel 8")

        let server = CompanionServer(pairingManager: pairing)
        var revealedId: String?
        server.onRevealClip = { id in
            revealedId = id
        }
        server.snapshotProvider = { CompanionStateSnapshot.empty }

        try server.start(port: 7389)
        defer { server.stop() }

        for _ in 0..<20 {
            if server.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: URL(string: "ws://127.0.0.1:7389")!)
        wsTask.resume()

        let helloMsg = CompanionClientMessage(type: "hello", deviceId: "test-device-1", deviceName: "Pixel 8")
        try await wsTask.send(.string(String(data: try JSONEncoder().encode(helloMsg), encoding: .utf8)!))
        _ = try await wsTask.receive() // auth
        _ = try await wsTask.receive() // snapshot

        // Send action format: type = action, action = reveal_clip
        let msg = CompanionClientMessage(type: "action", action: "reveal_clip", clipId: "clip-123")
        try await wsTask.send(.string(String(data: try JSONEncoder().encode(msg), encoding: .utf8)!))

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(revealedId, "clip-123")
    }

    func testActionWithDeleteClip() async throws {
        let defaults = UserDefaults(suiteName: "CompanionTest-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let pairing = CompanionPairingManager(defaults: defaults)
        pairing.approveDevice(id: "test-device-1", name: "Pixel 8")

        let server = CompanionServer(pairingManager: pairing)
        var deletedId: String?
        server.onDeleteClip = { id in
            deletedId = id
        }
        server.snapshotProvider = { CompanionStateSnapshot.empty }

        try server.start(port: 7390)
        defer { server.stop() }

        for _ in 0..<20 {
            if server.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: URL(string: "ws://127.0.0.1:7390")!)
        wsTask.resume()

        let helloMsg = CompanionClientMessage(type: "hello", deviceId: "test-device-1", deviceName: "Pixel 8")
        try await wsTask.send(.string(String(data: try JSONEncoder().encode(helloMsg), encoding: .utf8)!))
        _ = try await wsTask.receive() // auth
        _ = try await wsTask.receive() // snapshot

        // Send direct format: type = delete_clip
        let msg = CompanionClientMessage(type: "delete_clip", clipId: "clip-del-999")
        try await wsTask.send(.string(String(data: try JSONEncoder().encode(msg), encoding: .utf8)!))

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(deletedId, "clip-del-999")
    }

    func testGetThumbnailRequest() async throws {
        let defaults = UserDefaults(suiteName: "CompanionTest-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let pairing = CompanionPairingManager(defaults: defaults)
        pairing.approveDevice(id: "test-device-1", name: "Pixel 8")

        let server = CompanionServer(pairingManager: pairing)
        server.onGetThumbnail = { clipId in
            return "sample-thumb-bytes".data(using: .utf8)
        }
        server.snapshotProvider = { CompanionStateSnapshot.empty }

        try server.start(port: 7391)
        defer { server.stop() }

        for _ in 0..<20 {
            if server.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: URL(string: "ws://127.0.0.1:7391")!)
        wsTask.resume()

        let helloMsg = CompanionClientMessage(type: "hello", deviceId: "test-device-1", deviceName: "Pixel 8")
        try await wsTask.send(.string(String(data: try JSONEncoder().encode(helloMsg), encoding: .utf8)!))
        _ = try await wsTask.receive() // auth
        _ = try await wsTask.receive() // snapshot

        let thumbReq = CompanionClientMessage(type: "get_thumbnail", clipId: "clip-thumb-1")
        try await wsTask.send(.string(String(data: try JSONEncoder().encode(thumbReq), encoding: .utf8)!))

        let respMsg = try await wsTask.receive()
        let respData: Data
        switch respMsg {
        case .string(let s): respData = s.data(using: .utf8)!
        case .data(let d): respData = d
        @unknown default: fatalError()
        }

        let thumbResp = try JSONDecoder().decode(CompanionThumbnailResponse.self, from: respData)
        XCTAssertEqual(thumbResp.clipId, "clip-thumb-1")
        let expectedBase64 = "sample-thumb-bytes".data(using: .utf8)!.base64EncodedString()
        XCTAssertEqual(thumbResp.thumbnailBase64, expectedBase64)
    }

    func testUnapprovedDevicePendingThenApproved() async throws {
        let defaults = UserDefaults(suiteName: "CompanionTest-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let pairing = CompanionPairingManager(defaults: defaults)
        pairing.promptHandler = { id, name in
            return true
        }

        let server = CompanionServer(pairingManager: pairing)
        server.snapshotProvider = {
            CompanionStateSnapshot.empty
        }

        try server.start(port: 7392)
        defer { server.stop() }

        for _ in 0..<20 {
            if server.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: URL(string: "ws://127.0.0.1:7392")!)
        wsTask.resume()

        let helloMsg = CompanionClientMessage(type: "hello", deviceId: "unapproved-dev", deviceName: "Galaxy")
        try await wsTask.send(.string(String(data: try JSONEncoder().encode(helloMsg), encoding: .utf8)!))

        // First response is pending
        let resp1 = try await wsTask.receive()
        let resp1Data: Data
        switch resp1 {
        case .string(let s): resp1Data = s.data(using: .utf8)!
        case .data(let d): resp1Data = d
        @unknown default: fatalError()
        }
        let authPending = try JSONDecoder().decode(CompanionAuthResponse.self, from: resp1Data)
        XCTAssertEqual(authPending.status, "pending")

        // Second response is approved
        let resp2 = try await wsTask.receive()
        let resp2Data: Data
        switch resp2 {
        case .string(let s): resp2Data = s.data(using: .utf8)!
        case .data(let d): resp2Data = d
        @unknown default: fatalError()
        }
        let authApproved = try JSONDecoder().decode(CompanionAuthResponse.self, from: resp2Data)
        XCTAssertEqual(authApproved.status, "approved")

        // Initial snapshot follows
        let resp3 = try await wsTask.receive()
        let resp3Data: Data
        switch resp3 {
        case .string(let s): resp3Data = s.data(using: .utf8)!
        case .data(let d): resp3Data = d
        @unknown default: fatalError()
        }
        let snapshot = try JSONDecoder().decode(CompanionStateSnapshot.self, from: resp3Data)
        XCTAssertEqual(snapshot.type, "state_snapshot")
    }

    func testUnauthorizedActionRejected() async throws {
        let defaults = UserDefaults(suiteName: "CompanionTest-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let pairing = CompanionPairingManager(defaults: defaults)

        let server = CompanionServer(pairingManager: pairing)
        var actionRun = false
        server.onToggleBuffer = {
            actionRun = true
        }

        try server.start(port: 7393)
        defer { server.stop() }

        for _ in 0..<20 {
            if server.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: URL(string: "ws://127.0.0.1:7393")!)
        wsTask.resume()

        // Send action WITHOUT hello
        let actionMsg = CompanionClientMessage(type: "action", action: "toggleBuffer")
        try await wsTask.send(.string(String(data: try JSONEncoder().encode(actionMsg), encoding: .utf8)!))

        let resp = try await wsTask.receive()
        let respData: Data
        switch resp {
        case .string(let s): respData = s.data(using: .utf8)!
        case .data(let d): respData = d
        @unknown default: fatalError()
        }
        let errMsg = try JSONDecoder().decode(CompanionErrorMessage.self, from: respData)
        XCTAssertEqual(errMsg.type, "error")
        XCTAssertEqual(errMsg.message, "Device not authorized")
        XCTAssertFalse(actionRun)
    }
}


