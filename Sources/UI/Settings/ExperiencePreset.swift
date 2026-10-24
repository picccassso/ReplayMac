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
            return "Quick-Save Presets & Floating Thumbnail"
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
            return "Record continuously from start to stop into a single MP4 file."
        case .autoRecordGames:
            return "Automatically starts buffering when games launch and stops when they close."
        case .audioMixing:
            return "Volume sliders, mic device picker, per-app audio routing, and app muting."
        case .appearance:
            return "Custom atmospheres, accent colours, dual-tone styles, and surface designs."
        case .quickSaveAndThumbnail:
            return "Hotkeys for saving the last 15s or 60s, plus a floating thumbnail card after saving."
        case .extendedReplay:
            return "A rolling 5–30 minute buffer kept on disk for capturing longer sessions."
        case .proVideo:
            return "HEVC/H.264 codec selection, manual bitrate slider, HDR, and dual-display capture."
        case .captureProfiles:
            return "Save and switch between named recording and encoder configurations."
        case .companion:
            return "Control ReplayMac and trigger clips from your iPhone over the local network."
        case .systemAndFileTuning:
            return "Custom filename and date templates, buffer memory caps, and SCK queue depth."
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
