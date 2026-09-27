import Foundation

public enum SavePreflightFailure: Equatable {
    case saveInProgress
    case notRecording
    case replayBufferUnavailable
    case bufferEmpty
    case insufficientDiskSpace
}

public enum SavePreflight {
    public static let minimumBufferedSeconds: TimeInterval = 1

    public static func canSaveQuickReplay(
        isRecording: Bool,
        bufferedSeconds: TimeInterval,
        saveInProgress: Bool,
        replayBufferEnabled: Bool = true
    ) -> Bool {
        failure(
            isRecording: isRecording,
            bufferedSeconds: bufferedSeconds,
            saveInProgress: saveInProgress,
            replayBufferEnabled: replayBufferEnabled
        ) == nil
    }

    public static func canSaveLongReplay(
        isRecording: Bool,
        saveInProgress: Bool,
        replayBufferEnabled: Bool = true
    ) -> Bool {
        isRecording && !saveInProgress && replayBufferEnabled
    }

    public static func bufferedSeconds(
        primaryVideo: TimeInterval,
        dualDisplay1: TimeInterval,
        dualDisplay2: TimeInterval,
        isSeparateDualSave: Bool
    ) -> TimeInterval {
        guard isSeparateDualSave else {
            return primaryVideo
        }

        return min(dualDisplay1, dualDisplay2)
    }

    /// - Parameter replayBufferEnabled: false while a session recording owns
    ///   the capture pipeline. The buffers are deliberately not being filled,
    ///   so reporting them as still filling would promise something that will
    ///   never happen.
    public static func failure(
        isRecording: Bool,
        bufferedSeconds: TimeInterval,
        saveInProgress: Bool,
        replayBufferEnabled: Bool = true,
        minimumBufferedSeconds: TimeInterval = minimumBufferedSeconds
    ) -> SavePreflightFailure? {
        if saveInProgress {
            return .saveInProgress
        }
        if !isRecording {
            return .notRecording
        }
        if !replayBufferEnabled {
            return .replayBufferUnavailable
        }
        if bufferedSeconds < minimumBufferedSeconds {
            return .bufferEmpty
        }
        return nil
    }

    public static func notificationMessage(for failure: SavePreflightFailure) -> (title: String, body: String) {
        switch failure {
        case .saveInProgress:
            return ("Save Already in Progress", "Wait for the current clip to finish saving.")
        case .notRecording:
            return ("Not Recording", "Start recording before saving a clip.")
        case .replayBufferUnavailable:
            return (
                "Replay Buffer Off",
                "A session recording is in progress. Stop it to save the session, or start buffer recording to capture replays."
            )
        case .bufferEmpty:
            return ("Buffer Still Filling", "Wait a moment for footage to buffer before saving.")
        case .insufficientDiskSpace:
            return ("Not Enough Disk Space", "Free up space on your drive before saving this clip.")
        }
    }

    /// Rough upper-bound size of a clip from its target bitrate and duration.
    /// `streamCount` covers separate dual-display saves (two files), and
    /// `overhead` pads for muxing, audio tracks, and keyframe bitrate spikes.
    public static func estimatedClipBytes(
        bitrateMbps: Double,
        durationSeconds: TimeInterval,
        streamCount: Int = 1,
        overhead: Double = 1.2
    ) -> Int64 {
        guard bitrateMbps > 0, durationSeconds > 0 else {
            return 0
        }
        let bytesPerStream = (bitrateMbps * 1_000_000 / 8) * durationSeconds
        let total = bytesPerStream * Double(max(streamCount, 1)) * overhead
        return Int64(total)
    }

    /// Reports a failure when the volume lacks room for the estimated clip plus
    /// a safety margin. Returns `nil` when the estimate is unknown (zero) so a
    /// missing estimate never blocks a save.
    public static func diskFailure(
        estimatedClipBytes: Int64,
        availableCapacityBytes: Int64,
        safetyMarginBytes: Int64 = 200 * 1024 * 1024
    ) -> SavePreflightFailure? {
        guard estimatedClipBytes > 0 else {
            return nil
        }
        if availableCapacityBytes < estimatedClipBytes + safetyMarginBytes {
            return .insufficientDiskSpace
        }
        return nil
    }

    /// Resolves available volume capacity from macOS resource keys.
    ///
    /// `CacheDelete` (which backs `.volumeAvailableCapacityForImportantUsageKey`)
    /// only tracks purgeable space on the boot volume group and returns `0` on
    /// external APFS drives. Falling back to `.volumeAvailableCapacityKey` when
    /// `importantUsage` is zero or missing avoids false "disk full" failures on
    /// external drives while still reporting `0` when a volume is genuinely full.
    public static func resolvedAvailableCapacityBytes(
        importantUsage: Int64?,
        standardCapacity: Int?
    ) -> Int64? {
        let standard = standardCapacity.map(Int64.init)
        if let importantUsage, importantUsage > 0 {
            if let standard, standard > importantUsage {
                return standard
            }
            return importantUsage
        }
        return standard
    }

    /// Returns the volume name when `url` points inside `/Volumes/<VolumeName>`
    /// and that mount point does not currently exist on disk.
    public static func unmountedExternalVolumeName(
        for url: URL,
        volumesRootURL: URL = URL(filePath: "/Volumes", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) -> String? {
        let standardized = url.standardizedFileURL
        let volumesRoot = volumesRootURL.standardizedFileURL
        let rootComponents = volumesRoot.pathComponents
        let components = standardized.pathComponents

        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }

        let volumeName = components[rootComponents.count]
        guard !volumeName.isEmpty, volumeName != "/" else {
            return nil
        }

        let mountPointURL = volumesRoot.appendingPathComponent(volumeName, isDirectory: true)
        guard !fileManager.fileExists(atPath: mountPointURL.path(percentEncoded: false)) else {
            return nil
        }
        return volumeName
    }

    /// Finds the nearest existing directory on the same volume as `outputURL`
    /// so disk-capacity checks probe the target drive even before the leaf
    /// output folder has been created on first save.
    public static func existingProbeURL(
        for outputURL: URL,
        fallbackURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumesRootURL: URL = URL(filePath: "/Volumes", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) -> URL {
        let volumesRootPath = volumesRootURL.standardizedFileURL.path(percentEncoded: false)
        var candidate = outputURL.standardizedFileURL

        while true {
            let path = candidate.path(percentEncoded: false)
            if path == "/" || path == volumesRootPath || path.isEmpty {
                break
            }
            if fileManager.fileExists(atPath: path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent == candidate {
                break
            }
            candidate = parent
        }

        return fallbackURL.standardizedFileURL
    }

    public static func availableCapacityBytes(
        for outputURL: URL,
        fallbackURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumesRootURL: URL = URL(filePath: "/Volumes", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) -> Int64? {
        if unmountedExternalVolumeName(
            for: outputURL,
            volumesRootURL: volumesRootURL,
            fileManager: fileManager
        ) != nil {
            return nil
        }

        let probeURL = existingProbeURL(
            for: outputURL,
            fallbackURL: fallbackURL,
            volumesRootURL: volumesRootURL,
            fileManager: fileManager
        )
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        if let values = try? probeURL.resourceValues(forKeys: keys),
           let resolved = resolvedAvailableCapacityBytes(
               importantUsage: values.volumeAvailableCapacityForImportantUsage,
               standardCapacity: values.volumeAvailableCapacity
           ) {
            return resolved
        }

        let volumesPrefix = volumesRootURL.standardizedFileURL.path(percentEncoded: false) + "/"
        let isExternalPath = outputURL.standardizedFileURL.path(percentEncoded: false).hasPrefix(volumesPrefix)
        if !isExternalPath, probeURL != fallbackURL.standardizedFileURL,
           let fallbackValues = try? fallbackURL.resourceValues(forKeys: keys) {
            return resolvedAvailableCapacityBytes(
                importantUsage: fallbackValues.volumeAvailableCapacityForImportantUsage,
                standardCapacity: fallbackValues.volumeAvailableCapacity
            )
        }

        return nil
    }
}
