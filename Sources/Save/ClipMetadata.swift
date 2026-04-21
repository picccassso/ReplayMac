import Foundation
import AVFoundation

public struct ClipInfo: Identifiable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let creationDate: Date
    public let duration: TimeInterval
    public let fileSize: Int64
    public let resolution: CGSize?

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        creationDate: Date,
        duration: TimeInterval,
        fileSize: Int64,
        resolution: CGSize? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.creationDate = creationDate
        self.duration = duration
        self.fileSize = fileSize
        self.resolution = resolution
    }
}

public enum ClipMetadata {
    public static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ReplayMac", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Movies/ReplayMac", isDirectory: true)
    }

    public static func generateUniqueFileURL(in directory: URL) throws -> URL {
        try createOutputDirectoryIfNeeded(directory)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        let baseName = "ReplayMac_\(formatter.string(from: Date()))"
        let ext = "mp4"

        var fileURL = directory.appendingPathComponent("\(baseName).\(ext)")
        var counter = 1

        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = directory.appendingPathComponent("\(baseName)_\(counter).\(ext)")
            counter += 1
        }

        return fileURL
    }

    public static func createOutputDirectoryIfNeeded(_ directory: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public static func makeMetadataItems() -> [AVMetadataItem] {
        let sourceItem = AVMutableMetadataItem()
        sourceItem.key = AVMetadataKey.commonKeySource as (NSCopying & NSObjectProtocol)?
        sourceItem.keySpace = .common
        sourceItem.value = "ReplayMac" as (NSCopying & NSObjectProtocol)?

        let dateFormatter = ISO8601DateFormatter()
        let dateString = dateFormatter.string(from: Date())

        let dateItem = AVMutableMetadataItem()
        dateItem.key = AVMetadataKey.commonKeyCreationDate as (NSCopying & NSObjectProtocol)?
        dateItem.keySpace = .common
        dateItem.value = dateString as (NSCopying & NSObjectProtocol)?

        return [sourceItem, dateItem]
    }

    public static func scanClips(in directory: URL) -> [ClipInfo] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        let mp4URLs = urls.filter { $0.pathExtension.lowercased() == "mp4" }

        return mp4URLs.compactMap { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                return nil
            }

            let creationDate = attributes[.creationDate] as? Date ?? Date()
            let fileSize = attributes[.size] as? Int64 ?? 0

            return ClipInfo(
                fileURL: url,
                creationDate: creationDate,
                duration: 0,
                fileSize: fileSize,
                resolution: nil
            )
        }.sorted { $0.creationDate > $1.creationDate }
    }

    public static func enrichClipInfo(_ info: ClipInfo) async -> ClipInfo {
        let asset = AVURLAsset(url: info.fileURL)
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            let videoTrack = tracks.first { $0.mediaType == .video }
            let resolution = try? await videoTrack?.load(.naturalSize)

            return ClipInfo(
                id: info.id,
                fileURL: info.fileURL,
                creationDate: info.creationDate,
                duration: CMTimeGetSeconds(duration),
                fileSize: info.fileSize,
                resolution: resolution
            )
        } catch {
            return info
        }
    }
}
