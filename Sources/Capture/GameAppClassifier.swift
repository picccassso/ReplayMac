import Foundation

/// Pure rules for deciding whether a running application should be treated as a
/// game for auto-record. Kept free of AppKit so the classification logic lives
/// in one place and can be unit tested without a live workspace.
public enum GameAppClassifier {
    /// Whether an `LSApplicationCategoryType` string is one of Apple's App Store
    /// "Games" categories. The parent category is `public.app-category.games`;
    /// every genre subcategory ends in `-games`
    /// (e.g. `public.app-category.action-games`, `public.app-category.role-playing-games`).
    public static func isGameCategory(_ category: String?) -> Bool {
        guard let category, category.hasPrefix("public.app-category.") else {
            return false
        }
        return category == "public.app-category.games" || category.hasSuffix("-games")
    }

    /// A running app counts as a game when the user has explicitly listed its
    /// bundle identifier, or when its declared category is a games category,
    /// UNLESS its bundle identifier is present in the excluded list.
    ///
    /// The exclusion list is checked first so users can suppress launchers
    /// (e.g. Epic Games Launcher) or idle apps even if they declare a game category.
    /// Next, the manual list is checked, and finally the declared category.
    public static func isGame(
        bundleIdentifier: String?,
        category: String?,
        manualBundleIDs: Set<String>,
        excludedBundleIDs: Set<String> = []
    ) -> Bool {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            if excludedBundleIDs.contains(bundleIdentifier) {
                return false
            }
            if manualBundleIDs.contains(bundleIdentifier) {
                return true
            }
        }
        return isGameCategory(category)
    }
}

/// Built-in presets for applications and launchers that users commonly want to exclude.
public enum GameAutoRecordPresets {
    public struct Preset: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public let name: String
        public let bundleIDs: [String]

        public init(name: String, bundleIDs: [String]) {
            self.name = name
            self.bundleIDs = bundleIDs
        }
    }

    public static let defaultExclusionPresets: [Preset] = [
        Preset(name: "Epic Games Launcher", bundleIDs: ["com.epicgames.EpicGamesLauncher", "com.epicgames.launcher"]),
        Preset(name: "Steam", bundleIDs: ["com.valvesoftware.steam"]),
        Preset(name: "Battle.net", bundleIDs: ["net.battle.app"]),
        Preset(name: "Heroic Games Launcher", bundleIDs: ["com.heroicgameslauncher.hgl"]),
        Preset(name: "GOG Galaxy", bundleIDs: ["com.gog.galaxy"]),
        Preset(name: "EA App", bundleIDs: ["com.ea.mac.eaapp", "com.ea.Origin"]),
        Preset(name: "Unreal Editor", bundleIDs: ["com.epicgames.UnrealEditor"]),
        Preset(name: "Unity Editor", bundleIDs: ["com.unity3d.UnityEditor5.x"]),
        Preset(name: "Roblox Player", bundleIDs: ["com.roblox.RobloxPlayer"])
    ]
}

