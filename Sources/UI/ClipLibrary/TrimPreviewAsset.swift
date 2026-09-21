import Foundation
@preconcurrency import AVFoundation

enum TrimPreviewAssetError: LocalizedError {
    case invalidRange
    case cannotAddTrack
    case noPlayableTracks

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "The selected preview range is invalid."
        case .cannotAddTrack:
            return "Unable to prepare a track for the selected preview."
        case .noPlayableTracks:
            return "The selected preview does not contain playable media."
        }
    }
}

/// Builds a zero-based player asset containing only the selected source range.
/// AVPlayerView then reports the selection's duration instead of the full clip
/// duration, so its native controls agree with the cyan trim timeline.
enum TrimPreviewAsset {
    nonisolated static func make(
        from asset: AVURLAsset,
        startSeconds: Double,
        endSeconds: Double
    ) async throws -> AVAsset {
        guard startSeconds.isFinite,
              endSeconds.isFinite,
              startSeconds >= 0,
              endSeconds > startSeconds else {
            throw TrimPreviewAssetError.invalidRange
        }

        let assetDuration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(assetDuration)
        guard durationSeconds.isFinite else {
            throw TrimPreviewAssetError.invalidRange
        }

        let boundedEnd = min(endSeconds, max(0, durationSeconds))
        guard boundedEnd > startSeconds else {
            throw TrimPreviewAssetError.invalidRange
        }

        let selection = CMTimeRangeFromTimeToTime(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            end: CMTime(seconds: boundedEnd, preferredTimescale: 600)
        )
        let composition = AVMutableComposition()
        let tracks = try await asset.load(.tracks).filter {
            $0.mediaType == .video || $0.mediaType == .audio
        }

        var insertedTrackCount = 0
        for sourceTrack in tracks {
            let sourceRange = try await sourceTrack.load(.timeRange)
            let overlap = CMTimeRangeGetIntersection(selection, otherRange: sourceRange)
            guard overlap.isValid, !overlap.isEmpty else { continue }

            guard let targetTrack = composition.addMutableTrack(
                withMediaType: sourceTrack.mediaType,
                preferredTrackID: sourceTrack.trackID
            ) else {
                throw TrimPreviewAssetError.cannotAddTrack
            }

            let destinationStart = CMTimeSubtract(overlap.start, selection.start)
            try targetTrack.insertTimeRange(overlap, of: sourceTrack, at: destinationStart)
            if sourceTrack.mediaType == .video {
                targetTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
            }
            insertedTrackCount += 1
        }

        guard insertedTrackCount > 0 else {
            throw TrimPreviewAssetError.noPlayableTracks
        }
        return composition
    }
}
