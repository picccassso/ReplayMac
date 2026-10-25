import Capture
import Defaults
import Foundation

/// Functional areas that can be toggled independently or grouped into
/// curated experience presets.
public enum FeatureModule: String, CaseIterable, Codable, Identifiable, Sendable, Defaults.Serializable {
    case appearance
    case sessionRecording
    case extendedReplay
    case proVideo
    case audioMixing
    case autoRecordGames
    case quickSaveAndThumbnail
    case companion
    case captureProfiles
    case systemAndFileTuning

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sessionRecording:
            return "Session Recording"
        case .autoRecordGames:
            return "Auto-Record Games"
        case .audioMixing:
            return "Audio Mixing & App Mute"
        case .appearance:
            return "Appearance & Themes"
        case .quickSaveAndThumbnail:
            return "Quick-Save Presets & Thumbnail"
        case .extendedReplay:
            return "Extended Replay Buffer"
        case .proVideo:
            return "Pro Video & Dual Display"
        case .captureProfiles:
            return "Capture Profiles"
        case .companion:
            return "iPhone Companion"
        case .systemAndFileTuning:
            return "System & File Tuning"
        }
    }

    public var detail: String {
        switch self {
        case .sessionRecording:
            return "Record continuously from start to stop into a single MP4."
        case .autoRecordGames:
            return "Start buffering automatically when games launch and stop when they close."
        case .audioMixing:
            return "Volume sliders, microphone picker, per-app routing, and app muting."
        case .appearance:
            return "Custom atmospheres, accent colours, dual-tone styles, and surfaces."
        case .quickSaveAndThumbnail:
            return "15s and 60s quick-save hotkeys plus a floating thumbnail after saving."
        case .extendedReplay:
            return "Keep a rolling 5–30 minute buffer on disk for longer sessions."
        case .proVideo:
            return "Codec selection, manual bitrate, HDR, and dual-display capture."
        case .captureProfiles:
            return "Save and switch between named recording and encoder configurations."
        case .companion:
            return "Trigger clips and control recording from your iPhone over local Wi-Fi."
        case .systemAndFileTuning:
            return "Custom filename templates, buffer memory caps, and capture queue depth."
        }
    }

    public var icon: String {
        switch self {
        case .sessionRecording:
            return "record.circle"
        case .autoRecordGames:
            return "gamecontroller"
        case .audioMixing:
            return "slider.vertical.3"
        case .appearance:
            return "paintbrush"
        case .quickSaveAndThumbnail:
            return "sparkles.rectangle.stack"
        case .extendedReplay:
            return "externaldrive.badge.timemachine"
        case .proVideo:
            return "video.badge.waveform"
        case .captureProfiles:
            return "rectangle.stack.badge.play"
        case .companion:
            return "iphone"
        case .systemAndFileTuning:
            return "wrench.and.screwdriver"
        }
    }

    public var category: FeatureCategory {
        switch self {
        case .appearance:
            return .appearance
        case .sessionRecording, .extendedReplay, .proVideo:
            return .video
        case .audioMixing:
            return .audio
        case .autoRecordGames, .quickSaveAndThumbnail:
            return .automations
        case .companion, .captureProfiles, .systemAndFileTuning:
            return .advanced
        }
    }
}

public enum FeatureCategory: String, CaseIterable, Identifiable, Sendable {
    case appearance = "Interface & Themes"
    case video = "Video & Recording"
    case audio = "Audio & Mixing"
    case automations = "Shortcuts & Automations"
    case advanced = "Advanced & Ecosystem"

    public var id: String { rawValue }
    public var title: String { rawValue }

    public var icon: String {
        switch self {
        case .appearance:
            return "paintbrush"
        case .video:
            return "video"
        case .audio:
            return "slider.vertical.3"
        case .automations:
            return "gamecontroller"
        case .advanced:
            return "wrench.and.screwdriver"
        }
    }

    public var subtitle: String {
        switch self {
        case .appearance:
            return "Personalise atmospheres, accent colours, and window surfaces."
        case .video:
            return "Continuous recording, extended disk buffers, and pro encoding."
        case .audio:
            return "Per-app audio routing, volume sliders, and microphone controls."
        case .automations:
            return "Automatic game detection, quick-save hotkeys, and floating thumbnails."
        case .advanced:
            return "iPhone remote control, saved capture profiles, and system tuning."
        }
    }
}

/// Curated interface tiers that configure which feature modules are active.
public enum ExperiencePreset: String, CaseIterable, Identifiable, Sendable, Defaults.Serializable {
    case simple
    case balanced
    case full
    case custom

    public var id: String { rawValue }

    public static let selectablePresets: [ExperiencePreset] = [.simple, .balanced, .full]

    public var title: String {
        switch self {
        case .simple:
            return "Simple"
        case .balanced:
            return "Balanced"
        case .full:
            return "Full"
        case .custom:
            return "Custom"
        }
    }

    public var badgeText: String {
        switch self {
        case .simple:
            return "Simple"
        case .balanced:
            return "Balanced"
        case .full:
            return "Full"
        case .custom:
            return "Custom"
        }
    }

    public var subtitle: String {
        switch self {
        case .simple:
            return "Just clipping with custom themes. Minimal menus, clean settings, and zero clutter."
        case .balanced:
            return "Essential power tools: session recording, themes, and game auto-record."
        case .full:
            return "Every feature unlocked: extended replay, pro encoding, companion, and profiles."
        case .custom:
            return "Tailored combination of modules configured to your exact liking."
        }
    }

    public var icon: String {
        switch self {
        case .simple:
            return "bolt.circle"
        case .balanced:
            return "slider.horizontal.2.square"
        case .full:
            return "dial.high"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    public var modules: Set<FeatureModule> {
        switch self {
        case .simple:
            return [.appearance]
        case .balanced:
            return [
                .sessionRecording,
                .autoRecordGames,
                .audioMixing,
                .appearance,
                .quickSaveAndThumbnail
            ]
        case .full:
            return Set(FeatureModule.allCases)
        case .custom:
            return []
        }
    }

    public static func resolve(from modules: Set<FeatureModule>) -> ExperiencePreset {
        if modules == ExperiencePreset.simple.modules {
            return .simple
        }
        if modules == ExperiencePreset.balanced.modules {
            return .balanced
        }
        if modules == ExperiencePreset.full.modules {
            return .full
        }
        return .custom
    }
}

/// What the running app has to do after the enabled module set changes.
///
/// Turning a module on or off only matters at runtime when it hides a stored
/// setting that differs from the baseline, so toggling a UI-only module (or one
/// whose settings are already at their defaults) never touches capture.
public struct FeatureModuleChange: Equatable, Sendable {
    /// The user's own stored values that a disabled module masks.
    public struct StoredSettings: Equatable, Sendable {
        public var autoRecordGamesEnabled = false
        public var longBufferEnabled = false
        public var queueDepth = Defaults.Keys.queueDepth.defaultValue
        public var captureMode = CaptureMode.single.rawValue
        public var captureHDR = false
        public var videoCodec = VideoCodec.hevc.rawValue
        public var captureResolution = CaptureResolution.native.rawValue

        public init() {}

        public static var current: StoredSettings {
            var stored = StoredSettings()
            stored.autoRecordGamesEnabled = Defaults[.autoRecordGamesEnabled]
            stored.longBufferEnabled = Defaults[.longBufferEnabled]
            stored.queueDepth = Defaults[.queueDepth]
            stored.captureMode = Defaults[.captureMode]
            stored.captureHDR = Defaults[.captureHDR] && CaptureManager.supportsHDRCapture
            stored.videoCodec = Defaults[.videoCodec]
            stored.captureResolution = Defaults[.captureResolution]
            return stored
        }
    }

    public var reconcileCompanionServer = false
    public var reconcileGameAutoRecord = false
    /// Auto-record games was masked off while the user had it on, so normal
    /// auto-start behaviour should take over again.
    public var resumeAlwaysOnRecording = false
    public var refreshAudio = false
    public var syncMemoryCaps = false
    public var reconcileCapture = false
    public var needsVideoReset = false
    public var needsFullRestart = false

    public init(from old: Set<FeatureModule>, to new: Set<FeatureModule>, stored: StoredSettings = .current) {
        let toggled = old.symmetricDifference(new)

        if toggled.contains(.companion) {
            reconcileCompanionServer = true
        }

        if toggled.contains(.autoRecordGames), stored.autoRecordGamesEnabled {
            reconcileGameAutoRecord = true
            resumeAlwaysOnRecording = !new.contains(.autoRecordGames)
        }

        if toggled.contains(.audioMixing) {
            refreshAudio = true
            reconcileCapture = true
        }

        if toggled.contains(.systemAndFileTuning) {
            syncMemoryCaps = true
            if stored.queueDepth != Defaults.Keys.queueDepth.defaultValue {
                reconcileCapture = true
                needsVideoReset = true
            }
        }

        if toggled.contains(.extendedReplay), stored.longBufferEnabled {
            reconcileCapture = true
        }

        if toggled.contains(.proVideo) {
            if stored.captureMode != CaptureMode.single.rawValue || stored.captureHDR {
                reconcileCapture = true
                needsFullRestart = true
            } else if stored.videoCodec != VideoCodec.hevc.rawValue
                || stored.captureResolution == CaptureResolution.custom.rawValue {
                reconcileCapture = true
                needsVideoReset = true
            }
        }
    }
}
