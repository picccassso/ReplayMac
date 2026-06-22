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

    /// Default base name when no template is supplied, e.g.
    /// `ReplayMac_2026-06-22_11-00-21`.
    public static func defaultBaseName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return "ReplayMac_\(formatter.string(from: date))"
    }

    /// - Parameter baseName: The resolved file name without extension or
    ///   suffix. When `nil`, falls back to ``defaultBaseName(date:)``.
    public static func generateUniqueFileURL(
        in directory: URL,
        baseName: String? = nil,
        suffix: String? = nil
    ) throws -> URL {
        try createOutputDirectoryIfNeeded(directory)

        let cleanSuffix = suffix.map { "_\($0)" } ?? ""
        let resolvedBase = "\(baseName ?? defaultBaseName())\(cleanSuffix)"
        let ext = "mp4"

        var fileURL = directory.appendingPathComponent("\(resolvedBase).\(ext)")
        var counter = 1

        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = directory.appendingPathComponent("\(resolvedBase)_\(counter).\(ext)")
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
