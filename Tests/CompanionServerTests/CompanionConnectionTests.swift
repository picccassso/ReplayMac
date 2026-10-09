import XCTest
import Network
@testable import CompanionServer

/// A bare WebSocket client that, unlike URLSession, can send the empty ping
/// frames OkHttp (the Android companion) sends every 15 seconds.
private final class RawWebSocketClient: @unchecked Sendable {
    private let connection: NWConnection

    init(port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)")!), using: parameters)
        connection.start(queue: .global())
    }

    func sendText(_ text: String) {
        send(Data(text.utf8), opcode: .text)
    }

    func sendEmptyPing() {
        send(nil, opcode: .ping)
    }

    func close() {
        connection.cancel()
    }

    private func send(_ data: Data?, opcode: NWProtocolWebSocket.Opcode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

@MainActor
final class CompanionConnectionTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "CompanionConnectionTests-\(UUID().uuidString)")!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaults.description)
        try await super.tearDown()
    }

    private func startServer(port: UInt16, approving deviceId: String) async throws -> CompanionServer {
        let pairing = CompanionPairingManager(defaults: defaults)
        pairing.approveDevice(id: deviceId, name: "Galaxy S23")
        let server = CompanionServer(pairingManager: pairing, defaults: defaults)
        server.snapshotProvider = { CompanionStateSnapshot.empty }
        try server.start(port: port)
        try await waitUntil { server.isRunning }
        return server
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for condition") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testEmptyPingKeepsPairedClientConnected() async throws {
        let server = try await startServer(port: 7394, approving: "phone-1")
        defer { server.stop() }
        var toggles = 0
        server.onToggleBuffer = { toggles += 1 }

        let client = RawWebSocketClient(port: 7394)
        defer { client.close() }
        client.sendText(#"{"type":"hello","deviceId":"phone-1","deviceName":"Galaxy S23"}"#)
        try await waitUntil { server.connectedClientsCount == 1 }

        client.sendEmptyPing()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.connectedClientsCount, 1, "A keepalive ping must not count as the phone hanging up")

        // The connection still carries actions after the ping.
        client.sendText(#"{"type":"action","action":"toggleBuffer"}"#)
        try await waitUntil { toggles == 1 }
    }

    func testClosedClientIsStillDropped() async throws {
        let server = try await startServer(port: 7395, approving: "phone-1")
        defer { server.stop() }

        let client = RawWebSocketClient(port: 7395)
        client.sendText(#"{"type":"hello","deviceId":"phone-1","deviceName":"Galaxy S23"}"#)
        try await waitUntil { server.connectedClientsCount == 1 }

        client.close()
        try await waitUntil { server.connectedClientsCount == 0 }
    }

    func testServerIdIsStableAndSentWhenPairing() async throws {
        let server = try await startServer(port: 7396, approving: "phone-1")
        defer { server.stop() }
        XCTAssertFalse(server.serverId.isEmpty)
        XCTAssertEqual(CompanionServer(defaults: defaults).serverId, server.serverId, "Same Mac, same id across launches")

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:7396")!)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        try await task.send(.string(#"{"type":"hello","deviceId":"phone-1","deviceName":"Galaxy S23"}"#))

        guard case .string(let text) = try await task.receive() else { return XCTFail("Expected a text frame") }
        let auth = try JSONDecoder().decode(CompanionAuthResponse.self, from: Data(text.utf8))
        XCTAssertEqual(auth.status, "approved")
        XCTAssertEqual(auth.serverId, server.serverId)
    }

    func testServerRenameReflectedToConnectedClient() async throws {
        let pairing = CompanionPairingManager(defaults: defaults)
        pairing.approveDevice(id: "phone-1", name: "Galaxy S23")
        let server = CompanionServer(pairingManager: pairing, defaults: defaults)
        server.snapshotProvider = { CompanionStateSnapshot.empty }
        try server.start(port: 7397)
        defer { server.stop() }
        try await waitUntil { server.isRunning }

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:7397")!)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        try await task.send(.string(#"{"type":"hello","deviceId":"phone-1","deviceName":"Galaxy S23"}"#))

        guard case .string(let text1) = try await task.receive() else { return XCTFail("Expected text") }
        let auth1 = try JSONDecoder().decode(CompanionAuthResponse.self, from: Data(text1.utf8))
        XCTAssertEqual(auth1.status, "approved")

        // Consume snapshot sent after auth
        _ = try await task.receive()

        // Rename server
        server.updateServerName("Alex's Studio Mac")
        XCTAssertEqual(server.serverName, "Alex's Studio Mac")

        // Client receives updated auth response
        guard case .string(let text2) = try await task.receive() else { return XCTFail("Expected text") }
        let auth2 = try JSONDecoder().decode(CompanionAuthResponse.self, from: Data(text2.utf8))
        XCTAssertEqual(auth2.status, "approved")
        XCTAssertEqual(auth2.serverName, "Alex's Studio Mac")
    }

    func testDeviceRenameReflectedToConnectedClient() async throws {
        let pairing = CompanionPairingManager(defaults: defaults)
        pairing.approveDevice(id: "phone-1", name: "Galaxy S23")
        let server = CompanionServer(pairingManager: pairing, defaults: defaults)
        server.snapshotProvider = { CompanionStateSnapshot.empty }
        try server.start(port: 7398)
        defer { server.stop() }
        try await waitUntil { server.isRunning }

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:7398")!)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        try await task.send(.string(#"{"type":"hello","deviceId":"phone-1","deviceName":"Galaxy S23"}"#))

        guard case .string(let text1) = try await task.receive() else { return XCTFail("Expected text") }
        let auth1 = try JSONDecoder().decode(CompanionAuthResponse.self, from: Data(text1.utf8))
        XCTAssertEqual(auth1.status, "approved")
        XCTAssertEqual(auth1.deviceName, "Galaxy S23")

        // Consume snapshot sent after auth
        _ = try await task.receive()

        // Rename device on pairing manager
        pairing.renameDevice(id: "phone-1", newName: "My Custom Android")

        // Client receives updated auth response with new device name
        guard case .string(let text2) = try await task.receive() else { return XCTFail("Expected text") }
        let auth2 = try JSONDecoder().decode(CompanionAuthResponse.self, from: Data(text2.utf8))
        XCTAssertEqual(auth2.status, "approved")
        XCTAssertEqual(auth2.deviceName, "My Custom Android")
    }
}
