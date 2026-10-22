import AppKit
import Capture
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
    public static var autoRecordExcludedBundleIDs: [String] { Defaults[.autoRecordExcludedBundleIDs] }
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

    public static var captureDisplayPriorities: [String] {
        let stored = Defaults[.captureDisplayPriorities]
        if !stored.isEmpty {
            return stored
        }
        let single = Defaults[.captureDisplayID]
        return single.isEmpty ? [] : [single]
    }

    /// Upgrade display selections that were saved as raw `CGDirectDisplayID`s.
    ///
    /// Runs at launch. A value can only be migrated while the display it points at is
    /// still attached, so anything unresolvable is left untouched and picked up on a
    /// later launch — the raw ID keeps working in the meantime.
    public static func migrateDisplaySelectionsIfNeeded() {
        let online = DisplayIdentity.onlineDisplayIDs()
        guard !online.isEmpty else { return }

        let keys: [Defaults.Key<String>] = [.captureDisplayID, .captureDisplayID2]
        for key in keys {
            let stored = Defaults[key]
            if let migrated = DisplayIdentity.migratedKey(forLegacyValue: stored, among: online) {
                Defaults[key] = migrated
            }
        }

        let priorities = Defaults[.captureDisplayPriorities]
        if !priorities.isEmpty {
            var updated = priorities
            var changed = false
            for (idx, key) in priorities.enumerated() {
                if let migrated = DisplayIdentity.migratedKey(forLegacyValue: key, among: online) {
                    updated[idx] = migrated
                    changed = true
                }
            }
            if changed {
                Defaults[.captureDisplayPriorities] = updated
            }
        }
    }

    public static var dualCaptureSaveMode: String {
        Defaults[.dualCaptureSaveMode]
    }

    public static var dualCaptureSaveModeEnum: DualCaptureSaveMode {
        DualCaptureSaveMode(rawValue: Defaults[.dualCaptureSaveMode]) ?? .sideBySide
    }

    public static var systemAudioVolume: Double { Defaults[.systemAudioVolume] }
    public static var microphoneVolume: Double { Defaults[.microphoneVolume] }
    public static var isSystemAudioMuted: Bool { Defaults[.isSystemAudioMuted] }
    public static var isMicrophoneMuted: Bool { Defaults[.isMicrophoneMuted] }

    public static func setSystemAudioVolume(_ volume: Double) {
        Defaults[.systemAudioVolume] = min(max(volume, 0.0), 1.0)
    }

    public static func setMicrophoneVolume(_ volume: Double) {
        Defaults[.microphoneVolume] = min(max(volume, 0.0), 1.0)
    }

    public static func selectPrimaryDisplay(_ displayKey: String) {
        let trimmed = displayKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let previousPrimary = Defaults[.captureDisplayID]
        let onlineKeys = DisplayIdentity.onlineDisplayIDs().map { DisplayIdentity.stableKey(for: $0) }
        var priorities = Defaults[.captureDisplayPriorities].filter { !$0.isEmpty }
        for key in onlineKeys where !priorities.contains(key) {
            priorities.append(key)
        }
        priorities.removeAll { $0 == trimmed }
        priorities.insert(trimmed, at: 0)

        Defaults[.captureDisplayPriorities] = priorities
        Defaults[.captureDisplayID] = trimmed

        if Defaults[.captureMode] == CaptureMode.dualSideBySide.rawValue,
           Defaults[.captureDisplayID2] == trimmed,
           !previousPrimary.isEmpty,
           previousPrimary != trimmed {
            Defaults[.captureDisplayID2] = previousPrimary
        }
    }

    public static func loadCaptureProfiles() -> [CaptureProfile] {
        guard let data = Defaults[.captureProfilesJSON].data(using: .utf8),
              let profiles = try? JSONDecoder().decode([CaptureProfile].self, from: data) else {
            return []
        }
        return profiles.sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func isCaptureProfileActive(_ profile: CaptureProfile) -> Bool {
        let currentHDR = Defaults[.captureHDR]
        let profileHDR = profile.captureHDR ?? false
        guard currentHDR == profileHDR,
              Defaults[.videoCodec] == profile.videoCodecRawValue,
              Defaults[.captureMode] == profile.captureModeRawValue,
              Defaults[.captureResolution] == profile.captureResolutionRawValue,
              Defaults[.frameRate] == profile.frameRate,
              abs(Defaults[.bitrateMbps] - profile.bitrateMbps) < 0.01,
              Defaults[.captureSystemAudio] == profile.captureSystemAudio,
              Defaults[.captureMicrophone] == profile.captureMicrophone,
              Defaults[.perAppAudioEnabled] == profile.perAppAudioEnabled,
              Defaults[.longBufferEnabled] == profile.longBufferEnabled,
              Defaults[.longBufferDurationMinutes] == profile.longBufferDurationMinutes else {
            return false
        }
        if !profile.captureDisplayID.isEmpty && Defaults[.captureDisplayID] != profile.captureDisplayID {
            return false
        }
        if let theme = profile.themeSnapshot, currentThemeSnapshot() != theme {
            return false
        }
        return true
    }

    public static func currentThemeSnapshot() -> ProfileThemeSnapshot {
        ProfileThemeSnapshot(
            colorSchemeRawValue: Defaults[.themeColorScheme].rawValue,
            atmosphereRawValue: Defaults[.themeAtmosphere].rawValue,
            accentModeRawValue: Defaults[.themeAccentMode].rawValue,
            primaryAccentHex: ColorHex.normalized(Defaults[.themePrimaryAccentHex]),
            secondaryAccentHex: ColorHex.normalized(Defaults[.themeSecondaryAccentHex], defaultHex: "#00A3FF"),
            useDualToneAccent: Defaults[.themeUseDualToneAccent],
            surfaceStyleRawValue: Defaults[.themeSurfaceStyle].rawValue
        )
    }

    public static func applyThemeSnapshot(_ snapshot: ProfileThemeSnapshot) {
        Defaults[.themeColorScheme] = ThemeColorScheme(rawValue: snapshot.colorSchemeRawValue) ?? .system
        Defaults[.themeAtmosphere] = ThemeAtmosphere(rawValue: snapshot.atmosphereRawValue) ?? .native
        Defaults[.themeAccentMode] = ThemeAccentMode(rawValue: snapshot.accentModeRawValue) ?? .atmosphere
        Defaults[.themePrimaryAccentHex] = ColorHex.normalized(snapshot.primaryAccentHex)
        Defaults[.themeSecondaryAccentHex] = ColorHex.normalized(snapshot.secondaryAccentHex, defaultHex: "#00A3FF")
        Defaults[.themeUseDualToneAccent] = snapshot.useDualToneAccent
        Defaults[.themeSurfaceStyle] = ThemeSurfaceStyle(rawValue: snapshot.surfaceStyleRawValue) ?? .glass
    }

    public static func resetThemeToDefaults() {
        Defaults[.themeColorScheme] = .system
        Defaults[.themeAtmosphere] = .native
        Defaults[.themeAccentMode] = .atmosphere
        Defaults[.themePrimaryAccentHex] = "#00E5CC"
        Defaults[.themeSecondaryAccentHex] = "#00A3FF"
        Defaults[.themeUseDualToneAccent] = true
        Defaults[.themeSurfaceStyle] = .glass
    }

    @discardableResult
    public static func applyCaptureProfile(id: String) -> Bool {
        let profiles = loadCaptureProfiles()
        guard let profile = profiles.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame || $0.id.uuidString == id
        }) else {
            return false
        }

        Defaults[.captureHDR] = profile.captureHDR ?? false
        Defaults[.videoCodec] = profile.videoCodecRawValue
        Defaults[.captureMode] = profile.captureModeRawValue
        Defaults[.captureDisplayID] = profile.captureDisplayID
        Defaults[.captureDisplayID2] = profile.captureDisplayID2
        if let priorities = profile.captureDisplayPriorities, !priorities.isEmpty {
            Defaults[.captureDisplayPriorities] = priorities
        } else if !profile.captureDisplayID.isEmpty {
            Defaults[.captureDisplayPriorities] = [profile.captureDisplayID]
        }
        Defaults[.dualCaptureSaveMode] = profile.dualCaptureSaveModeRawValue
        Defaults[.captureResolution] = profile.captureResolutionRawValue
        Defaults[.customCaptureWidth] = profile.customCaptureWidth
        Defaults[.customCaptureHeight] = profile.customCaptureHeight
        Defaults[.frameRate] = profile.frameRate
        Defaults[.bitrateMbps] = profile.bitrateMbps
        Defaults[.qualityPreset] = profile.qualityPresetRawValue

        Defaults[.captureSystemAudio] = profile.captureSystemAudio
        Defaults[.captureMicrophone] = profile.captureMicrophone
        Defaults[.mergeAudioTracks] = profile.mergeAudioTracks ?? true
        Defaults[.microphoneID] = profile.microphoneID
        Defaults[.excludeOwnAppAudio] = profile.excludeOwnAppAudio
        Defaults[.perAppAudioEnabled] = profile.perAppAudioEnabled
        Defaults[.perAppAudioBundleID] = profile.perAppAudioBundleID
        Defaults[.mutedAudioAppBundleIDs] = profile.mutedAudioAppBundleIDs ?? []
        Defaults[.systemAudioVolume] = profile.systemAudioVolume
        Defaults[.microphoneVolume] = profile.microphoneVolume

        Defaults[.memoryCapMB] = profile.memoryCapMB
        Defaults[.queueDepth] = profile.queueDepth
        Defaults[.longBufferEnabled] = profile.longBufferEnabled
        Defaults[.longBufferDurationMinutes] = profile.longBufferDurationMinutes
        if let themeSnapshot = profile.themeSnapshot {
            applyThemeSnapshot(themeSnapshot)
        }
        return true
    }

    public static func effectiveSystemAudioVolume(
        volume: Double = systemAudioVolume,
        isMuted: Bool = isSystemAudioMuted
    ) -> Double {
        isMuted ? 0.0 : volume
    }

    public static func effectiveMicrophoneVolume(
        volume: Double = microphoneVolume,
        isMuted: Bool = isMicrophoneMuted,
        isPushToMuteActive: Bool = false
    ) -> Double {
        (isMuted || isPushToMuteActive) ? 0.0 : volume
    }

    public static var captureHDR: Bool { Defaults[.captureHDR] }
    public static var isHDRCaptureActive: Bool {
        captureHDR && CaptureManager.supportsHDRCapture
            && (captureMode != CaptureMode.dualSideBySide.rawValue || dualCaptureSaveModeEnum == .separateFiles)
    }
    public static var effectiveVideoCodec: String { isHDRCaptureActive ? "hevc" : videoCodec }

    public static var videoCodec: String { Defaults[.videoCodec] }
    public static var bitrateMbps: Double { Defaults[.bitrateMbps] }
    public static var captureResolution: String { Defaults[.captureResolution] }
    public static var customCaptureWidth: Int { Defaults[.customCaptureWidth] }
    public static var customCaptureHeight: Int { Defaults[.customCaptureHeight] }
    public static var excludeOwnAppAudio: Bool { Defaults[.excludeOwnAppAudio] }
    public static var microphoneID: String { Defaults[.microphoneID] }
    public static var perAppAudioEnabled: Bool { Defaults[.perAppAudioEnabled] }
    public static var perAppAudioBundleID: String { Defaults[.perAppAudioBundleID] }
    public static var mutedAudioAppBundleIDs: [String] { Defaults[.mutedAudioAppBundleIDs] }

    public static func isAppAudioMuted(_ bundleID: String) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return Defaults[.mutedAudioAppBundleIDs].contains {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    public static func muteAudioApp(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAppAudioMuted(trimmed) else { return }
        Defaults[.mutedAudioAppBundleIDs].append(trimmed)
    }

    public static func unmuteAudioApp(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Defaults[.mutedAudioAppBundleIDs].removeAll {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    public static func toggleAudioAppMute(_ bundleID: String) {
        if isAppAudioMuted(bundleID) {
            unmuteAudioApp(bundleID)
        } else {
            muteAudioApp(bundleID)
        }
    }

    public static func unmuteAllAudioApps() {
        guard !Defaults[.mutedAudioAppBundleIDs].isEmpty else { return }
        Defaults[.mutedAudioAppBundleIDs] = []
    }

    /// Running user applications (excluding this app itself), sorted alphabetically.
    public static func capturableRunningApplications(excluding excludedBundleIDs: [String] = []) -> [AudioApplicationOption] {
        let excludedLowercased = Set(excludedBundleIDs.map { $0.lowercased() })
        let ownID = Bundle.main.bundleIdentifier?.lowercased()
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AudioApplicationOption? in
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
                let lower = bundleID.lowercased()
                guard lower != ownID,
                      !excludedLowercased.contains(lower),
                      seen.insert(lower).inserted else {
                    return nil
                }
                return AudioApplicationOption(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func isApplicationRunning(_ bundleID: String) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier?.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    public static func appDisplayName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
        }), let name = running.localizedName, !name.isEmpty {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
            return url.deletingPathExtension().lastPathComponent
        }
        if let preset = GameAutoRecordPresets.defaultExclusionPresets.first(where: { $0.bundleIDs.contains(bundleID) }) {
            return preset.name
        }
        return bundleID
    }

    public static func appIcon(for bundleID: String) -> NSImage? {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
        }), let icon = running.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    nonisolated(unsafe) private static let appIconBase64Cache = NSCache<NSString, NSString>()

    public static func appIconBase64(for bundleID: String, dimension: Int = 64) -> String? {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cacheKey = "\(trimmed.lowercased()):\(dimension)" as NSString
        if let cached = appIconBase64Cache.object(forKey: cacheKey) {
            return cached as String
        }
        guard let icon = appIcon(for: trimmed),
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: dimension,
                  pixelsHigh: dimension,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ) else {
            return nil
        }
        bitmap.size = NSSize(width: dimension, height: dimension)
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        icon.draw(
            in: NSRect(x: 0, y: 0, width: dimension, height: dimension),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        let encoded = pngData.base64EncodedString()
        appIconBase64Cache.setObject(encoded as NSString, forKey: cacheKey)
        return encoded
    }

    public static var longBufferEnabled: Bool { Defaults[.longBufferEnabled] }
    public static var longBufferDurationMinutes: Int { Defaults[.longBufferDurationMinutes] }
    public static var longBufferDurationSeconds: Int {
        LongBufferDuration(rawValue: longBufferDurationMinutes)?.seconds ?? LongBufferDuration.fiveMinutes.seconds
    }
    public static var companionServerEnabled: Bool { Defaults[.companionServerEnabled] }
    public static var companionServerPort: Int { Defaults[.companionServerPort] }
    public static var companionCustomServerName: String { Defaults[.companionCustomServerName] }

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
    static let mainWindowLaunchBehavior = Key<String>(MainWindowState.launchBehaviorKey, default: MainWindowLaunchBehavior.mainWindow.rawValue)
    static let mainWindowStartPage = Key<String>(MainWindowState.startPageKey, default: MainWindowStartPage.home.rawValue)
    static let autoStartRecordingOnLaunch = Key<Bool>("autoStartRecordingOnLaunch", default: true)
    static let resumeRecordingAfterWake = Key<Bool>("resumeRecordingAfterWake", default: true)
    static let autoRecordGamesEnabled = Key<Bool>("autoRecordGamesEnabled", default: false)
    static let autoRecordStopWhenGameCloses = Key<Bool>("autoRecordStopWhenGameCloses", default: true)
    static let autoRecordGameBundleIDs = Key<[String]>("autoRecordGameBundleIDs", default: [])
    static let autoRecordExcludedBundleIDs = Key<[String]>("autoRecordExcludedBundleIDs", default: [])

    static let captureHDR = Key<Bool>("captureHDR", default: false)
    static let videoCodec = Key<String>("videoCodec", default: VideoCodec.hevc.rawValue)
    static let captureMode = Key<String>("captureMode", default: "single")
    static let captureDisplayID = Key<String>("captureDisplayID", default: "")
    static let captureDisplayID2 = Key<String>("captureDisplayID2", default: "")
    static let captureDisplayPriorities = Key<[String]>("captureDisplayPriorities", default: [])
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
    static let mutedAudioAppBundleIDs = Key<[String]>("mutedAudioAppBundleIDs", default: [])

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
    static let longReplayTipDismissed = Key<Bool>("longReplayTipDismissed", default: false)
    static let captureProfilesJSON = Key<String>("captureProfilesJSON", default: "[]")

    static let systemAudioVolume = Key<Double>("systemAudioVolume", default: 1.0)
    static let microphoneVolume = Key<Double>("microphoneVolume", default: 1.0)
    static let isSystemAudioMuted = Key<Bool>("isSystemAudioMuted", default: false)
    static let isMicrophoneMuted = Key<Bool>("isMicrophoneMuted", default: false)

    // Off until the user opts in: no open port or Local Network prompt for
    // people who never use the companion app.
    static let companionServerEnabled = Key<Bool>("companionServerEnabled", default: false)
    static let companionServerPort = Key<Int>("companionServerPort", default: 7375)
    static let companionHideSensitiveInfo = Key<Bool>("companionHideSensitiveInfo", default: false)
    static let companionCustomServerName = Key<String>("companionCustomServerName", default: "")

    static let hasCompletedOnboarding = Key<Bool>("hasCompletedOnboarding", default: false)

    static let themeColorScheme = Key<ThemeColorScheme>("themeColorScheme", default: .system)
    static let themeAtmosphere = Key<ThemeAtmosphere>("themeAtmosphere", default: .native)
    static let themeAccentMode = Key<ThemeAccentMode>("themeAccentMode", default: .atmosphere)
    static let themePrimaryAccentHex = Key<String>("themePrimaryAccentHex", default: "#00E5CC")
    static let themeSecondaryAccentHex = Key<String>("themeSecondaryAccentHex", default: "#00A3FF")
    static let themeUseDualToneAccent = Key<Bool>("themeUseDualToneAccent", default: true)
    static let themeSurfaceStyle = Key<ThemeSurfaceStyle>("themeSurfaceStyle", default: .glass)
}
