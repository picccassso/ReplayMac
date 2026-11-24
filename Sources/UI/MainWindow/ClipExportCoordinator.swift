import AppKit
import AVFoundation
import Combine
import Foundation

public enum ClipExportOrigin: Equatable, Sendable {
    case mainWindow
    case editor
}

/// App-owned jobs survive navigation and the destruction of a window's hosting view.
@MainActor
public final class ClipExportCoordinator: ObservableObject {
    public static let defaultAutoDismissDelay: Duration = .seconds(6)
    public static let defaultHoverResumeDelay: Duration = .seconds(2.5)
    static let mainWindowPauseSource = "mainWindow"

    static func editorPauseSource(for url: URL) -> String {
        "trimEditor:\(ExternalVideoOpenPolicy.canonicalURL(for: url).path)"
    }

    @Published public private(set) var isBusy = false
    @Published public private(set) var sourceURL: URL?
    @Published public private(set) var title = ""
    @Published public private(set) var progress: Double?
    @Published public private(set) var origin: ClipExportOrigin?
    @Published public private(set) var completedURL: URL?
    @Published public private(set) var errorMessage: String?
    /// Canonical URL of the clip that produced `completedURL` or `errorMessage`,
    /// so a standalone editor window can surface completion/error feedback even
    /// when the main window is closed.
    @Published public private(set) var resultSourceURL: URL?
    @Published public private(set) var resultOrigin: ClipExportOrigin?
    private let autoDismissDelay: Duration
    private let hoverResumeDelay: Duration
    private var job: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var autoDismissTask: Task<Void, Never>?
    private var autoDismissPauseSources: Set<String> = []
    private var resultID = UUID()
    private var session: AVAssetExportSession?
    private var customExporter: TrimVideoTranscoder?

    public init(autoDismissDelay: Duration = ClipExportCoordinator.defaultAutoDismissDelay,
                hoverResumeDelay: Duration = ClipExportCoordinator.defaultHoverResumeDelay) {
        self.autoDismissDelay = autoDismissDelay
        self.hoverResumeDelay = hoverResumeDelay
    }

    @discardableResult
    func start(source: URL, title: String, origin: ClipExportOrigin = .mainWindow,
               operation: @escaping @MainActor () async throws -> URL?) -> Bool {
        guard !isBusy else { return false }
        let canonicalSource = ExternalVideoOpenPolicy.canonicalURL(for: source)
        cancelAutoDismiss()
        resultID = UUID()
        sourceURL = canonicalSource
        self.title = title
        self.origin = origin
        isBusy = true
        progress = nil
        completedURL = nil
        errorMessage = nil
        resultSourceURL = nil
        resultOrigin = nil
        job = Task {
            defer {
                progressTask?.cancel()
                progressTask = nil
                session = nil
                customExporter = nil
                isBusy = false
                sourceURL = nil
                self.origin = nil
                progress = nil
                job = nil
            }
            do {
                try Task.checkCancellation()
                if let url = try await operation() {
                    completedURL = url
                    resultSourceURL = canonicalSource
                    resultOrigin = origin
                    resultID = UUID()
                    scheduleAutoDismiss(after: autoDismissDelay)
                    NotificationCenter.default.post(name: .replayCapLibraryShouldReload, object: nil)
                }
            } catch is CancellationError {
                self.title = "Export cancelled"
            } catch {
                if Task.isCancelled { self.title = "Export cancelled" }
                else {
                    errorMessage = error.localizedDescription
                    resultSourceURL = canonicalSource
                    resultOrigin = origin
                    resultID = UUID()
                }
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

    func track(_ exporter: TrimVideoTranscoder) {
        customExporter = exporter
        progressTask = Task {
            while !Task.isCancelled {
                progress = exporter.progress
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

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

    func setAutoDismissPaused(_ paused: Bool, source: String) {
        if paused {
            autoDismissPauseSources.insert(source)
            cancelAutoDismiss()
        } else {
            guard autoDismissPauseSources.remove(source) != nil else { return }
            if autoDismissPauseSources.isEmpty,
               !isBusy,
               completedURL != nil,
               errorMessage == nil {
                scheduleAutoDismiss(after: min(autoDismissDelay, hoverResumeDelay))
            }
        }
    }

    func dismissResult() {
        guard !isBusy else { return }
        cancelAutoDismiss()
        resultID = UUID()
        completedURL = nil
        errorMessage = nil
        resultSourceURL = nil
        resultOrigin = nil
        title = ""
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }

    private func scheduleAutoDismiss(after delay: Duration) {
        cancelAutoDismiss()
        guard autoDismissPauseSources.isEmpty,
              completedURL != nil,
              errorMessage == nil else { return }
        let expectedID = resultID
        autoDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  !self.isBusy,
                  self.resultID == expectedID,
                  self.autoDismissPauseSources.isEmpty,
                  self.errorMessage == nil,
                  self.completedURL != nil else { return }
            self.dismissResult()
        }
    }

    /// Stage outside the selected destination: failure/cancellation never destroys
    /// an existing user file, and source clips can never be overwritten by export.
    static func write(source: URL, destination: URL,
                      operation: (URL) async throws -> Void) async throws -> URL {
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else {
            throw ExportFileError.sourceOverwrite
        }
        let sourceAccess = source.startAccessingSecurityScopedResource()
        defer { if sourceAccess { source.stopAccessingSecurityScopedResource() } }
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
