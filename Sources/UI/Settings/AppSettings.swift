import Foundation
import Defaults

public enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc
    case h264

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hevc:
            return "HEVC"
        case .h264:
            return "H.264"
        }
    }
}

public enum CaptureResolution: String, CaseIterable, Identifiable {
    case native
    case half
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .native:
            return "Native"
        case .half:
            return "Half"
        case .custom:
            return "Custom"
        }
    }
}

public enum QualityPreset: String, CaseIterable, Identifiable {
    case performance
    case quality
    case ultra
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .performance:
            return "Performance"
        case .quality:
            return "Quality"
        case .ultra:
            return "Ultra"
        case .custom:
            return "Custom"
        }
    }
}

public enum OverlayCorner: String, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topLeft:
            return "Top Left"
        case .topRight:
            return "Top Right"
        case .bottomLeft:
            return "Bottom Left"
        case .bottomRight:
            return "Bottom Right"
        }
    }
}

private enum AppDefaultValues {
    static var outputDirectoryPath: String {
        let moviesDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        return moviesDirectory?
            .appendingPathComponent("ReplayMac", isDirectory: true)
            .path(percentEncoded: false)
            ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
                .appending(path: "Movies/ReplayMac", directoryHint: .isDirectory)
                .path(percentEncoded: false)
    }
}

public enum AppSettings {
    public static var bufferDurationSeconds: Int { Defaults[.bufferDurationSeconds] }

    public static var outputDirectoryURL: URL {
        URL(filePath: Defaults[.outputDirectoryPath], directoryHint: .isDirectory)
    }

    public static var autoStartRecordingOnLaunch: Bool { Defaults[.autoStartRecordingOnLaunch] }
    public static var captureSystemAudio: Bool { Defaults[.captureSystemAudio] }
    public static var captureMicrophone: Bool { Defaults[.captureMicrophone] }
    public static var showOverlayIndicator: Bool { Defaults[.showOverlayIndicator] }
    public static var playAudioCueOnSave: Bool { Defaults[.playAudioCueOnSave] }
    public static var showNotificationOnSave: Bool { Defaults[.showNotificationOnSave] }
    public static var watermarkSavedClips: Bool { Defaults[.watermarkSavedClips] }
    public static var memoryCapMB: Double { Defaults[.memoryCapMB] }
    public static var sparkleAppcastURLString: String {
        Defaults[.sparkleAppcastURLString]
    }

    public static var frameRate: Int {
        Defaults[.frameRate]
    }

    public static var queueDepth: Int {
        Defaults[.queueDepth]
    }

    public static var overlayCorner: OverlayCorner {
        OverlayCorner(rawValue: Defaults[.overlayCorner]) ?? .topRight
    }

    public static var systemAudioVolume: Double { Defaults[.systemAudioVolume] }
    public static var microphoneVolume: Double { Defaults[.microphoneVolume] }
}

public extension Defaults.Keys {
    static let bufferDurationSeconds = Key<Int>("bufferDurationSeconds", default: 30)
    static let outputDirectoryPath = Key<String>("outputDirectoryPath", default: AppDefaultValues.outputDirectoryPath)
    static let launchAtLogin = Key<Bool>("launchAtLogin", default: false)
    static let autoStartRecordingOnLaunch = Key<Bool>("autoStartRecordingOnLaunch", default: true)

    static let videoCodec = Key<String>("videoCodec", default: VideoCodec.hevc.rawValue)
    static let captureDisplayID = Key<String>("captureDisplayID", default: "")
    static let captureResolution = Key<String>("captureResolution", default: CaptureResolution.native.rawValue)
    static let customCaptureWidth = Key<Int>("customCaptureWidth", default: 1920)
    static let customCaptureHeight = Key<Int>("customCaptureHeight", default: 1080)
    static let frameRate = Key<Int>("frameRate", default: 60)
    static let bitrateMbps = Key<Double>("bitrateMbps", default: 20)
    static let qualityPreset = Key<String>("qualityPreset", default: QualityPreset.quality.rawValue)

    static let captureSystemAudio = Key<Bool>("captureSystemAudio", default: true)
    static let captureMicrophone = Key<Bool>("captureMicrophone", default: false)
    static let microphoneID = Key<String>("microphoneID", default: "")
    static let excludeOwnAppAudio = Key<Bool>("excludeOwnAppAudio", default: true)

    static let memoryCapMB = Key<Double>("memoryCapMB", default: 1536)
    static let queueDepth = Key<Int>("queueDepth", default: 5)
    static let showOverlayIndicator = Key<Bool>("showOverlayIndicator", default: false)
    static let overlayCorner = Key<String>("overlayCorner", default: OverlayCorner.topRight.rawValue)
    static let playAudioCueOnSave = Key<Bool>("playAudioCueOnSave", default: true)
    static let showNotificationOnSave = Key<Bool>("showNotificationOnSave", default: true)
    static let watermarkSavedClips = Key<Bool>("watermarkSavedClips", default: false)
    static let sparkleAppcastURLString = Key<String>("sparkleAppcastURLString", default: "")

    static let systemAudioVolume = Key<Double>("systemAudioVolume", default: 1.0)
    static let microphoneVolume = Key<Double>("microphoneVolume", default: 1.0)
}
