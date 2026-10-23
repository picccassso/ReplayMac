import Foundation
import os
import UI

private let updateLogger = Logger(subsystem: "com.replaycap", category: "UpdateCheck")

@MainActor
extension AppDelegate {
    func checkForAvailableUpdate() {
        // App Store builds ship updates through the store; the menu's
        // "Update Available" item never appears because nothing sets
        // menuBarState.availableUpdate.
        #if !APPSTORE
        guard let currentVersion = UpdateChecker.currentAppVersion else {
            updateLogger.warning("Skipping update check: app version is unavailable.")
            return
        }

        Task {
            do {
                let update = try await UpdateChecker.checkForUpdate(currentVersion: currentVersion)
                menuBarState.setAvailableUpdate(update)
                statusItemController.refreshPresentation()
            } catch {
                updateLogger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }
}

// The network half of the update checker lives here, in the app target,
// rather than in the UI package: Xcode build settings (-DAPPSTORE) reach
// these sources but not SwiftPM package targets, and App Store binaries
// must contain no reference to out-of-store downloads.
#if !APPSTORE
extension UpdateChecker {
    // The GitHub repo keeps the ReplayMac name; only the App Store product
    // (which never compiles this code) is branded ReplayCap.
    private static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/picccassso/ReplayMac/releases/latest"
    )!

    static func checkForUpdate(
        currentVersion: String,
        session: URLSession = .shared
    ) async throws -> AvailableUpdate? {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ReplayMac", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.invalidResponse
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard isVersion(release.tagName, newerThan: currentVersion) else {
            return nil
        }

        return AvailableUpdate(version: release.tagName, releaseURL: release.htmlURL)
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

private enum UpdateCheckError: Error {
    case invalidResponse
}
#endif
