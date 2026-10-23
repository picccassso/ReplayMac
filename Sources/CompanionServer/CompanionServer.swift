import Foundation
import Network
import os.log
import AppKit
import Branding

public enum CompanionServerError: Error, LocalizedError {
    case invalidPort
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Invalid port number."
        case .listenerFailed(let reason):
            return "Server listener failed: \(reason)"
        }
    }
}

// File scope so the nonisolated send path can log without hopping to the main actor.
private let logger = Logger(subsystem: "com.replaycap", category: "CompanionServer")

@MainActor
public final class CompanionServer: ObservableObject {
    public static let shared = CompanionServer()
    public static let defaultPort: UInt16 = 7375
    public static let bonjourServiceType = "_replaymac._tcp"
    /// Bonjour TXT key that carries ``serverId``.
    public static let serverIdTXTKey = "id"
    static let serverIdDefaultsKey = "companionServerId"
    /// Phones, tablets and anything else on the network, signed in or not.
    static let maxConnections = 16
    /// Phones only ever send small JSON commands.
    static let maxMessageSize = 64 * 1024

    /// Stays the same across launches and networks; paired phones use it to find this Mac again.
    public let serverId: String

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var listeningPort: UInt16 = defaultPort
    @Published public private(set) var connectedClientsCount: Int = 0
    @Published public private(set) var connectedDeviceIds: Set<String> = []
    @Published public private(set) var localIPAddresses: [String] = []
    /// Why the server isn't running, in words for the settings screen.
    @Published public private(set) var lastError: String?

    public func isDeviceConnected(id: String) -> Bool {
        connectedDeviceIds.contains(id)
    }

    /// The Mac's addresses change with the network; call before showing them.
    public func refreshLocalIPAddresses() {
        localIPAddresses = Self.resolveLocalIPAddresses()
    }

    // Callback hooks for application integration
    public var onSaveReplay: (@MainActor () -> Void)?
    public var onSaveExtendedReplay: (@MainActor () -> Void)?
    public var onToggleBuffer: (@MainActor () -> Void)?
    public var onToggleSession: (@MainActor () -> Void)?
    public var onToggleMicrophone: (@MainActor () -> Void)?
    public var onToggleSystemAudio: (@MainActor () -> Void)?
    public var onRevealClip: (@MainActor (String) -> Void)?
    public var onDeleteClip: (@MainActor (String) -> Void)?
    public var onTrimClip: (@MainActor (String) -> Void)?
    public var onCopyClip: (@MainActor (String) -> Void)?
    public var onSetVolume: (@MainActor (String, Double) -> Void)?
    public var onToggleAppMute: (@MainActor (String) -> Void)?
    public var onUnmuteAllApps: (@MainActor () -> Void)?
    public var onSelectDisplay: (@MainActor (String) -> Void)?
    public var onApplyProfile: (@MainActor (String) -> Void)?
    public var onGetThumbnail: (@MainActor (String) async -> Data?)?
    public var snapshotProvider: (@MainActor () -> CompanionStateSnapshot)?

    /// How long a connection may take to send `hello` and answer the challenge.
    var authDeadline: TimeInterval = 10
    /// How long a phone must wait to ask again after the user denies it or ignores the prompt.
    var pairingCooldown: TimeInterval = 30

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.replaymac.companion-server", qos: .userInitiated)
    private var activeConnections: [UUID: NWConnection] = [:]
    /// Connections that have signed in, and the device each belongs to.
    private var connectionDevices: [UUID: String] = [:]
    /// Connections still signing in.
    private var pendingAuth: [UUID: PendingAuth] = [:]
    /// The one pairing request the Mac is currently prompting for.
    private var pairingRequest: PairingRequest?
    private var pairingCooldowns: [String: Date] = [:]
    private let pairingManager: CompanionPairingManager
    private let defaults: UserDefaults

    private enum PendingAuth {
        case awaitingHello
        case awaitingProof(deviceId: String, deviceName: String, nonce: String)
        case awaitingApproval(deviceId: String)
    }

    private struct PairingRequest {
        let deviceId: String
        let deviceName: String
        let code: String
        var connectionId: UUID
    }

    public init(pairingManager: CompanionPairingManager = .shared, defaults: UserDefaults = .standard) {
        self.pairingManager = pairingManager
        self.defaults = defaults
        self.serverId = Self.loadOrCreateServerId(in: defaults)
        self.localIPAddresses = Self.resolveLocalIPAddresses()
        self.pairingManager.onDeviceRevoked = { [weak self] revokedId in
            self?.handleDeviceRevoked(revokedId)
        }
        self.pairingManager.onDeviceRenamed = { [weak self] id, newName in
            self?.handleDeviceRenamed(id: id, newName: newName)
        }
    }

    public func start(port: UInt16 = defaultPort) throws {
        guard !isRunning && listener == nil else { return }

        let tcpOptions = NWProtocolTCP.Options()
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = Self.maxMessageSize

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        parameters.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            lastError = CompanionServerError.invalidPort.errorDescription
            throw CompanionServerError.invalidPort
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: endpointPort)
        } catch {
            lastError = Self.describe(error, port: port)
            throw error
        }
        newListener.service = NWListener.Service(
            name: serverName,
            type: Self.bonjourServiceType,
            domain: nil,
            txtRecord: NWTXTRecord([Self.serverIdTXTKey: serverId])
        )

        newListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleListenerState(state)
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handleNewConnection(connection)
            }
        }

        newListener.start(queue: serverQueue)
        self.listener = newListener
        self.listeningPort = port
        self.lastError = nil
        self.localIPAddresses = Self.resolveLocalIPAddresses()
    }

    public func stop() {
        guard isRunning || listener != nil else { return }

        if let request = pairingRequest {
            pairingRequest = nil
            pairingManager.cancelPrompt(for: request.deviceId)
        }
        for (_, connection) in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        connectionDevices.removeAll()
        pendingAuth.removeAll()
        connectedClientsCount = 0
        connectedDeviceIds.removeAll()

        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - State & Connection Management

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
            // Port 0 asks the system for any free port; report the real one.
            if let actualPort = listener?.port?.rawValue {
                listeningPort = actualPort
            }
        case .failed(let error):
            logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            stop()
            lastError = Self.describe(error, port: listeningPort)
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    static func describe(_ error: Error, port: UInt16) -> String {
        if let nwError = error as? NWError, case .posix(let code) = nwError {
            switch code {
            case .EADDRINUSE:
                return "Port \(port) is already in use by another app. Choose a different port."
            case .EACCES, .EPERM:
                return "macOS didn't allow ReplayCap to listen on port \(port)."
            default:
                break
            }
        }
        return "The companion server couldn't start: \(error.localizedDescription)"
    }

    private func handleNewConnection(_ connection: NWConnection) {
        guard activeConnections.count < Self.maxConnections else {
            connection.cancel()
            return
        }

        let connectionId = UUID()
        activeConnections[connectionId] = connection
        pendingAuth[connectionId] = .awaitingHello

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receiveNextMessage(on: connection, connectionId: connectionId)
            case .failed, .cancelled:
                Task { @MainActor in
                    self.handleConnectionDisconnection(connectionId: connectionId)
                }
            default:
                break
            }
        }

        connection.start(queue: serverQueue)
        enforceAuthDeadline(for: connectionId)
    }

    /// Drops connections that open a socket and never finish signing in. A
    /// connection waiting on the user's Allow prompt is covered by the prompt's
    /// own timeout instead.
    private func enforceAuthDeadline(for connectionId: UUID) {
        let deadline = authDeadline
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard let self, let state = self.pendingAuth[connectionId] else { return }
            switch state {
            case .awaitingHello, .awaitingProof:
                self.reject(connectionId, .timeout, "The connection took too long to sign in. Try again.")
            case .awaitingApproval:
                break
            }
        }
    }

    nonisolated private func receiveNextMessage(on connection: NWConnection, connectionId: UUID) {
        connection.receiveMessage { [weak self, weak connection] content, context, isComplete, error in
            guard let self, let connection else { return }

            if error != nil {
                Task { @MainActor in
                    self.handleConnectionDisconnection(connectionId: connectionId)
                }
                return
            }

            // Check for WebSocket close frame
            if let wsMetadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               wsMetadata.opcode == .close {
                Task { @MainActor in
                    self.handleConnectionDisconnection(connectionId: connectionId)
                }
                return
            }

            // Check for EOF. Ping and pong frames also arrive complete with no
            // content, so only a final context means the peer has gone.
            if content == nil && isComplete && (context?.isFinal ?? true) {
                Task { @MainActor in
                    self.handleConnectionDisconnection(connectionId: connectionId)
                }
                return
            }

            if let data = content, !data.isEmpty {
                Task { @MainActor in
                    self.handleIncomingData(data, connectionId: connectionId, connection: connection)
                }
            }

            if connection.state == .ready {
                self.receiveNextMessage(on: connection, connectionId: connectionId)
            }
        }
    }

    private func handleConnectionDisconnection(connectionId: UUID) {
        if let conn = activeConnections[connectionId] {
            conn.cancel()
        }
        forget(connectionId)
    }

    /// Removes every trace of a connection without touching the socket.
    private func forget(_ connectionId: UUID) {
        activeConnections.removeValue(forKey: connectionId)
        pendingAuth.removeValue(forKey: connectionId)
        let wasSignedIn = connectionDevices.removeValue(forKey: connectionId) != nil
        if let request = pairingRequest, request.connectionId == connectionId {
            // The phone gave up, so the prompt has no one to answer to.
            pairingRequest = nil
            pairingManager.cancelPrompt(for: request.deviceId)
        }
        if wasSignedIn {
            updateConnectedClients()
        }
    }

    /// Sends a last message, then closes the connection once it's on the wire.
    private func sendThenClose<T: Encodable>(_ message: T, connectionId: UUID) {
        guard let connection = activeConnections[connectionId] else { return }
        forget(connectionId)
        send(message, to: connection) {
            connection.cancel()
        }
    }

    private func reject(_ connectionId: UUID, _ code: CompanionErrorCode, _ message: String) {
        sendThenClose(CompanionErrorMessage(code, message: message), connectionId: connectionId)
    }

    private func deny(_ connectionId: UUID, reason: CompanionDenialReason, deviceName: String? = nil) {
        sendThenClose(authResponse(status: "denied", deviceName: deviceName, reason: reason), connectionId: connectionId)
    }

    private func handleDeviceRevoked(_ deviceId: String) {
        let signedIn = connectionDevices.filter { $0.value == deviceId }.map(\.key)
        let signingIn = pendingAuth.compactMap { id, state -> UUID? in
            if case .awaitingProof(let pendingId, _, _) = state, pendingId == deviceId { return id }
            return nil
        }
        for connId in signedIn + signingIn {
            deny(connId, reason: .revoked)
        }
    }

    private func updateConnectedClients() {
        connectedClientsCount = connectionDevices.count
        connectedDeviceIds = Set(connectionDevices.values)
    }

    // MARK: - Message Handling

    private func handleIncomingData(_ data: Data, connectionId: UUID, connection: NWConnection) {
        guard activeConnections[connectionId] != nil else { return }
        let message: CompanionClientMessage
        do {
            message = try JSONDecoder().decode(CompanionClientMessage.self, from: data)
        } catch {
            // Dropped either way, but a phone on a mismatched protocol would
            // otherwise just look unresponsive. The payload is not logged.
            logger.warning("Ignoring undecodable message bytes=\(data.count, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        switch message.type {
        case CompanionClientMessageType.hello.rawValue:
            handleHello(message, connectionId: connectionId, connection: connection)

        case CompanionClientMessageType.authProof.rawValue:
            handleProof(message, connectionId: connectionId)

        case CompanionClientMessageType.ping.rawValue:
            send(CompanionPongMessage(), to: connection)

        default:
            guard connectionDevices[connectionId] != nil else {
                send(CompanionErrorMessage(.notAuthorized, message: "Device not authorized"), to: connection)
                return
            }

            let actionName = (message.type == "action" ? message.action : message.type) ?? message.type

            switch actionName {
            case "saveReplay", "save_replay":
                onSaveReplay?()
            case "saveExtendedReplay", "save_extended_replay":
                onSaveExtendedReplay?()
            case "toggleBuffer", "toggle_buffer":
                onToggleBuffer?()
            case "toggleSession", "toggle_session":
                onToggleSession?()
            case "toggleMicrophone", "toggle_microphone":
                onToggleMicrophone?()
            case "toggleSystemAudio", "toggle_system_audio":
                onToggleSystemAudio?()
            case "reveal_clip", "revealClip":
                if let clipId = message.clipId {
                    onRevealClip?(clipId)
                }
            case "delete_clip", "deleteClip":
                if let clipId = message.clipId {
                    onDeleteClip?(clipId)
                }
            case "trim_clip", "trimClip":
                if let clipId = message.clipId {
                    onTrimClip?(clipId)
                }
            case "copy_clip", "copyClip":
                if let clipId = message.clipId {
                    onCopyClip?(clipId)
                }
            case "set_volume", "setVolume":
                if let target = message.target, let volume = message.volume {
                    onSetVolume?(target, volume)
                }
            case "toggle_app_mute", "toggleAppMute":
                if let bundleId = message.bundleId {
                    onToggleAppMute?(bundleId)
                }
            case "unmute_all_apps", "unmuteAllApps":
                onUnmuteAllApps?()
            case "select_display", "selectDisplay":
                if let displayId = message.displayId {
                    onSelectDisplay?(displayId)
                }
            case "apply_profile", "applyProfile":
                if let profileId = message.profileId {
                    onApplyProfile?(profileId)
                }
            case "get_thumbnail", "getThumbnail":
                if let clipId = message.clipId {
                    Task { @MainActor in
                        let base64 = await self.onGetThumbnail?(clipId)
                        self.send(
                            CompanionThumbnailResponse(
                                clipId: clipId,
                                thumbnailBase64: base64?.base64EncodedString()
                            ),
                            to: connection
                        )
                    }
                }
            default:
                break
            }
        }
    }

    private func handleHello(_ message: CompanionClientMessage, connectionId: UUID, connection: NWConnection) {
        guard (message.protocolVersion ?? 1) >= CompanionAuth.protocolVersion else {
            reject(connectionId, .unsupportedClient, "Update ReplayCap Companion on this device to connect.")
            return
        }
        guard let deviceId = CompanionAuth.sanitizedDeviceId(message.deviceId) else {
            reject(connectionId, .unsupportedClient, "This device didn't send a valid ID.")
            return
        }
        let deviceName = CompanionAuth.sanitizedDeviceName(message.deviceName) ?? "Companion Device"

        // Already signed in: the phone came back to the foreground and wants fresh state.
        if let signedInDevice = connectionDevices[connectionId] {
            guard signedInDevice == deviceId else {
                reject(connectionId, .unsupportedClient, "This connection belongs to another device.")
                return
            }
            sendApproval(to: connection, deviceId: deviceId, deviceName: deviceName, newSecret: nil)
            return
        }

        // Don't let an extra hello reset a prompt already on screen.
        if case .awaitingApproval(let pendingId) = pendingAuth[connectionId], pendingId == deviceId {
            return
        }

        if pairingManager.secret(for: deviceId) != nil {
            let nonce = CompanionAuth.makeNonce()
            pendingAuth[connectionId] = .awaitingProof(deviceId: deviceId, deviceName: deviceName, nonce: nonce)
            send(
                CompanionAuthChallenge(nonce: nonce, serverId: serverId, serverName: serverName, serverVersion: serverVersion),
                to: connection
            )
        } else {
            beginPairing(connectionId: connectionId, deviceId: deviceId, deviceName: deviceName)
        }
    }

    private func handleProof(_ message: CompanionClientMessage, connectionId: UUID) {
        guard case .awaitingProof(let deviceId, let deviceName, let nonce) = pendingAuth[connectionId] else {
            return
        }

        // The phone has lost its secret (reinstalled, restored, or reset), so
        // the user decides again, exactly as for a new phone.
        guard message.proof != nil else {
            beginPairing(connectionId: connectionId, deviceId: deviceId, deviceName: deviceName)
            return
        }

        guard let secret = pairingManager.secret(for: deviceId),
              CompanionAuth.isValidProof(message.proof, secret: secret, serverId: serverId, deviceId: deviceId, nonce: nonce) else {
            deny(connectionId, reason: .invalidProof, deviceName: deviceName)
            return
        }

        pairingManager.refreshReportedName(id: deviceId, name: deviceName)
        authorize(connectionId: connectionId, deviceId: deviceId, deviceName: deviceName, newSecret: nil)
    }

    // MARK: - Pairing

    private func beginPairing(connectionId: UUID, deviceId: String, deviceName: String) {
        let now = Date()
        pairingCooldowns = pairingCooldowns.filter { $0.value > now }
        if pairingCooldowns[deviceId] != nil {
            reject(connectionId, .cooldown, "Pairing was declined on the Mac. Try again in a moment.")
            return
        }

        if var request = pairingRequest {
            guard request.deviceId == deviceId else {
                reject(connectionId, .busy, "Another device is waiting for approval on the Mac. Try again in a moment.")
                return
            }
            // The same phone reconnected while its prompt is up: keep the
            // prompt and code, and answer on the newest connection.
            let previousConnection = request.connectionId
            request.connectionId = connectionId
            pairingRequest = request
            pendingAuth[connectionId] = .awaitingApproval(deviceId: deviceId)
            if previousConnection != connectionId {
                handleConnectionDisconnection(connectionId: previousConnection)
            }
            if let connection = activeConnections[connectionId] {
                send(authResponse(status: "pending", deviceName: deviceName, pairingCode: request.code), to: connection)
            }
            return
        }

        let code = CompanionAuth.makePairingCode()
        pairingRequest = PairingRequest(deviceId: deviceId, deviceName: deviceName, code: code, connectionId: connectionId)
        pendingAuth[connectionId] = .awaitingApproval(deviceId: deviceId)
        if let connection = activeConnections[connectionId] {
            send(authResponse(status: "pending", deviceName: deviceName, pairingCode: code), to: connection)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.pairingManager.requestApproval(id: deviceId, name: deviceName, code: code)
            self.finishPairing(deviceId: deviceId, code: code, result: result)
        }
    }

    private func finishPairing(deviceId: String, code: String, result: PairingPromptResult) {
        guard let request = pairingRequest, request.deviceId == deviceId, request.code == code else { return }
        pairingRequest = nil
        let connectionId = request.connectionId

        switch result {
        case .approved:
            let secret = pairingManager.approveDevice(id: deviceId, name: request.deviceName)
            authorize(connectionId: connectionId, deviceId: deviceId, deviceName: request.deviceName, newSecret: secret)
        case .denied:
            pairingCooldowns[deviceId] = Date().addingTimeInterval(pairingCooldown)
            deny(connectionId, reason: .userDenied, deviceName: request.deviceName)
        case .timedOut:
            pairingCooldowns[deviceId] = Date().addingTimeInterval(pairingCooldown)
            reject(connectionId, .timeout, "Nobody answered on the Mac. Try again when you're next to it.")
        case .cancelled:
            reject(connectionId, .busy, "The Mac couldn't show the approval prompt. Try again.")
        }
    }

    private func authorize(connectionId: UUID, deviceId: String, deviceName: String, newSecret: Data?) {
        guard let connection = activeConnections[connectionId] else { return }
        pendingAuth.removeValue(forKey: connectionId)

        // Only now that this connection has proved itself may it replace the
        // phone's older ones; otherwise anyone who knew a device id could kick
        // that phone offline.
        for (staleId, staleDevice) in connectionDevices where staleDevice == deviceId && staleId != connectionId {
            handleConnectionDisconnection(connectionId: staleId)
        }

        connectionDevices[connectionId] = deviceId
        updateConnectedClients()
        sendApproval(to: connection, deviceId: deviceId, deviceName: deviceName, newSecret: newSecret)
    }

    private func sendApproval(to connection: NWConnection, deviceId: String, deviceName: String, newSecret: Data?) {
        let resolvedName = pairingManager.device(for: deviceId)?.name ?? deviceName
        send(
            authResponse(status: "approved", deviceName: resolvedName, pairingSecret: newSecret?.base64EncodedString()),
            to: connection
        )
        if let snapshot = snapshotProvider?() {
            send(snapshot, to: connection)
        }
    }

    // MARK: - Identity

    public static let serverNameDefaultsKey = "companionCustomServerName"

    public var serverName: String {
        let custom = defaults.string(forKey: Self.serverNameDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty {
            return custom
        }
        return Host.current().localizedName ?? AppBranding.name
    }

    public func updateServerName(_ newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            defaults.removeObject(forKey: Self.serverNameDefaultsKey)
        } else {
            defaults.set(clean, forKey: Self.serverNameDefaultsKey)
        }

        if let listener {
            listener.service = NWListener.Service(
                name: serverName,
                type: Self.bonjourServiceType,
                domain: nil,
                txtRecord: NWTXTRecord([Self.serverIdTXTKey: serverId])
            )
        }

        // Signed-in phones only: a phone still waiting on the Allow prompt
        // must never see "approved" before the user has answered.
        for (connId, devId) in connectionDevices {
            guard let conn = activeConnections[connId] else { continue }
            let devName = pairingManager.device(for: devId)?.name
            send(authResponse(status: "approved", deviceName: devName), to: conn)
        }
    }

    private func handleDeviceRenamed(id: String, newName: String) {
        for (connId, devId) in connectionDevices where devId == id {
            if let conn = activeConnections[connId] {
                send(
                    authResponse(status: "approved", deviceName: newName),
                    to: conn
                )
            }
        }
    }

    private var serverVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func authResponse(
        status: String,
        deviceName: String? = nil,
        pairingCode: String? = nil,
        pairingSecret: String? = nil,
        reason: CompanionDenialReason? = nil
    ) -> CompanionAuthResponse {
        CompanionAuthResponse(
            status: status,
            serverName: serverName,
            serverVersion: serverVersion,
            serverId: serverId,
            deviceName: deviceName,
            pairingCode: pairingCode,
            pairingSecret: pairingSecret,
            reason: reason?.rawValue
        )
    }

    static func loadOrCreateServerId(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: serverIdDefaultsKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: serverIdDefaultsKey)
        return created
    }

    // MARK: - Sending & Broadcasting

    nonisolated private func send<T: Encodable>(
        _ message: T,
        to connection: NWConnection,
        then completion: (@Sendable () -> Void)? = nil
    ) {
        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            logger.error("Could not encode \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
            completion?()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error {
                logger.error("Failed to send message: \(error.localizedDescription, privacy: .public)")
            }
            completion?()
        })
    }

    public func broadcastSnapshot(_ snapshot: CompanionStateSnapshot) {
        broadcast(snapshot)
    }

    public func broadcastTelemetryTick(_ tick: CompanionTelemetryTick) {
        broadcast(tick)
    }

    public func broadcastStateChanged(_ snapshot: CompanionStateSnapshot) {
        let changed = CompanionStateSnapshot(
            type: "state_changed",
            isRecording: snapshot.isRecording,
            isSessionRecording: snapshot.isSessionRecording,
            saveStatus: snapshot.saveStatus,
            recordingElapsedSeconds: snapshot.recordingElapsedSeconds,
            extendedBufferElapsedSeconds: snapshot.extendedBufferElapsedSeconds,
            sessionElapsedSeconds: snapshot.sessionElapsedSeconds,
            bufferedSeconds: snapshot.bufferedSeconds,
            bufferDurationSeconds: snapshot.bufferDurationSeconds,
            bufferMemoryBytes: snapshot.bufferMemoryBytes,
            bufferMemoryFormatted: snapshot.bufferMemoryFormatted,
            longBufferEnabled: snapshot.longBufferEnabled,
            longBufferDurationSeconds: snapshot.longBufferDurationSeconds,
            capturedDisplayName: snapshot.capturedDisplayName,
            isUsingFallbackDisplay: snapshot.isUsingFallbackDisplay,
            isMicrophoneEnabled: snapshot.isMicrophoneEnabled,
            isMicrophoneMuted: snapshot.isMicrophoneMuted,
            isSystemAudioEnabled: snapshot.isSystemAudioEnabled,
            isSystemAudioMuted: snapshot.isSystemAudioMuted,
            microphoneVolume: snapshot.microphoneVolume,
            systemAudioVolume: snapshot.systemAudioVolume,
            perAppAudioEnabled: snapshot.perAppAudioEnabled,
            audioApps: snapshot.audioApps,
            displays: snapshot.displays,
            profiles: snapshot.profiles,
            recentClips: snapshot.recentClips,
            theme: snapshot.theme
        )
        broadcast(changed)
    }

    private func broadcast<T: Encodable>(_ message: T) {
        guard isRunning, !connectionDevices.isEmpty else { return }
        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            logger.error("Could not encode broadcast \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        for (connId, _) in connectionDevices {
            if let connection = activeConnections[connId], connection.state == .ready {
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
                connection.send(
                    content: data,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] error in
                        if error != nil {
                            Task { @MainActor in
                                self?.handleConnectionDisconnection(connectionId: connId)
                            }
                        }
                    }
                )
            }
        }
    }

    // MARK: - IP Address Resolution

    nonisolated public static func resolveLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return ["127.0.0.1"]
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let p = ptr {
            let interface = p.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let flags = Int32(interface.ifa_flags)
                let isLoopback = (flags & IFF_LOOPBACK) != 0
                let isUp = (flags & IFF_UP) != 0
                if isUp && !isLoopback {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let ip = hostname.withUnsafeBufferPointer { buf in
                            buf.baseAddress.map { String(cString: $0) } ?? ""
                        }
                        if !ip.isEmpty && !addresses.contains(ip) {
                            addresses.append(ip)
                        }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return addresses.isEmpty ? ["127.0.0.1"] : addresses
    }
}
