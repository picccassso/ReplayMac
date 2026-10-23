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

    func receiveJSON() async throws -> [String: Any] {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { content, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: content ?? Data())
                }
            }
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// hello → challenge → proof, the way a paired phone signs in.
    func signIn(deviceId: String, secret: Data) async throws {
        sendText(#"{"type":"hello","deviceId":"\#(deviceId)","deviceName":"Galaxy S23","protocolVersion":2}"#)
        let challenge = try await receiveJSON()
        let proof = CompanionAuth.proof(
            secret: secret,
            serverId: challenge["serverId"] as? String ?? "",
            deviceId: deviceId,
            nonce: challenge["nonce"] as? String ?? ""
        ).base64EncodedString()
        sendText(#"{"type":"auth_proof","proof":"\#(proof)"}"#)
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
    private var pairing: CompanionPairingManager!
    private var secret: Data!

    override func setUp() async throws {
        try await super.setUp()
        defaults = makeTestDefaults()
        pairing = CompanionPairingManager(defaults: defaults, secretStore: InMemoryPairingSecretStore())
        secret = pairing.approveDevice(id: "phone-1", name: "Galaxy S23")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaults.description)
        try await super.tearDown()
    }

    func testEmptyPingKeepsPairedClientConnected() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }
        var toggles = 0
        server.onToggleBuffer = { toggles += 1 }

        let client = RawWebSocketClient(port: server.listeningPort)
        defer { client.close() }
        try await client.signIn(deviceId: "phone-1", secret: secret)
        try await waitUntil { server.connectedClientsCount == 1 }

        client.sendEmptyPing()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.connectedClientsCount, 1, "A keepalive ping must not count as the phone hanging up")

        // The connection still carries actions after the ping.
        client.sendText(#"{"type":"action","action":"toggleBuffer"}"#)
        try await waitUntil { toggles == 1 }
    }

    func testClosedClientIsStillDropped() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = RawWebSocketClient(port: server.listeningPort)
        try await client.signIn(deviceId: "phone-1", secret: secret)
        try await waitUntil { server.connectedClientsCount == 1 }

        client.close()
        try await waitUntil { server.connectedClientsCount == 0 }
    }

    func testServerIdIsStableAndSentInChallengeAndApproval() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }
        XCTAssertFalse(server.serverId.isEmpty)
        XCTAssertEqual(CompanionServer(pairingManager: pairing, defaults: defaults).serverId, server.serverId, "Same Mac, same id across launches")

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "phone-1")
        defer { client.close() }
        let auth = try await client.signIn(secret: secret)
        XCTAssertEqual(auth.status, "approved")
        XCTAssertEqual(auth.serverId, server.serverId)
    }

    func testServerRenameReflectedToConnectedClient() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "phone-1")
        defer { client.close() }
        do {
            let received = try await client.signIn(secret: secret).status
            XCTAssertEqual(received, "approved")
        }
        _ = try await client.receiveData() // snapshot

        server.updateServerName("Alex's Studio Mac")
        XCTAssertEqual(server.serverName, "Alex's Studio Mac")

        let renamed = try await client.receive(CompanionAuthResponse.self)
        XCTAssertEqual(renamed.status, "approved")
        XCTAssertEqual(renamed.serverName, "Alex's Studio Mac")
    }

    func testDeviceRenameReflectedToConnectedClient() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "phone-1", deviceName: "Galaxy S23")
        defer { client.close() }
        let auth = try await client.signIn(secret: secret)
        XCTAssertEqual(auth.deviceName, "Galaxy S23")
        _ = try await client.receiveData() // snapshot

        pairing.renameDevice(id: "phone-1", newName: "My Custom Android")

        let renamed = try await client.receive(CompanionAuthResponse.self)
        XCTAssertEqual(renamed.status, "approved")
        XCTAssertEqual(renamed.deviceName, "My Custom Android")
    }

    func testHelloOnSignedInConnectionResendsState() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "phone-1")
        defer { client.close() }
        _ = try await client.signIn(secret: secret)
        _ = try await client.receiveData() // snapshot

        // What the phone does when it comes back to the foreground.
        try await client.sendHello()
        let auth = try await client.receive(CompanionAuthResponse.self)
        XCTAssertEqual(auth.status, "approved")
        do {
            let received = try await client.receiveType()
            XCTAssertEqual(received, "state_snapshot")
        }
    }
}
