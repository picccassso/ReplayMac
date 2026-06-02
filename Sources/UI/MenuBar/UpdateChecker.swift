import Foundation

public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let releaseURL: URL

    public init(version: String, releaseURL: URL) {
        self.version = version
        self.releaseURL = releaseURL
    }
}

public enum UpdateChecker {
    private static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/picccassso/ReplayMac/releases/latest"
    )!

    public static var currentAppVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public static func checkForUpdate(
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

    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let candidateComponents = versionComponents(from: candidate),
              let currentComponents = versionComponents(from: current) else {
            return false
        }

        let count = max(candidateComponents.count, currentComponents.count)
        for index in 0..<count {
            let candidateValue = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0
            if candidateValue != currentValue {
                return candidateValue > currentValue
            }
        }
        return false
    }

    private static func versionComponents(from version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: \.isNumber) else {
            return nil
        }

        let numericPrefix = trimmed[start...].prefix { character in
            character.isNumber || character == "."
        }
        let components = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            return nil
        }
        let values = components.compactMap { Int($0) }
        return values.count == components.count ? values : nil
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
