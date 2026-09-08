@preconcurrency import AVFoundation

/// H.264 export presets tone-map HDR to SDR. Choose HEVC whenever a source
/// track contains HDR, including compositions assembled from saved segments.
public enum HDRVideoExport {
    public static func transcodePreset(for asset: AVAsset) async throws -> String {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        for track in tracks {
            if try await track.load(.mediaCharacteristics).contains(.containsHDRVideo) {
                return AVAssetExportPresetHEVCHighestQuality
            }
        }
        return AVAssetExportPresetHighestQuality
    }
}
