import AppKit
import AVFoundation
import Combine
import Foundation

/// App-owned jobs survive navigation and the destruction of a window's hosting view.
@MainActor
public final class ClipExportCoordinator: ObservableObject {
    @Published public private(set) var isBusy = false
    @Published public private(set) var sourceURL: URL?
    @Published public private(set) var title = ""
    @Published public private(set) var progress: Double?
    @Published public private(set) var completedURL: URL?
    @Published public private(set) var errorMessage: String?
    private var job: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var session: AVAssetExportSession?
    private var customExporter: TrimVideoTranscoder?

    public init() {}

    @discardableResult
    func start(source: URL, title: String,
               operation: @escaping @MainActor () async throws -> URL?) -> Bool {
        guard !isBusy else { return false }
        sourceURL = source.standardizedFileURL
        self.title = title
        isBusy = true
        progress = nil
        completedURL = nil
        errorMessage = nil
        job = Task {
            defer {
                progressTask?.cancel()
                progressTask = nil
                session = nil
                customExporter = nil
                isBusy = false
                sourceURL = nil
                progress = nil
                job = nil
            }
            do {
                try Task.checkCancellation()
                if let url = try await operation() {
                    completedURL = url
                    NotificationCenter.default.post(name: .replayCapLibraryShouldReload, object: nil)
                }
            } catch is CancellationError {
                self.title = "Export cancelled"
            } catch {
                if Task.isCancelled { self.title = "Export cancelled" }
                else { errorMessage = error.localizedDescription }
            }
        }
        return true
    }

    func track(_ session: AVAssetExportSession) {
        self.session = session
        progressTask = Task {
            while !Task.isCancelled {
                progress = Double(session.progress)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func track(_ exporter: TrimVideoTranscoder) { customExporter = exporter }

    public func cancel() {
        job?.cancel()
        session?.cancelExport()
        customExporter?.cancel()
    }

    public func cancelAndWait() async {
        let runningJob = job
        cancel()
        await runningJob?.value
    }

    func dismissResult() {
        guard !isBusy else { return }
        completedURL = nil
        errorMessage = nil
        title = ""
    }

    /// Stage outside the selected destination: failure/cancellation never destroys
    /// an existing user file, and source clips can never be overwritten by export.
    static func write(source: URL, destination: URL,
                      operation: (URL) async throws -> Void) async throws -> URL {
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else {
            throw ExportFileError.sourceOverwrite
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReplayMacExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("export").appendingPathExtension(destination.pathExtension)
        try await operation(staged)
        try Task.checkCancellation()
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        return destination
    }
}

enum ExportFileError: LocalizedError {
    case sourceOverwrite
    var errorDescription: String? { "Choose a different file name. The source clip cannot be overwritten." }
}
