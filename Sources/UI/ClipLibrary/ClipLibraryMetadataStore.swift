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

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return [:]
        }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            logger.error("Failed to read clip library metadata: \(String(describing: error), privacy: .public)")
            return [:]
        }

        let metadata: [String: ClipUserMetadata]
        do {
            metadata = try JSONDecoder().decode([String: ClipUserMetadata].self, from: data)
        } catch {
            logger.error("Clip library metadata could not be decoded: \(String(describing: error), privacy: .public)")
            // The library rewrites this file on the next reload, which would
            // silently replace every favorite, tag, and note with nothing.
            // Keep the unreadable copy so it can still be recovered by hand.
            preserveUnreadableFile(at: sourceURL)
            return [:]
        }

        if sourceURL == legacyURL {
            do {
                try data.write(to: currentURL, options: .atomic)
            } catch {
                logger.error("Failed to migrate legacy clip library metadata: \(String(describing: error), privacy: .public)")
            }
        }
        return metadata
    }

    static func unreadableBackupURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".unreadable", isDirectory: false)
    }

    private static func preserveUnreadableFile(at url: URL) {
        let backupURL = unreadableBackupURL(for: url)
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: url, to: backupURL)
        } catch {
            logger.error("Failed to back up unreadable clip library metadata: \(String(describing: error), privacy: .public)")
        }
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
