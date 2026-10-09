import Foundation
import Network
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

@MainActor
public final class CompanionServer: ObservableObject {
    public static let shared = CompanionServer()
    public static let defaultPort: UInt16 = 7375
    public static let bonjourServiceType = "_replaymac._tcp"
    /// Bonjour TXT key that carries ``serverId``.
    public static let serverIdTXTKey = "id"
    static let serverIdDefaultsKey = "companionServerId"

    /// Stays the same across launches and networks; paired phones use it to find this Mac again.
    public let serverId: String

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var listeningPort: UInt16 = defaultPort
    @Published public private(set) var connectedClientsCount: Int = 0
    @Published public private(set) var connectedDeviceIds: Set<String> = []
    @Published public private(set) var localIPAddresses: [String] = []

    public func isDeviceConnected(id: String) -> Bool {
        connectedDeviceIds.contains(id)
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
    public var onGetThumbnail: (@MainActor (String) async -> Data?)?
    public var snapshotProvider: (@MainActor () -> CompanionStateSnapshot)?

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.replaymac.companion-server", qos: .userInitiated)
    private var activeConnections: [UUID: NWConnection] = [:]
    private var connectionDevices: [UUID: String] = [:]
    private let pairingManager: CompanionPairingManager

    public init(pairingManager: CompanionPairingManager = .shared, defaults: UserDefaults = .standard) {
        self.pairingManager = pairingManager
        self.serverId = Self.loadOrCreateServerId(in: defaults)
        self.localIPAddresses = Self.resolveLocalIPAddresses()
        self.pairingManager.onDeviceRevoked = { [weak self] revokedId in
            self?.handleDeviceRevoked(revokedId)
        }
    }

    public func start(port: UInt16 = defaultPort) throws {
        guard !isRunning && listener == nil else { return }

        let tcpOptions = NWProtocolTCP.Options()
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        parameters.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw CompanionServerError.invalidPort
        }

        let newListener = try NWListener(using: parameters, on: endpointPort)
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
        self.localIPAddresses = Self.resolveLocalIPAddresses()
    }

    public func stop() {
        guard isRunning || listener != nil else { return }

        for (_, connection) in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        connectionDevices.removeAll()
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
        case .failed(let error):
            print("CompanionServer failed: \(error)")
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = UUID()
        activeConnections[connectionId] = connection

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
        if let conn = activeConnections.removeValue(forKey: connectionId) {
            conn.cancel()
        }
        connectionDevices.removeValue(forKey: connectionId)
        updateConnectedClients()
    }

    private func handleDeviceRevoked(_ deviceId: String) {
        let matching = connectionDevices.filter { $0.value == deviceId }
        for (connId, _) in matching {
            if let conn = activeConnections[connId] {
                send(authResponse(status: "denied"), to: conn)
                conn.cancel()
            }
            activeConnections.removeValue(forKey: connId)
            connectionDevices.removeValue(forKey: connId)
        }
        updateConnectedClients()
    }

    private func updateConnectedClients() {
        connectedClientsCount = connectionDevices.count
        connectedDeviceIds = Set(connectionDevices.values)
    }

    // MARK: - Message Handling

    private func handleIncomingData(_ data: Data, connectionId: UUID, connection: NWConnection) {
        guard let message = try? JSONDecoder().decode(CompanionClientMessage.self, from: data) else {
            return
        }

        switch message.type {
        case CompanionClientMessageType.hello.rawValue:
            handleHello(message, connectionId: connectionId, connection: connection)

        case CompanionClientMessageType.ping.rawValue:
            send(CompanionPongMessage(), to: connection)

        default:
            guard connectionDevices[connectionId] != nil else {
                send(CompanionErrorMessage(message: "Device not authorized"), to: connection)
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
        guard activeConnections[connectionId] != nil else { return }

        let rawId = message.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceId = (rawId?.isEmpty == false) ? rawId! : connectionId.uuidString
        let rawName = message.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = (rawName?.isEmpty == false) ? rawName! : "Android Device"

        // Cancel previous stale connection for same deviceId
        let staleConnections = connectionDevices.filter { $0.key != connectionId && $0.value == deviceId }
        for (staleId, _) in staleConnections {
            if let staleConn = activeConnections.removeValue(forKey: staleId) {
                staleConn.cancel()
            }
            connectionDevices.removeValue(forKey: staleId)
        }

        if pairingManager.isDeviceApproved(id: deviceId) {
            connectionDevices[connectionId] = deviceId
            updateConnectedClients()
            send(
                authResponse(status: "approved"),
                to: connection
            )
            if let snapshot = snapshotProvider?() {
                send(snapshot, to: connection)
            }
        } else {
            send(
                authResponse(status: "pending"),
                to: connection
            )

            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection else { return }
                let approved = await self.pairingManager.promptApprovalForDevice(id: deviceId, name: deviceName)
                guard self.activeConnections[connectionId] != nil else { return }

                if approved {
                    self.connectionDevices[connectionId] = deviceId
                    self.updateConnectedClients()
                    self.send(
                        authResponse(status: "approved"),
                        to: connection
                    )
                    if let snapshot = self.snapshotProvider?() {
                        self.send(snapshot, to: connection)
                    }
                } else {
                    self.send(
                        authResponse(status: "denied"),
                        to: connection
                    )
                    self.handleConnectionDisconnection(connectionId: connectionId)
                }
            }
        }
    }

    // MARK: - Identity

    private var serverName: String {
        Host.current().localizedName ?? AppBranding.name
    }

    private func authResponse(status: String) -> CompanionAuthResponse {
        CompanionAuthResponse(
            status: status,
            serverName: serverName,
            serverVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.7.3",
            serverId: serverId
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

    nonisolated private func send<T: Encodable>(_ message: T, to connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error {
                print("CompanionServer: failed to send message: \(error)")
            }
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
            recentClips: snapshot.recentClips
        )
        broadcast(changed)
    }

    private func broadcast<T: Encodable>(_ message: T) {
        guard isRunning, !connectionDevices.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(message) else { return }

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
