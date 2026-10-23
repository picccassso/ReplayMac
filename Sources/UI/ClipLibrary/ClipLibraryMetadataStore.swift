import Foundation
import os

struct ClipUserMetadata: Codable, Equatable {
    var displayName: String
    var isFavorite: Bool
    var tags: [String]
    var notes: String

    static let empty = ClipUserMetadata(displayName: "", isFavorite: false, tags: [], notes: "")
}

struct ClipLibraryStorageSummary: Equatable {
    var clipCount: Int
    var totalBytes: Int64
    var oldestClipDate: Date?
}

enum ClipLibraryMetadataStore {
    static let logger = Logger(subsystem: "com.replaycap", category: "ClipLibrary")
    private static let metadataFileName = ".ReplayCapClipLibrary.json"
    private static let legacyMetadataFileName = ".ReplayMacClipLibrary.json"

    static func metadataURL(in directory: URL) -> URL {
        directory.appendingPathComponent(metadataFileName, isDirectory: false)
    }

    static func load(in directory: URL) -> [String: ClipUserMetadata] {
        let currentURL = metadataURL(in: directory)
        let legacyURL = directory.appendingPathComponent(legacyMetadataFileName, isDirectory: false)
        let sourceURL = FileManager.default.fileExists(atPath: currentURL.path)
            ? currentURL
            : legacyURL

        guard let data = try? Data(contentsOf: sourceURL),
              let metadata = try? JSONDecoder().decode([String: ClipUserMetadata].self, from: data) else {
            return [:]
        }

        if sourceURL == legacyURL {
            try? data.write(to: currentURL, options: .atomic)
        }
        return metadata
    }

    static func save(_ metadata: [String: ClipUserMetadata], in directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.prettyReplayCap.encode(metadata)
            try data.write(to: metadataURL(in: directory), options: .atomic)
        } catch {
            logger.error("Failed to save clip library metadata: \(String(describing: error), privacy: .public)")
        }
    }

    static func key(for url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }
}

private extension JSONEncoder {
    static var prettyReplayCap: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
