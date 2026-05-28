import Foundation

enum SettingsTab: Hashable {
    case general
    case video
    case audio
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
