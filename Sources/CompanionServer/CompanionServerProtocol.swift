import Foundation

// MARK: - Client Messages (Android Companion -> macOS Server)

public enum CompanionClientMessageType: String, Codable, Sendable {
    case hello
    case action
    case getThumbnail = "get_thumbnail"
    case revealClip = "reveal_clip"
    case deleteClip = "delete_clip"
    case authProof = "auth_proof"
    case ping
}

public struct CompanionClientMessage: Codable, Sendable {
    public let type: String
    public let deviceId: String?
    public let deviceName: String?
    public let clientVersion: String?
    public let action: String?
    public let clipId: String?
    /// Sent in `hello`; see ``CompanionAuth/protocolVersion``.
    public let protocolVersion: Int?
    /// Base64 HMAC answering an `auth_challenge`; absent when the phone has no secret for this Mac.
    public let proof: String?

    public init(
        type: String,
        deviceId: String? = nil,
        deviceName: String? = nil,
        clientVersion: String? = nil,
        action: String? = nil,
        clipId: String? = nil,
        protocolVersion: Int? = nil,
        proof: String? = nil
    ) {
        self.type = type
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.clientVersion = clientVersion
        self.action = action
        self.clipId = clipId
        self.protocolVersion = protocolVersion
        self.proof = proof
    }
}

// MARK: - Client Action Names

public enum CompanionClientAction: String, Sendable, CaseIterable {
    case saveReplay
    case saveExtendedReplay
    case toggleBuffer
    case toggleSession
    case toggleMicrophone
    case toggleSystemAudio
}

// MARK: - Server Messages (macOS Server -> Android Companion)

public enum CompanionServerMessageType: String, Codable, Sendable {
    case authResponse = "auth_response"
    case authChallenge = "auth_challenge"
    case stateSnapshot = "state_snapshot"
    case stateChanged = "state_changed"
    case telemetryTick = "telemetry_tick"
    case thumbnailResponse = "thumbnail_response"
    case pong
    case error
}

public struct CompanionClipSummary: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let filename: String
    public let kind: String
    public let savedAt: Double
    public let duration: Double?
    public let fileSize: Int64?
    public let hasThumbnail: Bool

    public init(
        id: String,
        filename: String,
        kind: String,
        savedAt: Double,
        duration: Double? = nil,
        fileSize: Int64? = nil,
        hasThumbnail: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.savedAt = savedAt
        self.duration = duration
        self.fileSize = fileSize
        self.hasThumbnail = hasThumbnail
    }
}

public struct CompanionStateSnapshot: Codable, Sendable, Equatable {
    public let type: String
    public let isRecording: Bool
    public let isSessionRecording: Bool
    public let saveStatus: String
    public let recordingElapsedSeconds: Double
    public let extendedBufferElapsedSeconds: Double
    public let sessionElapsedSeconds: Double
    public let bufferedSeconds: Double
    public let bufferDurationSeconds: Int
    public let bufferMemoryBytes: Int
    public let bufferMemoryFormatted: String
    public let longBufferEnabled: Bool
    public let longBufferDurationSeconds: Int
    public let capturedDisplayName: String?
    /// The chosen display was unavailable, so capture fell back to another one.
    public let isUsingFallbackDisplay: Bool
    public let isMicrophoneEnabled: Bool
    public let isMicrophoneMuted: Bool
    public let isSystemAudioEnabled: Bool
    public let isSystemAudioMuted: Bool
    public let recentClips: [CompanionClipSummary]

    public init(
        type: String = "state_snapshot",
        isRecording: Bool,
        isSessionRecording: Bool,
        saveStatus: String,
        recordingElapsedSeconds: Double,
        extendedBufferElapsedSeconds: Double,
        sessionElapsedSeconds: Double,
        bufferedSeconds: Double,
        bufferDurationSeconds: Int,
        bufferMemoryBytes: Int,
        bufferMemoryFormatted: String,
        longBufferEnabled: Bool,
        longBufferDurationSeconds: Int,
        capturedDisplayName: String?,
        isUsingFallbackDisplay: Bool = false,
        isMicrophoneEnabled: Bool,
        isMicrophoneMuted: Bool,
        isSystemAudioEnabled: Bool,
        isSystemAudioMuted: Bool,
        recentClips: [CompanionClipSummary]
    ) {
        self.type = type
        self.isRecording = isRecording
        self.isSessionRecording = isSessionRecording
        self.saveStatus = saveStatus
        self.recordingElapsedSeconds = recordingElapsedSeconds
        self.extendedBufferElapsedSeconds = extendedBufferElapsedSeconds
        self.sessionElapsedSeconds = sessionElapsedSeconds
        self.bufferedSeconds = bufferedSeconds
        self.bufferDurationSeconds = bufferDurationSeconds
        self.bufferMemoryBytes = bufferMemoryBytes
        self.bufferMemoryFormatted = bufferMemoryFormatted
        self.longBufferEnabled = longBufferEnabled
        self.longBufferDurationSeconds = longBufferDurationSeconds
        self.capturedDisplayName = capturedDisplayName
        self.isUsingFallbackDisplay = isUsingFallbackDisplay
        self.isMicrophoneEnabled = isMicrophoneEnabled
        self.isMicrophoneMuted = isMicrophoneMuted
        self.isSystemAudioEnabled = isSystemAudioEnabled
        self.isSystemAudioMuted = isSystemAudioMuted
        self.recentClips = recentClips
    }
}

public extension CompanionStateSnapshot {
    static var empty: CompanionStateSnapshot {
        CompanionStateSnapshot(
            isRecording: false,
            isSessionRecording: false,
            saveStatus: "idle",
            recordingElapsedSeconds: 0,
            extendedBufferElapsedSeconds: 0,
            sessionElapsedSeconds: 0,
            bufferedSeconds: 0,
            bufferDurationSeconds: 30,
            bufferMemoryBytes: 0,
            bufferMemoryFormatted: "0 MB",
            longBufferEnabled: false,
            longBufferDurationSeconds: 300,
            capturedDisplayName: nil,
            isMicrophoneEnabled: false,
            isMicrophoneMuted: false,
            isSystemAudioEnabled: true,
            isSystemAudioMuted: false,
            recentClips: []
        )
    }
}

public struct CompanionTelemetryTick: Codable, Sendable, Equatable {
    public let type: String
    public let recordingElapsedSeconds: Double
    public let extendedBufferElapsedSeconds: Double
    public let sessionElapsedSeconds: Double
    public let bufferedSeconds: Double
    public let bufferMemoryBytes: Int
    public let bufferMemoryFormatted: String

    public init(
        type: String = "telemetry_tick",
        recordingElapsedSeconds: Double,
        extendedBufferElapsedSeconds: Double,
        sessionElapsedSeconds: Double,
        bufferedSeconds: Double,
        bufferMemoryBytes: Int,
        bufferMemoryFormatted: String
    ) {
        self.type = type
        self.recordingElapsedSeconds = recordingElapsedSeconds
        self.extendedBufferElapsedSeconds = extendedBufferElapsedSeconds
        self.sessionElapsedSeconds = sessionElapsedSeconds
        self.bufferedSeconds = bufferedSeconds
        self.bufferMemoryBytes = bufferMemoryBytes
        self.bufferMemoryFormatted = bufferMemoryFormatted
    }
}

public struct CompanionAuthResponse: Codable, Sendable, Equatable {
    public let type: String
    public let status: String
    public let serverName: String
    public let serverVersion: String
    /// This Mac's stable companion identity, so a paired phone can find it on any network.
    public let serverId: String?
    /// The friendly name of the paired device assigned or confirmed by the Mac.
    public let deviceName: String?
    /// With `pending`: the code the Mac's Allow prompt shows, for the phone to display too.
    public let pairingCode: String?
    /// With `approved`, only right after the user clicks Allow: the secret the
    /// phone must keep to answer future challenges.
    public let pairingSecret: String?
    /// With `denied`: one of ``CompanionDenialReason``.
    public let reason: String?

    public init(
        type: String = "auth_response",
        status: String,
        serverName: String,
        serverVersion: String,
        serverId: String? = nil,
        deviceName: String? = nil,
        pairingCode: String? = nil,
        pairingSecret: String? = nil,
        reason: String? = nil
    ) {
        self.type = type
        self.status = status
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.serverId = serverId
        self.deviceName = deviceName
        self.pairingCode = pairingCode
        self.pairingSecret = pairingSecret
        self.reason = reason
    }
}

public enum CompanionDenialReason: String, Sendable {
    case userDenied = "user_denied"
    case revoked
    case invalidProof = "invalid_proof"
}

/// Sent after `hello` from a paired device; the phone answers with `auth_proof`.
public struct CompanionAuthChallenge: Codable, Sendable, Equatable {
    public let type: String
    public let nonce: String
    public let serverId: String
    public let serverName: String
    public let serverVersion: String

    public init(type: String = "auth_challenge", nonce: String, serverId: String, serverName: String, serverVersion: String) {
        self.type = type
        self.nonce = nonce
        self.serverId = serverId
        self.serverName = serverName
        self.serverVersion = serverVersion
    }
}

public struct CompanionThumbnailResponse: Codable, Sendable, Equatable {
    public let type: String
    public let clipId: String
    public let thumbnailBase64: String?

    public init(
        type: String = "thumbnail_response",
        clipId: String,
        thumbnailBase64: String?
    ) {
        self.type = type
        self.clipId = clipId
        self.thumbnailBase64 = thumbnailBase64
    }
}

public struct CompanionPongMessage: Codable, Sendable, Equatable {
    public let type: String

    public init(type: String = "pong") {
        self.type = type
    }
}

public struct CompanionErrorMessage: Codable, Sendable, Equatable {
    public let type: String
    public let message: String
    /// One of ``CompanionErrorCode``. Every code except `not_authorized` is
    /// followed by the Mac closing the connection.
    public let code: String?

    public init(type: String = "error", message: String, code: String? = nil) {
        self.type = type
        self.message = message
        self.code = code
    }

    init(_ code: CompanionErrorCode, message: String) {
        self.init(message: message, code: code.rawValue)
    }
}

public enum CompanionErrorCode: String, Sendable {
    case busy
    case cooldown
    case timeout
    case unsupportedClient = "unsupported_client"
    case tooManyConnections = "too_many_connections"
    case notAuthorized = "not_authorized"
}
