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

public enum CaptureMode: String, CaseIterable, Identifiable {
    case single
    case dualSideBySide = "dual_side_by_side"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .single:
            return "Single Display"
        case .dualSideBySide:
            return "Dual Side-by-Side"
        }
    }
}

public enum DualCaptureSaveMode: String, CaseIterable, Identifiable {
    case sideBySide = "side_by_side"
    case separateFiles = "separate_files"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sideBySide:
            return "One side-by-side file"
        case .separateFiles:
            return "Two separate files"
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
        let path = Defaults[.outputDirectoryPath]
        guard !path.isEmpty else {
            return URL(filePath: AppDefaultValues.outputDirectoryPath, directoryHint: .isDirectory)
        }
        return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public static var autoStartRecordingOnLaunch: Bool { Defaults[.autoStartRecordingOnLaunch] }
    public static var captureSystemAudio: Bool { Defaults[.captureSystemAudio] }
    public static var captureMicrophone: Bool { Defaults[.captureMicrophone] }
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

    public static var captureMode: String {
        Defaults[.captureMode]
    }

    public static var captureDisplayID: String {
        Defaults[.captureDisplayID]
    }

    public static var captureDisplayID2: String {
        Defaults[.captureDisplayID2]
    }

    public static var dualCaptureSaveMode: String {
        Defaults[.dualCaptureSaveMode]
    }

    public static var systemAudioVolume: Double { Defaults[.systemAudioVolume] }
    public static var microphoneVolume: Double { Defaults[.microphoneVolume] }

    public static var videoCodec: String { Defaults[.videoCodec] }
    public static var videoCodecEnum: VideoCodec { VideoCodec(rawValue: Defaults[.videoCodec]) ?? .hevc }
    public static var bitrateMbps: Double { Defaults[.bitrateMbps] }
    public static var captureResolution: String { Defaults[.captureResolution] }
    public static var customCaptureWidth: Int { Defaults[.customCaptureWidth] }
    public static var customCaptureHeight: Int { Defaults[.customCaptureHeight] }
    public static var excludeOwnAppAudio: Bool { Defaults[.excludeOwnAppAudio] }
    public static var microphoneID: String { Defaults[.microphoneID] }

    public static func scaledDimensions(displayWidth: Int, displayHeight: Int) -> (width: Int, height: Int) {
        switch captureResolution {
        case CaptureResolution.half.rawValue:
            return (displayWidth / 2, displayHeight / 2)
        case CaptureResolution.custom.rawValue:
            return (customCaptureWidth, customCaptureHeight)
        default:
            return (displayWidth, displayHeight)
        }
    }
}

public extension Defaults.Keys {
    static let bufferDurationSeconds = Key<Int>("bufferDurationSeconds", default: 30)
    static let outputDirectoryPath = Key<String>("outputDirectoryPath", default: AppDefaultValues.outputDirectoryPath)
    static let launchAtLogin = Key<Bool>("launchAtLogin", default: false)
    static let autoStartRecordingOnLaunch = Key<Bool>("autoStartRecordingOnLaunch", default: true)

    static let videoCodec = Key<String>("videoCodec", default: VideoCodec.hevc.rawValue)
    static let captureMode = Key<String>("captureMode", default: "single")
    static let captureDisplayID = Key<String>("captureDisplayID", default: "")
    static let captureDisplayID2 = Key<String>("captureDisplayID2", default: "")
    static let dualCaptureSaveMode = Key<String>("dualCaptureSaveMode", default: DualCaptureSaveMode.sideBySide.rawValue)
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
    static let playAudioCueOnSave = Key<Bool>("playAudioCueOnSave", default: true)
    static let showNotificationOnSave = Key<Bool>("showNotificationOnSave", default: true)
    static let watermarkSavedClips = Key<Bool>("watermarkSavedClips", default: false)
    static let sparkleAppcastURLString = Key<String>("sparkleAppcastURLString", default: "")

    static let systemAudioVolume = Key<Double>("systemAudioVolume", default: 1.0)
    static let microphoneVolume = Key<Double>("microphoneVolume", default: 1.0)
}
