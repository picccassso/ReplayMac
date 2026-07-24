import AppKit
import Foundation
import Defaults

public extension Defaults.Keys {
    static let outputDirectoryBookmark = Key<Data?>("outputDirectoryBookmark", default: nil)
}

/// Keeps sandbox access to a user-chosen output directory across launches.
///
/// App Store builds start with no proposed output folder and require the user
/// to select one through the standard folder picker. The scoped access is held
/// open for the app's lifetime because clips can be saved at any moment while
/// recording.
@MainActor
public enum OutputDirectoryAccess {
    private static var scopedURL: URL?

    /// Persist access to a folder the user just picked in the open panel.
    /// The panel's implicit grant covers the rest of this session, so no
    /// scoped access needs to start here; the bookmark takes over on the
    /// next launch.
    public static func adopt(_ url: URL) {
        endScopedAccess()
        do {
            Defaults[.outputDirectoryBookmark] = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            Defaults[.outputDirectoryBookmark] = nil
            NSLog("OutputDirectoryAccess: failed to create bookmark for \(url.path): \(error)")
        }
    }

    /// Presents the standard folder picker and, on selection, persists both
    /// the path and the security-scoped access to it. Returns the new path,
    /// or `nil` if the user cancelled. Shared by Settings and onboarding.
    public static func promptUserToChoose() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose Clip Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let initialDirectory = initialPanelDirectoryURL(
            storedPath: Defaults[.outputDirectoryPath]
        ) {
            panel.directoryURL = initialDirectory
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        let path = selectedURL.standardizedFileURL.path(percentEncoded: false)
        Defaults[.outputDirectoryPath] = path
        UserDefaults.standard.set(path, forKey: "outputDirectoryPath")
        UserDefaults.standard.synchronize()
        adopt(selectedURL)
        return path
    }

    /// Resolves the folder where the picker should open. An empty stored path
    /// deliberately returns `nil`, leaving the standard panel to choose its own
    /// neutral starting location instead of steering a fresh install to Movies.
    nonisolated static func initialPanelDirectoryURL(
        storedPath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let storedURL = AppSettings.outputDirectoryURL(for: storedPath) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: storedURL.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return storedURL
        }
        return storedURL.deletingLastPathComponent()
    }

    /// Re-establish access to a previously chosen folder. Call once at launch,
    /// before anything touches the output directory. Returns `true` only when
    /// persistent access was successfully restored.
    @discardableResult
    public static func restore() -> Bool {
        migrateLegacyContainerDefault()

        guard let data = Defaults[.outputDirectoryBookmark] else { return false }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // Folder is gone (deleted, or on an unmounted volume). Drop the
            // stored path so App Store builds require a fresh explicit choice.
            NSLog("OutputDirectoryAccess: dropping unresolvable bookmark: \(error)")
            Defaults[.outputDirectoryBookmark] = nil
            Defaults.reset(.outputDirectoryPath)
            return false
        }

        guard url.startAccessingSecurityScopedResource() else {
            NSLog("OutputDirectoryAccess: security-scoped access could not be restored for \(url.path)")
            Defaults[.outputDirectoryBookmark] = nil
            Defaults.reset(.outputDirectoryPath)
            return false
        }
        scopedURL = url

        if isStale, let fresh = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            Defaults[.outputDirectoryBookmark] = fresh
        }

        // Follow the folder if it was moved or renamed since last launch.
        let resolvedPath = url.standardizedFileURL.path(percentEncoded: false)
        if Defaults[.outputDirectoryPath] != resolvedPath {
            Defaults[.outputDirectoryPath] = resolvedPath
        }
        return true
    }

    /// Builds before 1.6.8 registered the sandbox-container Movies path
    /// (`~/Library/Containers/…/Data/Movies/ReplayMac`) as the default. Files
    /// still reached the real `~/Movies` through the container's symlink, but
    /// the stored path read as the hidden container. Drop it so the corrected
    /// default applies; folders the user picked themselves carry a bookmark
    /// and are left alone.
    private static func migrateLegacyContainerDefault() {
        guard Defaults[.outputDirectoryBookmark] == nil,
              Defaults[.outputDirectoryPath].contains("/Library/Containers/") else {
            return
        }
        Defaults.reset(.outputDirectoryPath)
        UserDefaults.standard.removeObject(forKey: "outputDirectoryPath")
    }

    private static func endScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}
