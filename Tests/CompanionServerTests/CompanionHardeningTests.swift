import XCTest
@testable import CompanionServer

/// What happens when something other than a well-behaved paired phone shows up.
@MainActor
final class CompanionHardeningTests: XCTestCase {
    private var defaults: UserDefaults!
    private var pairing: CompanionPairingManager!

    override func setUp() async throws {
        try await super.setUp()
        defaults = makeTestDefaults()
        pairing = CompanionPairingManager(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaults.description)
        try await super.tearDown()
    }

    func testOutdatedClientIsToldToUpdate() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "old-phone")
        try await client.sendHello(protocolVersion: nil)
        let error = try await client.receive(CompanionErrorMessage.self)
        XCTAssertEqual(error.code, "unsupported_client")
        let closed = await client.isClosedByServer()
        XCTAssertTrue(closed)
    }

    func testInvalidDeviceIdIsRejected() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "has spaces\nand newlines")
        try await client.sendHello()
        do {
            let received = try await client.receive(CompanionErrorMessage.self).code
            XCTAssertEqual(received, "unsupported_client")
        }
    }

    func testPhoneThatLostItsSecretMustBeApprovedAgain() async throws {
        let oldSecret = pairing.approveDevice(id: "phone-1", name: "Phone")
        var prompts = 0
        pairing.promptHandler = { _, _, _ in
            prompts += 1
            return true
        }
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "phone-1")
        defer { client.close() }
        let pending = try await client.signIn(secret: nil)
        XCTAssertEqual(pending.status, "pending")
        XCTAssertNotNil(pending.pairingCode)

        let approved = try await client.receive(CompanionAuthResponse.self)
        XCTAssertEqual(approved.status, "approved")
        XCTAssertEqual(prompts, 1)
        let newSecret = try XCTUnwrap(approved.pairingSecret.flatMap { Data(base64Encoded: $0) })
        XCTAssertNotEqual(newSecret, oldSecret, "Re-pairing rotates the secret")
    }

    func testSecondDeviceIsTurnedAwayWhileAPromptIsUp() async throws {
        pairing.promptHandler = { _, _, _ in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return false
        }
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let first = CompanionTestClient(port: server.listeningPort, deviceId: "phone-a")
        defer { first.close() }
        try await first.sendHello()
        do {
            let received = try await first.receive(CompanionAuthResponse.self).status
            XCTAssertEqual(received, "pending")
        }

        let second = CompanionTestClient(port: server.listeningPort, deviceId: "phone-b")
        try await second.sendHello()
        let error = try await second.receive(CompanionErrorMessage.self)
        XCTAssertEqual(error.code, "busy")
        XCTAssertTrue(pairing.isPromptActive, "The first phone's prompt stays up")
    }

    func testSamePhoneRetryingKeepsThePromptAndCode() async throws {
        var prompts = 0
        pairing.promptHandler = { _, _, _ in
            prompts += 1
            try? await Task.sleep(nanoseconds: 500_000_000)
            return true
        }
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let first = CompanionTestClient(port: server.listeningPort, deviceId: "phone-a")
        try await first.sendHello()
        let firstPending = try await first.receive(CompanionAuthResponse.self)

        let retry = CompanionTestClient(port: server.listeningPort, deviceId: "phone-a")
        defer { retry.close() }
        try await retry.sendHello()
        let retryPending = try await retry.receive(CompanionAuthResponse.self)
        XCTAssertEqual(retryPending.status, "pending")
        XCTAssertEqual(retryPending.pairingCode, firstPending.pairingCode)

        do {

            let received = try await retry.receive(CompanionAuthResponse.self).status

            XCTAssertEqual(received, "approved")

        }
        XCTAssertEqual(prompts, 1)
        let firstClosed = await first.isClosedByServer()
        XCTAssertTrue(firstClosed, "The abandoned connection is dropped")
    }

    func testDeniedPhoneIsDeniedThenCoolsDown() async throws {
        var prompts = 0
        pairing.promptHandler = { _, _, _ in
            prompts += 1
            return false
        }
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "phone-a")
        try await client.sendHello()
        do {
            let received = try await client.receive(CompanionAuthResponse.self).status
            XCTAssertEqual(received, "pending")
        }
        let denied = try await client.receive(CompanionAuthResponse.self)
        XCTAssertEqual(denied.status, "denied")
        XCTAssertEqual(denied.reason, "user_denied")

        let retry = CompanionTestClient(port: server.listeningPort, deviceId: "phone-a")
        try await retry.sendHello()
        do {
            let received = try await retry.receive(CompanionErrorMessage.self).code
            XCTAssertEqual(received, "cooldown")
        }
        XCTAssertEqual(prompts, 1, "No second prompt during the cooldown")
    }

    func testUnansweredPromptTimesOut() async throws {
        pairing.promptTimeout = 0.2
        pairing.promptHandler = { _, _, _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return true
        }
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "phone-a")
        try await client.sendHello()
        do {
            let received = try await client.receive(CompanionAuthResponse.self).status
            XCTAssertEqual(received, "pending")
        }
        do {
            let received = try await client.receive(CompanionErrorMessage.self).code
            XCTAssertEqual(received, "timeout")
        }
        XCTAssertFalse(pairing.isDeviceApproved(id: "phone-a"))
    }

    func testPhoneLeavingDismissesItsPrompt() async throws {
        pairing.promptHandler = { _, _, _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return true
        }
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "phone-a")
        try await client.sendHello()
        _ = try await client.receiveData()
        XCTAssertTrue(pairing.isPromptActive)

        client.close()
        try await waitUntil { !pairing.isPromptActive }
        XCTAssertFalse(pairing.isDeviceApproved(id: "phone-a"))
    }

    func testPendingPhoneNeverSeesApprovedWhenTheMacIsRenamed() async throws {
        pairing.promptHandler = { _, _, _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return false
        }
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "phone-a")
        defer { client.close() }
        try await client.sendHello()
        do {
            let received = try await client.receive(CompanionAuthResponse.self).status
            XCTAssertEqual(received, "pending")
        }

        server.updateServerName("Renamed Mac")
        try await client.send(CompanionClientMessage(type: "ping"))
        do {
            let received = try await client.receiveType()
            XCTAssertEqual(received, "pong", "No auth_response may arrive before the pong")
        }
    }

    func testSilentConnectionIsDroppedAfterTheDeadline() async throws {
        let server = CompanionServer(pairingManager: pairing, defaults: defaults)
        server.authDeadline = 0.3
        try server.start(port: 0)
        defer { server.stop() }
        try await waitUntil { server.isRunning && server.listeningPort != 0 }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "lurker")
        try await client.send(CompanionClientMessage(type: "ping"))
        do {
            let received = try await client.receiveType()
            XCTAssertEqual(received, "pong")
        }
        do {
            let received = try await client.receive(CompanionErrorMessage.self).code
            XCTAssertEqual(received, "timeout")
        }
        let closed = await client.isClosedByServer()
        XCTAssertTrue(closed)
    }

    func testRevokingAConnectedPhoneDeniesIt() async throws {
        let secret = pairing.approveDevice(id: "phone-1", name: "Phone")
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "phone-1")
        _ = try await client.signIn(secret: secret)
        _ = try await client.receiveData() // snapshot

        pairing.revokeDevice(id: "phone-1")
        let denied = try await client.receive(CompanionAuthResponse.self)
        XCTAssertEqual(denied.status, "denied")
        XCTAssertEqual(denied.reason, "revoked")
        try await waitUntil { server.connectedClientsCount == 0 }
    }

    func testOversizedMessageDropsTheConnection() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "flooder")
        try? await client.send(String(repeating: "x", count: CompanionServer.maxMessageSize + 1))
        let closed = await client.isClosedByServer()
        XCTAssertTrue(closed)
    }
}

final class CompanionAuthTests: XCTestCase {
    /// Shared with the iOS and Android clients; computed independently with
    /// `printf 'replaycap-companion-auth-v1\nS\nD\nN' | openssl dgst -sha256 -mac HMAC -macopt hexkey:0101…01 -binary | base64`.
    func testProofMatchesCrossPlatformVector() {
        let proof = CompanionAuth.proof(secret: Data(repeating: 1, count: 32), serverId: "S", deviceId: "D", nonce: "N")
        XCTAssertEqual(proof.base64EncodedString(), "uWE2MkK60y47fmnf7H64CPSeu+v47Xrw4QeYLwmpKcs=")
    }

    func testProofVerification() {
        let secret = CompanionAuth.makeSecret()
        let nonce = CompanionAuth.makeNonce()
        let good = CompanionAuth.proof(secret: secret, serverId: "mac", deviceId: "phone", nonce: nonce).base64EncodedString()

        XCTAssertTrue(CompanionAuth.isValidProof(good, secret: secret, serverId: "mac", deviceId: "phone", nonce: nonce))
        XCTAssertFalse(CompanionAuth.isValidProof(good, secret: secret, serverId: "mac", deviceId: "phone", nonce: CompanionAuth.makeNonce()), "A replayed proof fails a new nonce")
        XCTAssertFalse(CompanionAuth.isValidProof(good, secret: secret, serverId: "other-mac", deviceId: "phone", nonce: nonce))
        XCTAssertFalse(CompanionAuth.isValidProof(good, secret: secret, serverId: "mac", deviceId: "other-phone", nonce: nonce))
        XCTAssertFalse(CompanionAuth.isValidProof(nil, secret: secret, serverId: "mac", deviceId: "phone", nonce: nonce))
        XCTAssertFalse(CompanionAuth.isValidProof("not base64!", secret: secret, serverId: "mac", deviceId: "phone", nonce: nonce))
    }

    func testRandomValuesAreFreshAndWellFormed() {
        XCTAssertNotEqual(CompanionAuth.makeSecret(), CompanionAuth.makeSecret())
        XCTAssertEqual(Data(base64Encoded: CompanionAuth.makeNonce())?.count, 32)
        for _ in 0..<50 {
            let code = CompanionAuth.makePairingCode()
            XCTAssertEqual(code.count, 4)
            XCTAssertTrue(code.allSatisfy(\.isNumber))
        }
    }

    func testDeviceNameIsMadeSafeToShowInThePrompt() {
        XCTAssertEqual(CompanionAuth.sanitizedDeviceName("  Alex's   iPhone \n"), "Alex's iPhone")
        XCTAssertEqual(CompanionAuth.sanitizedDeviceName("Phone\u{202E}enohP"), "PhoneenohP", "Bidi overrides are stripped")
        XCTAssertEqual(CompanionAuth.sanitizedDeviceName("Line one\nLine two"), "Line one Line two")
        XCTAssertNil(CompanionAuth.sanitizedDeviceName(" \n\t "))
        XCTAssertNil(CompanionAuth.sanitizedDeviceName(nil))

        let long = CompanionAuth.sanitizedDeviceName(String(repeating: "a", count: 200))
        XCTAssertEqual(long?.count, CompanionAuth.maxDeviceNameLength)
        XCTAssertTrue(long?.hasSuffix("…") == true)
    }

    func testDeviceIdMustBeAnOpaqueToken() {
        XCTAssertEqual(CompanionAuth.sanitizedDeviceId(" 3F2504E0-4F89-11D3-9A0C-0305E82C3301 "), "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertNil(CompanionAuth.sanitizedDeviceId(""))
        XCTAssertNil(CompanionAuth.sanitizedDeviceId(nil))
        XCTAssertNil(CompanionAuth.sanitizedDeviceId("has space"))
        XCTAssertNil(CompanionAuth.sanitizedDeviceId("ünïcode"))
        XCTAssertNil(CompanionAuth.sanitizedDeviceId(String(repeating: "a", count: 129)))
    }
}
