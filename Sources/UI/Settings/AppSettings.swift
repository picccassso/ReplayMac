import Foundation
import Branding
import Defaults
import Save

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
    case retina
    case half
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .native:
            return "Current"
        case .retina:
            return "Retina"
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

public enum LongBufferDuration: Int, CaseIterable, Identifiable {
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .fiveMinutes:
            return "5 minutes"
        case .tenMinutes:
            return "10 minutes"
        case .thirtyMinutes:
            return "30 minutes"
        }
    }

    public var seconds: Int {
        rawValue * 60
    }
}

public enum AppSettings {
    /// App Store installs have no proposed output folder. Direct builds retain
    /// their traditional user-visible Movies folder default.
    public static var defaultOutputDirectoryPath: String {
        defaultOutputDirectoryPath(
            requiresExplicitSelection: AppBranding.requiresExplicitOutputDirectorySelection,
            directBuildDefault: ClipMetadata.defaultOutputDirectory
        )
    }

    public static func defaultOutputDirectoryPath(
        requiresExplicitSelection: Bool,
        directBuildDefault: URL
    ) -> String {
        requiresExplicitSelection
            ? ""
            : directBuildDefault.standardizedFileURL.path(percentEncoded: false)
    }

    /// Updates only the old built-in file-name template. Custom templates and
    /// previously selected output folders remain untouched across the rename.
    public static func migrateLegacyBrandDefaults() {
        if Defaults[.clipFilenameTemplate] == "ReplayMac_{date}_{time}" {
            Defaults[.clipFilenameTemplate] = FilenameTemplate.default
        }
    }

    public static var bufferDurationSeconds: Int { Defaults[.bufferDurationSeconds] }

    /// Extra seconds retained in the ring buffers beyond the user-facing replay
    /// window. Video eviction is GOP-granular — whole keyframe groups (~2s at the
    /// encoder's 2s max keyframe interval) drop at once — so without headroom the
    /// buffer settles just under the requested duration and a "Save Last 30s"
    /// comes up short (e.g. 29s). One keyframe interval of slack plus a small
    /// margin guarantees the full window is always retained.
    public static let ringBufferHeadroomSeconds: TimeInterval = 3.0

    /// Internal ring-buffer time cap: the user-facing replay window plus headroom.
    /// Saves still request exactly `bufferDurationSeconds`; the extra retention
    /// only exists so that full window is always available to hand out.
    public static var ringBufferTimeCapSeconds: TimeInterval {
        TimeInterval(bufferDurationSeconds) + ringBufferHeadroomSeconds
    }

    public static var outputDirectoryURL: URL? {
        outputDirectoryURL(for: Defaults[.outputDirectoryPath])
    }

    public static func outputDirectoryURL(for path: String) -> URL? {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public static var autoStartRecordingOnLaunch: Bool { Defaults[.autoStartRecordingOnLaunch] }
    public static var resumeRecordingAfterWake: Bool { Defaults[.resumeRecordingAfterWake] }
    public static var autoRecordGamesEnabled: Bool { Defaults[.autoRecordGamesEnabled] }
    public static var autoRecordStopWhenGameCloses: Bool { Defaults[.autoRecordStopWhenGameCloses] }
    public static var autoRecordGameBundleIDs: [String] { Defaults[.autoRecordGameBundleIDs] }
    public static var captureSystemAudio: Bool { Defaults[.captureSystemAudio] }
    public static var captureMicrophone: Bool { Defaults[.captureMicrophone] }
    public static var mergeAudioTracks: Bool { Defaults[.mergeAudioTracks] }
    public static var playAudioCueOnSave: Bool { Defaults[.playAudioCueOnSave] }
    public static var showNotificationOnSave: Bool { Defaults[.showNotificationOnSave] }
    public static var clipFilenameTemplate: String { Defaults[.clipFilenameTemplate] }
    public static var clipDateFormat: String { Defaults[.clipDateFormat] }
    public static var clipTimeFormat: String { Defaults[.clipTimeFormat] }
    public static var memoryCapMB: Double { Defaults[.memoryCapMB] }

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

    public static var dualCaptureSaveModeEnum: DualCaptureSaveMode {
        DualCaptureSaveMode(rawValue: Defaults[.dualCaptureSaveMode]) ?? .sideBySide
    }

    public static var systemAudioVolume: Double { Defaults[.systemAudioVolume] }
    public static var microphoneVolume: Double { Defaults[.microphoneVolume] }

    public static var videoCodec: String { Defaults[.videoCodec] }
    public static var bitrateMbps: Double { Defaults[.bitrateMbps] }
    public static var captureResolution: String { Defaults[.captureResolution] }
    public static var customCaptureWidth: Int { Defaults[.customCaptureWidth] }
    public static var customCaptureHeight: Int { Defaults[.customCaptureHeight] }
    public static var excludeOwnAppAudio: Bool { Defaults[.excludeOwnAppAudio] }
    public static var microphoneID: String { Defaults[.microphoneID] }
    public static var perAppAudioEnabled: Bool { Defaults[.perAppAudioEnabled] }
    public static var perAppAudioBundleID: String { Defaults[.perAppAudioBundleID] }
    public static var longBufferEnabled: Bool { Defaults[.longBufferEnabled] }
    public static var longBufferDurationMinutes: Int { Defaults[.longBufferDurationMinutes] }
    public static var longBufferDurationSeconds: Int {
        LongBufferDuration(rawValue: longBufferDurationMinutes)?.seconds ?? LongBufferDuration.fiveMinutes.seconds
    }

    public static func ringBufferMemoryCaps(
        isDualMode: Bool,
        captureSystemAudio: Bool,
        captureMicrophone: Bool,
        totalCapMB: Double = memoryCapMB
    ) -> (videoPerBuffer: Int, audioPerBuffer: Int) {
        let totalBytes = Int(totalCapMB * 1024 * 1024)
        let videoBufferCount = max(isDualMode ? 3 : 1, 1)

        var audioBufferCount = 0
        if captureSystemAudio {
            audioBufferCount += 1
        }
        if captureMicrophone {
            audioBufferCount += 1
        }

        let videoPool = Int(Double(totalBytes) * 0.85)
        let audioPool = totalBytes - videoPool

        let minimumVideoBytes = 32 * 1024 * 1024
        let minimumAudioBytes = 8 * 1024 * 1024

        let videoPerBuffer = max(minimumVideoBytes, videoPool / videoBufferCount)
        let audioPerBuffer = audioBufferCount > 0
            ? max(minimumAudioBytes, audioPool / audioBufferCount)
            : minimumAudioBytes

        return (videoPerBuffer, audioPerBuffer)
    }

    public static func retinaPixelDimension(
        for pointDimension: Int,
        pointPixelScale: Double,
        maxPixelDimension: Int? = nil
    ) -> Int {
        let safeScale = max(pointPixelScale, 1.0)
        let scaledDimension = max(Int((Double(pointDimension) * safeScale).rounded()), 1)

        guard let maxPixelDimension, maxPixelDimension > 0 else {
            return scaledDimension
        }

        return min(scaledDimension, maxPixelDimension)
    }

    public static func scaledDimensions(
        displayWidth: Int,
        displayHeight: Int,
        pointPixelScale: Double = 1.0,
        maxPixelWidth: Int? = nil,
        maxPixelHeight: Int? = nil
    ) -> (width: Int, height: Int) {
        switch captureResolution {
        case CaptureResolution.half.rawValue:
            return (displayWidth / 2, displayHeight / 2)
        case CaptureResolution.retina.rawValue:
            return (
                retinaPixelDimension(
                    for: displayWidth,
                    pointPixelScale: pointPixelScale,
                    maxPixelDimension: maxPixelWidth
                ),
                retinaPixelDimension(
                    for: displayHeight,
                    pointPixelScale: pointPixelScale,
                    maxPixelDimension: maxPixelHeight
                )
            )
        case CaptureResolution.custom.rawValue:
            return (customCaptureWidth, customCaptureHeight)
        default:
            return (displayWidth, displayHeight)
        }
    }
}

public extension Defaults.Keys {
    static let bufferDurationSeconds = Key<Int>("bufferDurationSeconds", default: 30)
    static let outputDirectoryPath = Key<String>("outputDirectoryPath", default: AppSettings.defaultOutputDirectoryPath)
    static let launchAtLogin = Key<Bool>("launchAtLogin", default: false)
    static let autoStartRecordingOnLaunch = Key<Bool>("autoStartRecordingOnLaunch", default: true)
    static let resumeRecordingAfterWake = Key<Bool>("resumeRecordingAfterWake", default: true)
    static let autoRecordGamesEnabled = Key<Bool>("autoRecordGamesEnabled", default: false)
    static let autoRecordStopWhenGameCloses = Key<Bool>("autoRecordStopWhenGameCloses", default: true)
    static let autoRecordGameBundleIDs = Key<[String]>("autoRecordGameBundleIDs", default: [])

    static let videoCodec = Key<String>("videoCodec", default: VideoCodec.hevc.rawValue)
    static let captureMode = Key<String>("captureMode", default: "single")
    static let captureDisplayID = Key<String>("captureDisplayID", default: "")
    static let captureDisplayID2 = Key<String>("captureDisplayID2", default: "")
    static let dualCaptureSaveMode = Key<String>("dualCaptureSaveMode", default: DualCaptureSaveMode.sideBySide.rawValue)
    static let captureResolution = Key<String>("captureResolution", default: CaptureResolution.native.rawValue)
    static let customCaptureWidth = Key<Int>("customCaptureWidth", default: 1920)
    static let customCaptureHeight = Key<Int>("customCaptureHeight", default: 1080)
    static let frameRate = Key<Int>("frameRate", default: 60)
    static let bitrateMbps = Key<Double>("bitrateMbps", default: 25)
    static let qualityPreset = Key<String>("qualityPreset", default: QualityPreset.quality.rawValue)

    static let captureSystemAudio = Key<Bool>("captureSystemAudio", default: true)
    static let captureMicrophone = Key<Bool>("captureMicrophone", default: false)
    static let mergeAudioTracks = Key<Bool>("mergeAudioTracks", default: true)
    static let microphoneID = Key<String>("microphoneID", default: "")
    static let excludeOwnAppAudio = Key<Bool>("excludeOwnAppAudio", default: true)
    static let perAppAudioEnabled = Key<Bool>("perAppAudioEnabled", default: false)
    static let perAppAudioBundleID = Key<String>("perAppAudioBundleID", default: "")

    static let memoryCapMB = Key<Double>("memoryCapMB", default: 1536)
    static let queueDepth = Key<Int>("queueDepth", default: 5)
    static let playAudioCueOnSave = Key<Bool>("playAudioCueOnSave", default: true)
    static let showNotificationOnSave = Key<Bool>("showNotificationOnSave", default: true)
    static let clipFilenameTemplate = Key<String>("clipFilenameTemplate", default: FilenameTemplate.default)
    static let clipDateFormat = Key<String>("clipDateFormat", default: FilenameTemplate.defaultDateFormat)
    static let clipTimeFormat = Key<String>("clipTimeFormat", default: FilenameTemplate.defaultTimeFormat)
    static let longBufferEnabled = Key<Bool>("longBufferEnabled", default: false)
    static let longBufferDurationMinutes = Key<Int>("longBufferDurationMinutes", default: LongBufferDuration.fiveMinutes.rawValue)
    static let longBufferWarningAccepted = Key<Bool>("longBufferWarningAccepted", default: false)
    static let captureProfilesJSON = Key<String>("captureProfilesJSON", default: "[]")

    static let systemAudioVolume = Key<Double>("systemAudioVolume", default: 1.0)
    static let microphoneVolume = Key<Double>("microphoneVolume", default: 1.0)

    static let hasCompletedOnboarding = Key<Bool>("hasCompletedOnboarding", default: false)
}
