import Foundation

public enum WatermarkCompositor {
    public static func applyIfEnabled(to clipURL: URL, enabled: Bool) async throws -> URL {
        guard enabled else {
            return clipURL
        }

        // Full visual watermark compositing requires at least partial re-encode.
        // Keep this as a no-op by default to preserve near-instant save latency.
        return clipURL
    }
}
