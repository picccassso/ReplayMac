import Foundation

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
    private static let metadataFileName = ".ReplayMacClipLibrary.json"

    static func metadataURL(in directory: URL) -> URL {
        directory.appendingPathComponent(metadataFileName, isDirectory: false)
    }

    static func load(in directory: URL) -> [String: ClipUserMetadata] {
        let url = metadataURL(in: directory)
        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }

        return (try? JSONDecoder().decode([String: ClipUserMetadata].self, from: data)) ?? [:]
    }

    static func save(_ metadata: [String: ClipUserMetadata], in directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.prettyReplayMac.encode(metadata)
            try data.write(to: metadataURL(in: directory), options: .atomic)
        } catch {
            print("Failed to save clip library metadata: \(error)")
        }
    }

    static func key(for url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }
}

private extension JSONEncoder {
    static var prettyReplayMac: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
