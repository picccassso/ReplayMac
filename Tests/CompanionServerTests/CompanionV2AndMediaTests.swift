import XCTest
import Network
@testable import CompanionServer

final class CompanionServerProtocolV2Tests: XCTestCase {
    func testSnapshotV2RoundTripAndWithType() throws {
        let clip = CompanionClipSummary(
            id: "clip-1",
            filename: "Clutch.mp4",
            kind: "replay",
            savedAt: 1730000000,
            duration: 30,
            fileSize: 2048,
            hasThumbnail: true,
            isFavorite: true,
            tags: ["Clutch", "Highlight"],
            note: "Final round 1v3"
        )
        let snapshot = CompanionStateSnapshot(
            isRecording: true,
            isSessionRecording: false,
            saveStatus: "idle",
            recordingElapsedSeconds: 12,
            extendedBufferElapsedSeconds: 12,
            sessionElapsedSeconds: 0,
            bufferedSeconds: 12,
            bufferDurationSeconds: 30,
            bufferMemoryBytes: 4096,
            bufferMemoryFormatted: "4 KB",
            longBufferEnabled: true,
            longBufferDurationSeconds: 300,
            capturedDisplayName: "Studio Display",
            isMicrophoneEnabled: true,
            isMicrophoneMuted: false,
            isSystemAudioEnabled: true,
            isSystemAudioMuted: false,
            microphoneVolume: 1.0,
            systemAudioVolume: 0.75,
            microphoneGain: 2.25,
            microphoneGainMax: 4.0,
            perAppAudioEnabled: true,
            isCameraOverlayEnabled: true,
            isCameraOverlayAvailable: true,
            isExtendedReplayAvailable: true,
            isSessionRecordingAvailable: false,
            isAudioMixingAvailable: true,
            isQuickSavePresetsAvailable: false,
            isCaptureProfilesAvailable: false,
            isAutoRecordGamesAvailable: true,
            autoRecordGamesEnabled: true,
            activeGameName: "Baldur's Gate 3",
            showCursorInRecordings: false,
            cameraOverlayPosition: "bottomRight",
            cameraOverlaySize: "large",
            warnings: ["Critical memory pressure: buffer shortened to 15s", "System audio stalled"],
            recentClips: [clip]
        )

        let changed = snapshot.withType("state_changed")
        XCTAssertEqual(changed.type, "state_changed")
        XCTAssertEqual(changed.activeGameName, "Baldur's Gate 3")
        XCTAssertEqual(changed.cameraOverlayPosition, "bottomRight")
        XCTAssertEqual(changed.cameraOverlaySize, "large")
        XCTAssertEqual(changed.warnings.count, 2)

        let data = try JSONEncoder().encode(changed)
        let decoded = try JSONDecoder().decode(CompanionStateSnapshot.self, from: data)
        XCTAssertEqual(decoded, changed)
        XCTAssertTrue(decoded.isExtendedReplayAvailable)
        XCTAssertFalse(decoded.isSessionRecordingAvailable)
        XCTAssertFalse(decoded.isQuickSavePresetsAvailable)
        XCTAssertFalse(decoded.isCaptureProfilesAvailable)
        XCTAssertTrue(decoded.isAutoRecordGamesAvailable)
        XCTAssertTrue(decoded.autoRecordGamesEnabled)
        XCTAssertFalse(decoded.showCursorInRecordings)
        XCTAssertEqual(decoded.recentClips.first?.isFavorite, true)
        XCTAssertEqual(decoded.recentClips.first?.tags, ["Clutch", "Highlight"])
        XCTAssertEqual(decoded.recentClips.first?.note, "Final round 1v3")
    }

    func testLegacySnapshotAndClipDefaultsAreBackwardsCompatible() throws {
        let legacyJSON = """
        {
            "type": "state_snapshot",
            "isRecording": true,
            "recentClips": [
                {
                    "id": "legacy-1",
                    "filename": "Old.mp4",
                    "kind": "replay",
                    "savedAt": 1700000000
                }
            ]
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(CompanionStateSnapshot.self, from: legacyJSON)
        XCTAssertTrue(snapshot.isExtendedReplayAvailable)
        XCTAssertTrue(snapshot.isSessionRecordingAvailable)
        XCTAssertTrue(snapshot.isAudioMixingAvailable)
        XCTAssertTrue(snapshot.isQuickSavePresetsAvailable)
        XCTAssertTrue(snapshot.isCaptureProfilesAvailable)
        XCTAssertFalse(snapshot.isAutoRecordGamesAvailable)
        XCTAssertFalse(snapshot.autoRecordGamesEnabled)
        XCTAssertNil(snapshot.activeGameName)
        XCTAssertTrue(snapshot.showCursorInRecordings)
        XCTAssertNil(snapshot.cameraOverlayPosition)
        XCTAssertNil(snapshot.cameraOverlaySize)
        XCTAssertTrue(snapshot.warnings.isEmpty)

        let clip = try XCTUnwrap(snapshot.recentClips.first)
        XCTAssertFalse(clip.isFavorite)
        XCTAssertTrue(clip.tags.isEmpty)
        XCTAssertEqual(clip.note, "")
    }

    func testNewServerMessagesEncodeAndDecode() throws {
        let levels = CompanionAudioLevelsMessage(microphone: 0.42, systemAudio: 0.65)
        let levelsObj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(levels)) as? [String: Any]
        XCTAssertEqual(levelsObj?["type"] as? String, "audio_levels")
        XCTAssertEqual(levelsObj?["microphone"] as? Double ?? 0, 0.42, accuracy: 0.001)
        XCTAssertEqual(levelsObj?["systemAudio"] as? Double ?? 0, 0.65, accuracy: 0.001)

        let feedback = CompanionActionFeedbackMessage(kind: .error, title: "Save Failed", message: "Disk full")
        let decodedFeedback = try JSONDecoder().decode(
            CompanionActionFeedbackMessage.self,
            from: JSONEncoder().encode(feedback)
        )
        XCTAssertEqual(decodedFeedback.type, "action_feedback")
        XCTAssertEqual(decodedFeedback.kind, "error")
        XCTAssertEqual(decodedFeedback.title, "Save Failed")
        XCTAssertEqual(decodedFeedback.message, "Disk full")

        let media = CompanionClipMediaResponse(
            clipId: "c1",
            httpPort: 7376,
            token: "abc",
            filename: "Clip.mp4",
            fileSize: 123456,
            mimeType: "video/mp4",
            error: nil
        )
        let decodedMedia = try JSONDecoder().decode(
            CompanionClipMediaResponse.self,
            from: JSONEncoder().encode(media)
        )
        XCTAssertEqual(decodedMedia, media)
    }

    func testNewClientMessagesDecode() throws {
        let updateJSON = """
        {
            "type": "update_clip_metadata",
            "clipId": "c1",
            "isFavorite": true,
            "tags": ["Funny", "Clutch"],
            "note": "Nice shot"
        }
        """.data(using: .utf8)!
        let update = try JSONDecoder().decode(CompanionClientMessage.self, from: updateJSON)
        XCTAssertEqual(update.type, "update_clip_metadata")
        XCTAssertEqual(update.clipId, "c1")
        XCTAssertEqual(update.isFavorite, true)
        XCTAssertEqual(update.tags, ["Funny", "Clutch"])
        XCTAssertEqual(update.note, "Nice shot")

        let durationJSON = #"{"type":"save_replay_duration","durationSeconds":15}"#.data(using: .utf8)!
        let durationMsg = try JSONDecoder().decode(CompanionClientMessage.self, from: durationJSON)
        XCTAssertEqual(durationMsg.durationSeconds, 15)

        let pushToMuteJSON = #"{"type":"push_to_mute","active":true}"#.data(using: .utf8)!
        let pushToMute = try JSONDecoder().decode(CompanionClientMessage.self, from: pushToMuteJSON)
        XCTAssertEqual(pushToMute.active, true)

        XCTAssertEqual(CompanionClientAction(rawValue: "toggleCursor"), .toggleCursor)
        XCTAssertEqual(CompanionClientAction(rawValue: "toggleAutoRecordGames"), .toggleAutoRecordGames)
    }

    func testPairingURIFormattingAndRoundTrip() throws {
        let uri = CompanionPairingURI.make(
            hosts: ["192.168.1.42", "10.0.0.5"],
            port: 7375,
            serverId: "mac-uuid-123",
            serverName: "Alex's Mac & Studio"
        )
        XCTAssertTrue(uri.hasPrefix("replaycap://pair?"))
        let components = try XCTUnwrap(URLComponents(string: uri))
        XCTAssertEqual(components.scheme, "replaycap")
        XCTAssertEqual(components.host, "pair")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["hosts"], "192.168.1.42,10.0.0.5")
        XCTAssertEqual(items["port"], "7375")
        XCTAssertEqual(items["id"], "mac-uuid-123")
        XCTAssertEqual(items["name"], "Alex's Mac & Studio")
    }
}

@MainActor
final class CompanionServerV2Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var pairing: CompanionPairingManager!
    private var secret: Data!

    override func setUp() async throws {
        try await super.setUp()
        defaults = makeTestDefaults()
        pairing = CompanionPairingManager(defaults: defaults, secretStore: InMemoryPairingSecretStore())
        secret = pairing.approveDevice(id: "dev-v2", name: "Pixel 9")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaults.description)
        try await super.tearDown()
    }

    func testNewCommandsReachHandlersAndPushToMuteReleasesOnDisconnect() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        var toggledCursor = false
        var toggledAutoRecord = false
        var savedDuration: Int?
        var favoriteClipId: String?
        var updatedMeta: (String, Bool?, [String]?, String?)?
        var renamedClip: (String, String)?
        var cameraLayout: (String?, String?)?
        var pushStates: [Bool] = []

        server.onToggleCursor = { toggledCursor = true }
        server.onToggleAutoRecordGames = { toggledAutoRecord = true }
        server.onSaveReplayDuration = { savedDuration = $0 }
        server.onToggleClipFavorite = { favoriteClipId = $0 }
        server.onUpdateClipMetadata = { updatedMeta = ($0, $1, $2, $3) }
        server.onRenameClip = { renamedClip = ($0, $1) }
        server.onSetCameraLayout = { cameraLayout = ($0, $1) }
        server.onPushToMute = { pushStates.append($0) }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "dev-v2")
        _ = try await client.signIn(secret: secret)
        _ = try await client.receiveData() // snapshot

        try await client.send(CompanionClientMessage(type: "action", action: "toggleCursor"))
        try await client.send(CompanionClientMessage(type: "action", action: "toggleAutoRecordGames"))
        try await client.send(CompanionClientMessage(type: "save_replay_duration", durationSeconds: 15))
        try await client.send(CompanionClientMessage(type: "toggle_clip_favorite", clipId: "c-fav"))
        try await client.send(CompanionClientMessage(
            type: "update_clip_metadata",
            clipId: "c-meta",
            isFavorite: true,
            tags: ["Highlight"],
            note: "Great clip"
        ))
        try await client.send(CompanionClientMessage(type: "rename_clip", clipId: "c-ren", newName: "Boss Fight"))
        try await client.send(CompanionClientMessage(type: "set_camera_layout", position: "bottomLeft", size: "medium"))
        try await client.send(CompanionClientMessage(type: "push_to_mute", active: true))

        try await waitUntil {
            toggledCursor &&
            toggledAutoRecord &&
            savedDuration == 15 &&
            favoriteClipId == "c-fav" &&
            updatedMeta?.0 == "c-meta" &&
            renamedClip?.0 == "c-ren" &&
            cameraLayout?.0 == "bottomLeft" &&
            pushStates == [true]
        }

        XCTAssertEqual(updatedMeta?.1, true)
        XCTAssertEqual(updatedMeta?.2, ["Highlight"])
        XCTAssertEqual(updatedMeta?.3, "Great clip")
        XCTAssertEqual(renamedClip?.1, "Boss Fight")
        XCTAssertEqual(cameraLayout?.1, "medium")

        // Dropping the client mid-hold must automatically release push-to-mute.
        client.close()
        try await waitUntil { pushStates == [true, false] }
    }

    func testAudioLevelSubscriptionLifecycleAndFeedbackBroadcast() async throws {
        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }

        var subHistory: [Bool] = []
        server.onAudioLevelSubscriptionChanged = { subHistory.append($0) }
        server.audioLevelProvider = { (microphone: 0.42, systemAudio: 0.65) }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "dev-v2")
        defer { client.close() }
        _ = try await client.signIn(secret: secret)
        _ = try await client.receiveData() // snapshot

        try await client.send(CompanionClientMessage(type: "subscribe_audio_levels"))
        try await waitUntil { subHistory == [true] }

        let levels = try await client.receive(CompanionAudioLevelsMessage.self)
        XCTAssertEqual(levels.type, "audio_levels")
        XCTAssertEqual(levels.microphone, 0.42, accuracy: 0.001)
        XCTAssertEqual(levels.systemAudio, 0.65, accuracy: 0.001)

        try await client.send(CompanionClientMessage(type: "unsubscribe_audio_levels"))
        try await waitUntil { subHistory == [true, false] }

        server.broadcastActionFeedback(kind: .error, title: "Disk Full", message: "Free up space.")
        // Drain any audio_levels message that was already in flight before unsubscribe.
        var receivedFeedback: CompanionActionFeedbackMessage?
        for _ in 0..<5 {
            let data = try await client.receiveData()
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if obj?["type"] as? String == "action_feedback" {
                receivedFeedback = try JSONDecoder().decode(CompanionActionFeedbackMessage.self, from: data)
                break
            }
        }
        XCTAssertEqual(receivedFeedback?.kind, "error")
        XCTAssertEqual(receivedFeedback?.title, "Disk Full")
    }

    func testRequestClipMediaReturnsTokenOrError() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CompanionMediaTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clipURL = tempDir.appendingPathComponent("SampleClip.mp4")
        let payload = Data("fake-mp4-data".utf8)
        try payload.write(to: clipURL)

        let server = try await startTestServer(pairing: pairing, defaults: defaults)
        defer { server.stop() }
        try await waitUntil { server.mediaServer.isRunning && server.mediaPort != 0 }

        server.onResolveClipMediaURL = { clipId in
            clipId == "clip-found" ? clipURL : nil
        }

        let client = CompanionTestClient(port: server.listeningPort, deviceId: "dev-v2")
        defer { client.close() }
        _ = try await client.signIn(secret: secret)
        _ = try await client.receiveData() // snapshot

        try await client.send(CompanionClientMessage(type: "request_clip_media", clipId: "clip-missing"))
        let missingResp = try await client.receive(CompanionClipMediaResponse.self)
        XCTAssertEqual(missingResp.clipId, "clip-missing")
        XCTAssertNotNil(missingResp.error)
        XCTAssertNil(missingResp.token)

        try await client.send(CompanionClientMessage(type: "request_clip_media", clipId: "clip-found"))
        let foundResp = try await client.receive(CompanionClipMediaResponse.self)
        XCTAssertEqual(foundResp.clipId, "clip-found")
        XCTAssertEqual(foundResp.httpPort, server.mediaPort)
        XCTAssertEqual(foundResp.token?.count, 64)
        XCTAssertEqual(foundResp.filename, "SampleClip.mp4")
        XCTAssertEqual(foundResp.fileSize, Int64(payload.count))
        XCTAssertEqual(foundResp.mimeType, "video/mp4")
        XCTAssertNil(foundResp.error)
    }
}

final class CompanionMediaServerTests: XCTestCase {
    func testHTTPRangeParser() {
        XCTAssertEqual(HTTPRangeParser.parse("bytes=0-9", fileSize: 100), .success(0...9))
        XCTAssertEqual(HTTPRangeParser.parse("bytes=50-", fileSize: 100), .success(50...99))
        XCTAssertEqual(HTTPRangeParser.parse("bytes=-20", fileSize: 100), .success(80...99))
        XCTAssertEqual(HTTPRangeParser.parse("bytes=-200", fileSize: 100), .success(0...99))
        XCTAssertEqual(HTTPRangeParser.parse("bytes=0-999", fileSize: 100), .success(0...99))
        XCTAssertEqual(HTTPRangeParser.parse("bytes=100-120", fileSize: 100), .failure(.unsatisfiable))
        XCTAssertEqual(HTTPRangeParser.parse("bytes=0-0", fileSize: 0), .failure(.unsatisfiable))
        XCTAssertEqual(HTTPRangeParser.parse("bytes=10-5", fileSize: 100), .failure(.invalidSyntax))
        XCTAssertEqual(HTTPRangeParser.parse("items=0-5", fileSize: 100), .failure(.invalidSyntax))
    }

    func testTokenStoreScopingAndExpiry() {
        let store = CompanionMediaTokenStore(ttl: 60)
        let url = URL(fileURLWithPath: "/tmp/test.mp4")
        let t0 = Date(timeIntervalSince1970: 1000)
        let token = store.issueToken(for: "clip-1", fileURL: url, now: t0)
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(store.resolve(token: token, clipId: "clip-1", now: t0.addingTimeInterval(30)), url)
        XCTAssertNil(store.resolve(token: token, clipId: "clip-2", now: t0.addingTimeInterval(30)))
        XCTAssertNil(store.resolve(token: token, clipId: "clip-1", now: t0.addingTimeInterval(61)))
    }

    @MainActor
    func testHTTPStreamingRangeAuthAndMissingFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MediaHTTPTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Larger than one 64 KB chunk to exercise multi-chunk asynchronous streaming.
        var payload = Data(count: 150_000)
        for index in payload.indices {
            payload[index] = UInt8(index & 0xFF)
        }
        let fileURL = tempDir.appendingPathComponent("Video.mp4")
        try payload.write(to: fileURL)

        let mediaServer = CompanionMediaServer()
        mediaServer.start(preferredPort: 0)
        defer { mediaServer.stop() }
        try await waitUntil { mediaServer.isRunning && mediaServer.listeningPort != 0 }

        let token = mediaServer.issueToken(for: "clip-abc", fileURL: fileURL)
        let port = mediaServer.listeningPort
        let session = URLSession(configuration: .ephemeral)

        // 1. Full GET -> 200 OK
        let validURL = URL(string: "http://127.0.0.1:\(port)/clips/clip-abc?token=\(token)")!
        let (fullData, fullResp) = try await session.data(from: validURL)
        let httpFull = try XCTUnwrap(fullResp as? HTTPURLResponse)
        XCTAssertEqual(httpFull.statusCode, 200)
        XCTAssertEqual(httpFull.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(httpFull.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(fullData, payload)

        // 2. HEAD -> 200 OK, empty body, Content-Length = total
        var headReq = URLRequest(url: validURL)
        headReq.httpMethod = "HEAD"
        let (headData, headResp) = try await session.data(for: headReq)
        let httpHead = try XCTUnwrap(headResp as? HTTPURLResponse)
        XCTAssertEqual(httpHead.statusCode, 200)
        XCTAssertEqual(httpHead.value(forHTTPHeaderField: "Content-Length"), "\(payload.count)")
        XCTAssertTrue(headData.isEmpty)

        // 3. Range GET -> 206 Partial Content
        var rangeReq = URLRequest(url: validURL)
        rangeReq.setValue("bytes=1000-2099", forHTTPHeaderField: "Range")
        let (rangeData, rangeResp) = try await session.data(for: rangeReq)
        let httpRange = try XCTUnwrap(rangeResp as? HTTPURLResponse)
        XCTAssertEqual(httpRange.statusCode, 206)
        XCTAssertEqual(httpRange.value(forHTTPHeaderField: "Content-Range"), "bytes 1000-2099/\(payload.count)")
        XCTAssertEqual(rangeData, payload[1000...2099])

        // 4. Unsatisfiable Range -> 416
        var badRangeReq = URLRequest(url: validURL)
        badRangeReq.setValue("bytes=999999-", forHTTPHeaderField: "Range")
        let (_, badRangeResp) = try await session.data(for: badRangeReq)
        XCTAssertEqual((badRangeResp as? HTTPURLResponse)?.statusCode, 416)

        // 5. Bad token / wrong clipId -> 401
        let badTokenURL = URL(string: "http://127.0.0.1:\(port)/clips/clip-abc?token=wrong")!
        let (_, badTokenResp) = try await session.data(from: badTokenURL)
        XCTAssertEqual((badTokenResp as? HTTPURLResponse)?.statusCode, 401)

        let wrongClipURL = URL(string: "http://127.0.0.1:\(port)/clips/other-clip?token=\(token)")!
        let (_, wrongClipResp) = try await session.data(from: wrongClipURL)
        XCTAssertEqual((wrongClipResp as? HTTPURLResponse)?.statusCode, 401)

        // 6. Missing file on disk -> 404
        try FileManager.default.removeItem(at: fileURL)
        let (_, missingFileResp) = try await session.data(from: validURL)
        XCTAssertEqual((missingFileResp as? HTTPURLResponse)?.statusCode, 404)
    }

    @MainActor
    func testMediaServerFallsBackToEphemeralPortWhenPreferredBusy() async throws {
        let blocker = try NWListener(using: .tcp, on: 0)
        blocker.newConnectionHandler = { $0.cancel() }
        let queue = DispatchQueue(label: "test.port.blocker")
        blocker.start(queue: queue)
        defer { blocker.cancel() }
        try await waitUntil { blocker.port != nil && blocker.port?.rawValue != 0 }
        let busyPort = try XCTUnwrap(blocker.port?.rawValue)

        let mediaServer = CompanionMediaServer()
        mediaServer.start(preferredPort: busyPort)
        defer { mediaServer.stop() }
        try await waitUntil { mediaServer.isRunning && mediaServer.listeningPort != 0 }
        XCTAssertNotEqual(mediaServer.listeningPort, busyPort)
    }
}
