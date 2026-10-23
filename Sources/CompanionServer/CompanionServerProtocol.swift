import Foundation

// MARK: - Client Messages (Android Companion -> macOS Server)

public enum CompanionClientMessageType: String, Codable, Sendable {
    case hello
    case action
    case getThumbnail = "get_thumbnail"
    case revealClip = "reveal_clip"
    case deleteClip = "delete_clip"
    case trimClip = "trim_clip"
    case copyClip = "copy_clip"
    case setVolume = "set_volume"
    case toggleAppMute = "toggle_app_mute"
    case unmuteAllApps = "unmute_all_apps"
    case selectDisplay = "select_display"
    case applyProfile = "apply_profile"
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
    /// Bundle identifier for `toggle_app_mute`.
    public let bundleId: String?
    /// Audio target (`"microphone"` or `"systemAudio"`) for `set_volume`.
    public let target: String?
    /// Volume level (`0.0...1.0`) for `set_volume`.
    public let volume: Double?
    /// Display stable key for `select_display`.
    public let displayId: String?
    /// Capture profile UUID string for `apply_profile`.
    public let profileId: String?

    public init(
        type: String,
        deviceId: String? = nil,
        deviceName: String? = nil,
        clientVersion: String? = nil,
        action: String? = nil,
        clipId: String? = nil,
        protocolVersion: Int? = nil,
        proof: String? = nil,
        bundleId: String? = nil,
        target: String? = nil,
        volume: Double? = nil,
        displayId: String? = nil,
        profileId: String? = nil
    ) {
        self.type = type
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.clientVersion = clientVersion
        self.action = action
        self.clipId = clipId
        self.protocolVersion = protocolVersion
        self.proof = proof
        self.bundleId = bundleId
        self.target = target
        self.volume = volume
        self.displayId = displayId
        self.profileId = profileId
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

public struct CompanionAudioApp: Codable, Sendable, Identifiable, Equatable {
    public let bundleId: String
    public let name: String
    public let isMuted: Bool
    public let isRunning: Bool
    public let iconBase64: String?

    public var id: String { bundleId }

    public init(
        bundleId: String,
        name: String,
        isMuted: Bool = false,
        isRunning: Bool = true,
        iconBase64: String? = nil
    ) {
        self.bundleId = bundleId
        self.name = name
        self.isMuted = isMuted
        self.isRunning = isRunning
        self.iconBase64 = iconBase64
    }
}

public struct CompanionDisplayInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let isActive: Bool
    public let isConnected: Bool

    public init(
        id: String,
        name: String,
        isActive: Bool = false,
        isConnected: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.isConnected = isConnected
    }
}

/// One appearance's colours, as `#RRGGBB` hex already resolved on the Mac,
/// so the phone needs no copy of the atmosphere table or the system accent.
public struct CompanionThemePalette: Codable, Sendable, Equatable {
    public let canvas: String
    public let card: String
    public let accent: String
    public let accentSecondary: String

    public init(canvas: String, card: String, accent: String, accentSecondary: String) {
        self.canvas = canvas
        self.card = card
        self.accent = accent
        self.accentSecondary = accentSecondary
    }
}

/// The desktop's Appearance settings, sent so the companion can match them.
public struct CompanionTheme: Codable, Sendable, Equatable {
    public let atmosphere: String
    public let atmosphereName: String
    public let colorScheme: String
    public let accentMode: String
    public let surfaceStyle: String
    /// Whether the desktop actually draws the two-colour accent gradient.
    public let dualTone: Bool
    public let dark: CompanionThemePalette
    public let light: CompanionThemePalette

    public init(
        atmosphere: String,
        atmosphereName: String,
        colorScheme: String,
        accentMode: String,
        surfaceStyle: String,
        dualTone: Bool,
        dark: CompanionThemePalette,
        light: CompanionThemePalette
    ) {
        self.atmosphere = atmosphere
        self.atmosphereName = atmosphereName
        self.colorScheme = colorScheme
        self.accentMode = accentMode
        self.surfaceStyle = surfaceStyle
        self.dualTone = dualTone
        self.dark = dark
        self.light = light
    }
}

public struct CompanionProfileSummary: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let isActive: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        isActive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isActive = isActive
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
    public let microphoneVolume: Double
    public let systemAudioVolume: Double
    public let perAppAudioEnabled: Bool
    public let audioApps: [CompanionAudioApp]
    public let displays: [CompanionDisplayInfo]
    public let profiles: [CompanionProfileSummary]
    public let recentClips: [CompanionClipSummary]
    /// Absent from builds that predate theming; phones then keep their default look.
    public let theme: CompanionTheme?

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
        microphoneVolume: Double = 1.0,
        systemAudioVolume: Double = 1.0,
        perAppAudioEnabled: Bool = false,
        audioApps: [CompanionAudioApp] = [],
        displays: [CompanionDisplayInfo] = [],
        profiles: [CompanionProfileSummary] = [],
        recentClips: [CompanionClipSummary],
        theme: CompanionTheme? = nil
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
        self.microphoneVolume = microphoneVolume
        self.systemAudioVolume = systemAudioVolume
        self.perAppAudioEnabled = perAppAudioEnabled
        self.audioApps = audioApps
        self.displays = displays
        self.profiles = profiles
        self.recentClips = recentClips
        self.theme = theme
    }

    private enum CodingKeys: String, CodingKey {
        case type, isRecording, isSessionRecording, saveStatus
        case recordingElapsedSeconds, extendedBufferElapsedSeconds, sessionElapsedSeconds
        case bufferedSeconds, bufferDurationSeconds, bufferMemoryBytes, bufferMemoryFormatted
        case longBufferEnabled, longBufferDurationSeconds, capturedDisplayName, isUsingFallbackDisplay
        case isMicrophoneEnabled, isMicrophoneMuted, isSystemAudioEnabled, isSystemAudioMuted
        case microphoneVolume, systemAudioVolume, perAppAudioEnabled
        case audioApps, displays, profiles, recentClips, theme
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "state_snapshot"
        self.isRecording = try container.decodeIfPresent(Bool.self, forKey: .isRecording) ?? false
        self.isSessionRecording = try container.decodeIfPresent(Bool.self, forKey: .isSessionRecording) ?? false
        self.saveStatus = try container.decodeIfPresent(String.self, forKey: .saveStatus) ?? "idle"
        self.recordingElapsedSeconds = try container.decodeIfPresent(Double.self, forKey: .recordingElapsedSeconds) ?? 0
        self.extendedBufferElapsedSeconds = try container.decodeIfPresent(Double.self, forKey: .extendedBufferElapsedSeconds) ?? 0
        self.sessionElapsedSeconds = try container.decodeIfPresent(Double.self, forKey: .sessionElapsedSeconds) ?? 0
        self.bufferedSeconds = try container.decodeIfPresent(Double.self, forKey: .bufferedSeconds) ?? 0
        self.bufferDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .bufferDurationSeconds) ?? 30
        self.bufferMemoryBytes = try container.decodeIfPresent(Int.self, forKey: .bufferMemoryBytes) ?? 0
        self.bufferMemoryFormatted = try container.decodeIfPresent(String.self, forKey: .bufferMemoryFormatted) ?? "0 MB"
        self.longBufferEnabled = try container.decodeIfPresent(Bool.self, forKey: .longBufferEnabled) ?? false
        self.longBufferDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .longBufferDurationSeconds) ?? 300
        self.capturedDisplayName = try container.decodeIfPresent(String.self, forKey: .capturedDisplayName)
        self.isUsingFallbackDisplay = try container.decodeIfPresent(Bool.self, forKey: .isUsingFallbackDisplay) ?? false
        self.isMicrophoneEnabled = try container.decodeIfPresent(Bool.self, forKey: .isMicrophoneEnabled) ?? false
        self.isMicrophoneMuted = try container.decodeIfPresent(Bool.self, forKey: .isMicrophoneMuted) ?? false
        self.isSystemAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSystemAudioEnabled) ?? true
        self.isSystemAudioMuted = try container.decodeIfPresent(Bool.self, forKey: .isSystemAudioMuted) ?? false
        self.microphoneVolume = try container.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? 1.0
        self.systemAudioVolume = try container.decodeIfPresent(Double.self, forKey: .systemAudioVolume) ?? 1.0
        self.perAppAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .perAppAudioEnabled) ?? false
        self.audioApps = try container.decodeIfPresent([CompanionAudioApp].self, forKey: .audioApps) ?? []
        self.displays = try container.decodeIfPresent([CompanionDisplayInfo].self, forKey: .displays) ?? []
        self.profiles = try container.decodeIfPresent([CompanionProfileSummary].self, forKey: .profiles) ?? []
        self.recentClips = try container.decodeIfPresent([CompanionClipSummary].self, forKey: .recentClips) ?? []
        self.theme = try? container.decodeIfPresent(CompanionTheme.self, forKey: .theme)
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
