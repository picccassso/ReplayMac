// @preconcurrency: kept from ClipLibraryView.swift, where this code used to
// live, so Swift 6.1 (GitHub's macos-latest runners) checks it the same way.
@preconcurrency import AVFoundation

enum TrimExportError: LocalizedError {
    case cannotCreateSession
    case cannotBuildComposition
    case exportFailed
    case stalled

    var errorDescription: String? {
        switch self {
        case .cannotCreateSession:
            return "Unable to create a trim export session."
        case .cannotBuildComposition:
            return "Unable to prepare the selected audio track for export."
        case .exportFailed:
            return "Trim export did not complete."
        case .stalled:
            return "The export stopped making progress and was cancelled. Please try again."
        }
    }
}

/// Carries an export session to the stall watchdog, which deliberately runs
/// off the main actor so it still fires if the main actor is starved.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

enum ExportWatchdog {
    /// Seconds of zero progress before an export is treated as wedged.
    static let stallTimeout = 90

    /// Runs an export, cancelling it if `progress` stops advancing entirely.
    ///
    /// Without this a stuck export leaves the sheet spinning forever with no
    /// way out but force-quitting. Progress-based rather than a flat deadline,
    /// so a slow-but-advancing export of a long clip is never killed. The
    /// watchdog is detached on purpose: a main-actor watchdog cannot fire in
    /// exactly the situation it exists to catch.
    @MainActor
    static func runExport(
        _ session: AVAssetExportSession,
        to outputURL: URL,
        as fileType: AVFileType
    ) async throws {
        let box = ExportSessionBox(session)
        let watchdog = Task.detached(priority: .utility) {
            var lastProgress: Float = -1
            var stalledSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                let progress = box.session.progress
                if progress > lastProgress {
                    lastProgress = progress
                    stalledSeconds = 0
                } else {
                    stalledSeconds += 2
                    if stalledSeconds >= stallTimeout {
                        box.session.cancelExport()
                        return
                    }
                }
            }
        }
        defer { watchdog.cancel() }

        try await session.export(to: outputURL, as: fileType)
    }
}
