import Foundation

enum SettingsTab: Hashable {
    case general
    case video
    case audio
    case profiles
    case hotkeys
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
}

struct MicrophoneOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct AudioApplicationOption: Identifiable, Hashable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

struct CaptureProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    var videoCodecRawValue: String
    var captureModeRawValue: String
    var captureDisplayID: String
    var captureDisplayID2: String
    var dualCaptureSaveModeRawValue: String
    var captureResolutionRawValue: String
    var customCaptureWidth: Int
    var customCaptureHeight: Int
    var frameRate: Int
    var bitrateMbps: Double
    var qualityPresetRawValue: String

    var captureSystemAudio: Bool
    var captureMicrophone: Bool
    var mergeAudioTracks: Bool? = true
    var microphoneID: String
    var excludeOwnAppAudio: Bool
    var perAppAudioEnabled: Bool
    var perAppAudioBundleID: String
    var systemAudioVolume: Double
    var microphoneVolume: Double

    var memoryCapMB: Double
    var queueDepth: Int
    var longBufferEnabled: Bool
    var longBufferDurationMinutes: Int

    var summary: String {
        let fpsLabel = "\(frameRate) fps"
        let audioLabel: String
        if !captureSystemAudio {
            audioLabel = "No system audio"
        } else if perAppAudioEnabled {
            audioLabel = "Selected app audio"
        } else {
            audioLabel = "All app audio"
        }
        let micLabel = captureMicrophone ? "Mic on" : "Mic off"
        let mergeLabel = (mergeAudioTracks ?? true) ? "Merged audio" : "Separate audio"
        return "\(fpsLabel) · \(Int(bitrateMbps)) Mbps · \(audioLabel) · \(micLabel) · \(mergeLabel)"
    }
}
