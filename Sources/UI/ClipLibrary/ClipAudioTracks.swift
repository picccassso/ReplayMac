// @preconcurrency: Swift 6.1 (still served by GitHub's macos-latest runners)
// rejects loadTracks' non-Sendable [AVAssetTrack] result; 6.3 accepts it.
@preconcurrency import AVFoundation

/// An audio track a clip player can solo, identified by its persistent track
/// ID in the file. `allTracksID` is a sentinel for "play every track".
struct AudioTrackChoice: Identifiable, Hashable {
    static let allTracksID: CMPersistentTrackID = -1

    let id: CMPersistentTrackID
    let label: String
}

enum ClipAudioTracks {
    /// Returns selectable audio tracks for the clip, or `[]` when the clip has
    /// zero or one audio track (nothing to choose between).
    ///
    /// The save pipeline writes system audio before the microphone when
    /// "Merge audio tracks" is off, so labels are assigned by track order.
    static func choices(for asset: AVURLAsset) async -> [AudioTrackChoice] {
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard tracks.count > 1 else { return [] }
        return tracks.enumerated().map { index, track in
            AudioTrackChoice(id: track.trackID, label: label(forTrackAt: index))
        }
    }

    private static func label(forTrackAt index: Int) -> String {
        switch index {
        case 0: return "System Audio"
        case 1: return "Microphone"
        default: return "Track \(index + 1)"
        }
    }

    /// Mutes every audio track except the selected one (or unmutes all when
    /// `selection` is `allTracksID`). Playback-only; the file is untouched.
    @MainActor
    static func apply(
        selection: CMPersistentTrackID,
        choices: [AudioTrackChoice],
        to item: AVPlayerItem?
    ) {
        guard let item, !choices.isEmpty else { return }
        let mix = AVMutableAudioMix()
        mix.inputParameters = choices.map { choice in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = choice.id
            let isAudible = selection == AudioTrackChoice.allTracksID || selection == choice.id
            parameters.setVolume(isAudible ? 1 : 0, at: .zero)
            return parameters
        }
        item.audioMix = mix
    }

    /// Builds a composition with the clip's video and only the selected audio
    /// track, so an export drops the other tracks entirely. Falls back to the
    /// original asset if the track is no longer present in the file.
    ///
    /// Deliberately not main-actor isolated: `insertTimeRange` is synchronous
    /// and can take real time on a long clip, which has no business blocking
    /// the main thread.
    nonisolated static func soloComposition(
        from asset: AVURLAsset,
        audioTrackID: CMPersistentTrackID
    ) async throws -> AVAsset {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let soloTrack = audioTracks.first(where: { $0.trackID == audioTrackID }) else {
            return asset
        }

        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: duration)

        for videoTrack in try await asset.loadTracks(withMediaType: .video) {
            guard let target = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw TrimExportError.cannotBuildComposition
            }
            try target.insertTimeRange(fullRange, of: videoTrack, at: .zero)
            target.preferredTransform = try await videoTrack.load(.preferredTransform)
        }

        guard let target = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TrimExportError.cannotBuildComposition
        }
        try target.insertTimeRange(fullRange, of: soloTrack, at: .zero)

        return composition
    }
}
