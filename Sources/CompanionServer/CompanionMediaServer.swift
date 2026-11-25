import Foundation
import Network
import Security
import os.log

private let mediaLogger = Logger(subsystem: "com.replaycap", category: "CompanionMediaServer")

/// Pure HTTP Range header parser for single byte ranges (`bytes=start-end`,
/// `bytes=start-`, `bytes=-suffix`).
enum HTTPRangeParser {
    enum RangeError: Error, Equatable {
        case invalidSyntax
        case unsatisfiable
    }

    static func parse(_ headerValue: String, fileSize: Int64) -> Result<ClosedRange<Int64>, RangeError> {
        guard fileSize > 0 else { return .failure(.unsatisfiable) }
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes=") else {
            return .failure(.invalidSyntax)
        }
        let spec = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject multi-range requests or empty specs.
        guard !spec.isEmpty, !spec.contains(",") else {
            return .failure(.invalidSyntax)
        }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .failure(.invalidSyntax)
        }

        let startStr = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let endStr = String(parts[1]).trimmingCharacters(in: .whitespaces)

        if startStr.isEmpty {
            // Suffix byte range: bytes=-<suffixLength>
            guard let suffix = Int64(endStr), suffix > 0 else {
                return .failure(.invalidSyntax)
            }
            let start = max(0, fileSize - suffix)
            return .success(start...(fileSize - 1))
        }

        guard let start = Int64(startStr), start >= 0 else {
            return .failure(.invalidSyntax)
        }
        guard start < fileSize else {
            return .failure(.unsatisfiable)
        }

        if endStr.isEmpty {
            return .success(start...(fileSize - 1))
        }

        guard let rawEnd = Int64(endStr), rawEnd >= start else {
            return .failure(.invalidSyntax)
        }
        let end = min(rawEnd, fileSize - 1)
        return .success(start...end)
    }
}

/// Pure HTTP/1.x request-head parser for `GET` / `HEAD /clips/<clipId>?token=<token>`.
struct CompanionMediaHTTPRequest: Equatable {
    let method: String
    let clipId: String
    let token: String?
    let rangeHeader: String?

    enum ParseError: Error, Equatable {
        case badRequest
        case methodNotAllowed
        case notFound
    }

    static func parse(headerData: Data) -> Result<CompanionMediaHTTPRequest, ParseError> {
        guard let raw = String(data: headerData, encoding: .utf8) else {
            return .failure(.badRequest)
        }
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .failure(.badRequest)
        }
        let tokens = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2 else {
            return .failure(.badRequest)
        }
        let method = String(tokens[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            return .failure(.methodNotAllowed)
        }

        let target = String(tokens[1])
        guard let components = URLComponents(string: target) else {
            return .failure(.badRequest)
        }
        let path = components.path
        let prefix = "/clips/"
        guard path.hasPrefix(prefix) else {
            return .failure(.notFound)
        }
        let clipId = String(path.dropFirst(prefix.count))
        guard !clipId.isEmpty, !clipId.contains("/") else {
            return .failure(.notFound)
        }

        let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        var rangeHeader: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "range" {
                rangeHeader = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                break
            }
        }

        return .success(CompanionMediaHTTPRequest(
            method: method,
            clipId: clipId,
            token: token,
            rangeHeader: rangeHeader
        ))
    }
}

/// Thread-safe store of short-lived per-clip playback tokens.
final class CompanionMediaTokenStore: @unchecked Sendable {
    private struct Entry {
        let clipId: String
        let fileURL: URL
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 15 * 60) {
        self.ttl = ttl
    }

    func issueToken(for clipId: String, fileURL: URL, now: Date = Date()) -> String {
        let token = Self.makeRandomHexToken()
        let entry = Entry(clipId: clipId, fileURL: fileURL, expiresAt: now.addingTimeInterval(ttl))
        lock.lock()
        pruneLocked(now: now)
        entries[token] = entry
        lock.unlock()
        return token
    }

    func resolve(token: String, clipId: String, now: Date = Date()) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        guard let entry = entries[token],
              entry.expiresAt > now,
              entry.clipId.caseInsensitiveCompare(clipId) == .orderedSame else {
            return nil
        }
        return entry.fileURL
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: Date())
        return entries.count
    }

    private func pruneLocked(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }

    static func makeRandomHexToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...UInt8.max)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Lightweight local HTTP/1.1 server over `NWListener` that streams authenticated
/// MP4 clips to paired companion clients with full HTTP byte-range support.
@MainActor
public final class CompanionMediaServer {
    public static let defaultTokenTTL: TimeInterval = 15 * 60
    nonisolated private static let maxHeaderBytes = 16 * 1024
    nonisolated private static let streamChunkSize = 64 * 1024

    public private(set) var isRunning = false
    public private(set) var listeningPort: UInt16 = 0 {
        didSet {
            if oldValue != listeningPort {
                onListeningPortChanged?(listeningPort)
            }
        }
    }
    public var onListeningPortChanged: (@MainActor (UInt16) -> Void)?

    private let tokenStore: CompanionMediaTokenStore
    private let serverQueue = DispatchQueue(label: "com.replaymac.companion-media-server", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.replaymac.companion-media-io", qos: .utility)

    private var listener: NWListener?
    private var activeConnections: [UUID: NWConnection] = [:]
    private var preferredPort: UInt16 = 0
    private var didAttemptFallbackPort = false

    public init(tokenTTL: TimeInterval = CompanionMediaServer.defaultTokenTTL) {
        self.tokenStore = CompanionMediaTokenStore(ttl: tokenTTL)
    }

    /// Starts the HTTP media listener on `preferredPort` (falling back to an
    /// ephemeral port `0` if `preferredPort` is already in use).
    public func start(preferredPort: UInt16) {
        stop()
        self.preferredPort = preferredPort
        self.didAttemptFallbackPort = false
        startListener(on: preferredPort)
    }

    public func stop() {
        tokenStore.removeAll()
        for (_, connection) in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        listeningPort = 0
        preferredPort = 0
        didAttemptFallbackPort = false
    }

    public func issueToken(for clipId: String, fileURL: URL) -> String {
        tokenStore.issueToken(for: clipId, fileURL: fileURL)
    }

    var activeTokenCount: Int {
        tokenStore.activeCount
    }

    private func startListener(on port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            if port != 0 {
                didAttemptFallbackPort = true
                startListener(on: 0)
            }
            return
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: nwPort)
        } catch {
            mediaLogger.warning("Media server failed to bind port \(port, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if port != 0 && !didAttemptFallbackPort {
                didAttemptFallbackPort = true
                startListener(on: 0)
            }
            return
        }

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            Task { @MainActor [weak self, weak newListener] in
                guard let self, let newListener, self.listener === newListener else { return }
                self.handleListenerState(state, listener: newListener, requestedPort: port)
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handleNewConnection(connection)
            }
        }

        self.listener = newListener
        self.listeningPort = port
        newListener.start(queue: serverQueue)
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener, requestedPort: UInt16) {
        switch state {
        case .ready:
            isRunning = true
            if let actualPort = listener.port?.rawValue {
                listeningPort = actualPort
            }
        case .failed(let error):
            mediaLogger.warning("Media listener failed on port \(requestedPort, privacy: .public): \(error.localizedDescription, privacy: .public)")
            listener.cancel()
            self.listener = nil
            isRunning = false
            listeningPort = 0
            if requestedPort != 0 && !didAttemptFallbackPort {
                didAttemptFallbackPort = true
                startListener(on: 0)
            }
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
                self.receiveRequestHeaders(on: connection, connectionId: connectionId, accumulated: Data())
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.activeConnections.removeValue(forKey: connectionId)
                }
            default:
                break
            }
        }

        connection.start(queue: serverQueue)
    }

    nonisolated private func receiveRequestHeaders(
        on connection: NWConnection,
        connectionId: UUID,
        accumulated: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.closeConnection(connection, connectionId: connectionId)
                return
            }

            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<headerRange.lowerBound]
                self.handleParsedHeader(Data(headerData), on: connection, connectionId: connectionId)
                return
            }

            if buffer.count >= Self.maxHeaderBytes {
                self.sendErrorResponse(status: "400 Bad Request", on: connection, connectionId: connectionId)
                return
            }

            if isComplete {
                self.closeConnection(connection, connectionId: connectionId)
                return
            }

            self.receiveRequestHeaders(on: connection, connectionId: connectionId, accumulated: buffer)
        }
    }

    nonisolated private func handleParsedHeader(
        _ headerData: Data,
        on connection: NWConnection,
        connectionId: UUID
    ) {
        let parsed: CompanionMediaHTTPRequest
        switch CompanionMediaHTTPRequest.parse(headerData: headerData) {
        case .success(let request):
            parsed = request
        case .failure(.badRequest):
            sendErrorResponse(status: "400 Bad Request", on: connection, connectionId: connectionId)
            return
        case .failure(.methodNotAllowed):
            sendErrorResponse(status: "405 Method Not Allowed", on: connection, connectionId: connectionId)
            return
        case .failure(.notFound):
            sendErrorResponse(status: "404 Not Found", on: connection, connectionId: connectionId)
            return
        }

        guard let token = parsed.token,
              !token.isEmpty,
              let fileURL = tokenStore.resolve(token: token, clipId: parsed.clipId) else {
            sendErrorResponse(status: "401 Unauthorized", on: connection, connectionId: connectionId)
            return
        }

        let fileSize: Int64
        let fileHandle: FileHandle
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let sizeNumber = attributes[.size] as? NSNumber else {
                sendErrorResponse(status: "404 Not Found", on: connection, connectionId: connectionId)
                return
            }
            fileSize = sizeNumber.int64Value
            fileHandle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            sendErrorResponse(status: "404 Not Found", on: connection, connectionId: connectionId)
            return
        }

        let isHead = parsed.method == "HEAD"
        if let rangeHeader = parsed.rangeHeader {
            switch HTTPRangeParser.parse(rangeHeader, fileSize: fileSize) {
            case .success(let range):
                let length = range.upperBound - range.lowerBound + 1
                let headers = [
                    "HTTP/1.1 206 Partial Content",
                    "Accept-Ranges: bytes",
                    "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)",
                    "Content-Length: \(length)",
                    "Content-Type: video/mp4",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                sendHeadersAndStream(
                    headers: headers,
                    fileHandle: fileHandle,
                    startOffset: range.lowerBound,
                    length: isHead ? 0 : length,
                    on: connection,
                    connectionId: connectionId
                )
            case .failure(.unsatisfiable):
                try? fileHandle.close()
                let headers = [
                    "HTTP/1.1 416 Range Not Satisfiable",
                    "Content-Range: bytes */\(fileSize)",
                    "Content-Length: 0",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                sendErrorResponse(rawHeaders: headers, on: connection, connectionId: connectionId)
            case .failure(.invalidSyntax):
                try? fileHandle.close()
                sendErrorResponse(status: "400 Bad Request", on: connection, connectionId: connectionId)
            }
            return
        }

        let headers = [
            "HTTP/1.1 200 OK",
            "Accept-Ranges: bytes",
            "Content-Length: \(fileSize)",
            "Content-Type: video/mp4",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        sendHeadersAndStream(
            headers: headers,
            fileHandle: fileHandle,
            startOffset: 0,
            length: isHead ? 0 : fileSize,
            on: connection,
            connectionId: connectionId
        )
    }

    nonisolated private func sendHeadersAndStream(
        headers: String,
        fileHandle: FileHandle,
        startOffset: Int64,
        length: Int64,
        on connection: NWConnection,
        connectionId: UUID
    ) {
        let headerData = Data(headers.utf8)
        let finishImmediately = length <= 0
        connection.send(content: headerData, isComplete: finishImmediately, completion: .contentProcessed { [weak self] error in
            guard let self else {
                try? fileHandle.close()
                connection.cancel()
                return
            }
            if error != nil || finishImmediately {
                try? fileHandle.close()
                self.closeConnection(connection, connectionId: connectionId)
                return
            }
            self.ioQueue.async {
                do {
                    try fileHandle.seek(toOffset: UInt64(startOffset))
                    self.streamNextChunk(
                        fileHandle: fileHandle,
                        remaining: length,
                        on: connection,
                        connectionId: connectionId
                    )
                } catch {
                    try? fileHandle.close()
                    self.closeConnection(connection, connectionId: connectionId)
                }
            }
        })
    }

    nonisolated private func streamNextChunk(
        fileHandle: FileHandle,
        remaining: Int64,
        on connection: NWConnection,
        connectionId: UUID
    ) {
        guard remaining > 0 else {
            try? fileHandle.close()
            closeConnection(connection, connectionId: connectionId)
            return
        }

        let toRead = Int(min(Int64(Self.streamChunkSize), remaining))
        let chunk: Data?
        do {
            chunk = try fileHandle.read(upToCount: toRead)
        } catch {
            try? fileHandle.close()
            closeConnection(connection, connectionId: connectionId)
            return
        }

        guard let chunk, !chunk.isEmpty else {
            try? fileHandle.close()
            closeConnection(connection, connectionId: connectionId)
            return
        }

        let nextRemaining = remaining - Int64(chunk.count)
        let isLastChunk = nextRemaining <= 0

        connection.send(content: chunk, isComplete: isLastChunk, completion: .contentProcessed { [weak self] error in
            guard let self else {
                try? fileHandle.close()
                connection.cancel()
                return
            }
            if error != nil || isLastChunk {
                try? fileHandle.close()
                self.closeConnection(connection, connectionId: connectionId)
                return
            }
            self.ioQueue.async {
                self.streamNextChunk(
                    fileHandle: fileHandle,
                    remaining: nextRemaining,
                    on: connection,
                    connectionId: connectionId
                )
            }
        })
    }

    nonisolated private func sendErrorResponse(
        status: String,
        on connection: NWConnection,
        connectionId: UUID
    ) {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Length: 0",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        sendErrorResponse(rawHeaders: headers, on: connection, connectionId: connectionId)
    }

    nonisolated private func sendErrorResponse(
        rawHeaders: String,
        on connection: NWConnection,
        connectionId: UUID
    ) {
        connection.send(content: Data(rawHeaders.utf8), isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.closeConnection(connection, connectionId: connectionId)
        })
    }

    nonisolated private func closeConnection(_ connection: NWConnection, connectionId: UUID) {
        connection.cancel()
        Task { @MainActor [weak self] in
            self?.activeConnections.removeValue(forKey: connectionId)
        }
    }
}
