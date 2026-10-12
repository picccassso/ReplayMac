import XCTest
@testable import CompanionServer

/// A phone, as far as the server can tell: speaks the JSON protocol over a
/// real WebSocket and can sign in with a pairing secret.
final class CompanionTestClient: @unchecked Sendable {
    let deviceId: String
    let deviceName: String
    private let task: URLSessionWebSocketTask

    init(port: UInt16, deviceId: String, deviceName: String = "Pixel 8") {
        self.deviceId = deviceId
        self.deviceName = deviceName
        task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    func send(_ json: String) async throws {
        try await task.send(.string(json))
    }

    func send(_ message: CompanionClientMessage) async throws {
        try await send(String(decoding: try JSONEncoder().encode(message), as: UTF8.self))
    }

    func sendHello(protocolVersion: Int? = CompanionAuth.protocolVersion) async throws {
        try await send(CompanionClientMessage(
            type: "hello",
            deviceId: deviceId,
            deviceName: deviceName,
            clientVersion: "test",
            protocolVersion: protocolVersion
        ))
    }

    /// The next text frame as raw JSON.
    func receiveData() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: throw URLError(.cannotParseResponse)
        }
    }

    func receive<T: Decodable>(_ type: T.Type) async throws -> T {
        let data = try await receiveData()
        return try JSONDecoder().decode(type, from: data)
    }

    func receiveType() async throws -> String {
        let data = try await receiveData()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["type"] as? String ?? ""
    }

    /// Whether the server has closed the socket.
    func isClosedByServer(within timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                _ = try await task.receive()
            } catch {
                return true
            }
        }
        return false
    }

    /// Runs hello → challenge → proof and returns the server's verdict.
    func signIn(secret: Data?) async throws -> CompanionAuthResponse {
        try await sendHello()
        let challenge = try await receive(CompanionAuthChallenge.self)
        XCTAssertEqual(challenge.type, "auth_challenge")
        let proof = secret.map {
            CompanionAuth.proof(secret: $0, serverId: challenge.serverId, deviceId: deviceId, nonce: challenge.nonce)
                .base64EncodedString()
        }
        try await send(CompanionClientMessage(type: "auth_proof", proof: proof))
        return try await receive(CompanionAuthResponse.self)
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return XCTFail("Timed out waiting for condition") }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

func makeTestDefaults() -> UserDefaults {
    UserDefaults(suiteName: "CompanionTests-\(UUID().uuidString)")!
}

@MainActor
func startTestServer(pairing: CompanionPairingManager, defaults: UserDefaults) async throws -> CompanionServer {
    let server = CompanionServer(pairingManager: pairing, defaults: defaults)
    server.snapshotProvider = { CompanionStateSnapshot.empty }
    try server.start(port: 0)
    try await waitUntil { server.isRunning && server.listeningPort != 0 }
    return server
}
