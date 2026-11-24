import Foundation
import UniformTypeIdentifiers

/// Validates, canonicalizes, deduplicates, and caps external video URLs opened
/// via Finder "Open With", Dock drag-and-drop, or File > Open Video.
public enum ExternalVideoOpenPolicy {
    public struct Resolution: Equatable, Sendable {
        public let accepted: [URL]
        public let skippedCount: Int
        public let truncatedCount: Int

        public init(accepted: [URL], skippedCount: Int, truncatedCount: Int) {
            self.accepted = accepted
            self.skippedCount = skippedCount
            self.truncatedCount = truncatedCount
        }
    }

    /// Maximum number of editor windows opened from a single multi-file batch,
    /// keeping memory and hardware video decoders bounded if a user opens an
    /// entire folder selection at once.
    public static let maxBatchCount = 8

    /// AVFoundation-native video types advertised in Info.plist and NSOpenPanel.
    public static var supportedContentTypes: [UTType] {
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie]
        if let m4v = UTType("com.apple.m4v-video") {
            types.append(m4v)
        }
        return types
    }

    public static func canonicalURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func resolve(
        _ urls: [URL],
        maxBatchCount: Int = Self.maxBatchCount,
        fileManager: FileManager = .default
    ) -> Resolution {
        var seen = Set<URL>()
        var valid: [URL] = []
        var skippedCount = 0

        for url in urls {
            guard url.isFileURL else {
                skippedCount += 1
                continue
            }
            let canonical = canonicalURL(for: url)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                skippedCount += 1
                continue
            }
            if seen.insert(canonical).inserted {
                valid.append(canonical)
            }
        }

        let limit = max(0, maxBatchCount)
        if valid.count > limit {
            return Resolution(
                accepted: Array(valid.prefix(limit)),
                skippedCount: skippedCount,
                truncatedCount: valid.count - limit
            )
        }

        return Resolution(
            accepted: valid,
            skippedCount: skippedCount,
            truncatedCount: 0
        )
    }
}
