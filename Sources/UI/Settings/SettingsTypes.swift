import Foundation

public enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case appearance
    case video
    case audio
    case profiles
    case hotkeys
    case companion
    case advanced
}

enum SystemAudioMode: String, CaseIterable, Identifiable {
    case off
    case allApps
    case selectedApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .allApps:
            return "All apps"
        case .selectedApp:
            return "Selected app only"
        }
    }
}

struct DisplayOption: Identifiable, Hashable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let pointPixelScale: Double
    let pixelWidth: Int
    let pixelHeight: Int
    /// False for a saved selection whose display isn't attached right now. The option is
    /// still listed so the stored choice survives until the display comes back.
    var isConnected: Bool = true

    var retinaWidth: Int {
        AppSettings.retinaPixelDimension(
            for: width,
            pointPixelScale: pointPixelScale,
            maxPixelDimension: pixelWidth
        )
    }

    var retinaHeight: Int {
        AppSettings.retinaPixelDimension(
            for: height,
            pointPixelScale: pointPixelScale,
            maxPixelDimension: pixelHeight
        )
    }

    var hasRetinaOutput: Bool {
        retinaWidth > width || retinaHeight > height
    }
}

struct MicrophoneOption: Identifiable, Hashable {
    let id: String
    let name: String
}

public struct AudioApplicationOption: Identifiable, Hashable, Sendable {
    public let bundleID: String
    public let name: String

    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public struct CaptureProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public var captureHDR: Bool? = false
    public var videoCodecRawValue: String
    public var captureModeRawValue: String
    public var captureDisplayID: String
    public var captureDisplayID2: String
    public var captureDisplayPriorities: [String]? = []
    public var dualCaptureSaveModeRawValue: String
    public var captureResolutionRawValue: String
    public var customCaptureWidth: Int
    public var customCaptureHeight: Int
    public var frameRate: Int
    public var bitrateMbps: Double
    public var qualityPresetRawValue: String

    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    public var mergeAudioTracks: Bool? = true
    public var microphoneID: String
    public var excludeOwnAppAudio: Bool
    public var perAppAudioEnabled: Bool
    public var perAppAudioBundleID: String
    public var mutedAudioAppBundleIDs: [String]? = []
    public var systemAudioVolume: Double
    public var microphoneVolume: Double

    public var memoryCapMB: Double
    public var queueDepth: Int
    public var longBufferEnabled: Bool
    public var longBufferDurationMinutes: Int
    public var themeSnapshot: ProfileThemeSnapshot? = nil

    public var summary: String {
        let fpsLabel = "\(frameRate) fps"
        let audioLabel: String
        if !captureSystemAudio {
            audioLabel = "No system audio"
        } else if perAppAudioEnabled {
            audioLabel = "Selected app audio"
        } else if let muted = mutedAudioAppBundleIDs, !muted.isEmpty {
            audioLabel = "All app audio (\(muted.count) muted)"
        } else {
            audioLabel = "All app audio"
        }
        let micLabel = captureMicrophone ? "Mic on" : "Mic off"
        let mergeLabel = (mergeAudioTracks ?? true) ? "Merged audio" : "Separate audio"
        var parts = [fpsLabel, "\(Int(bitrateMbps)) Mbps", audioLabel, micLabel, mergeLabel]
        if let themeSnapshot {
            let atmosphere = (ThemeAtmosphere(rawValue: themeSnapshot.atmosphereRawValue) ?? .native).title
            parts.append("\(atmosphere) theme")
        }
        return parts.joined(separator: " · ")
    }
}
