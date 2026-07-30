import AppKit
import UniformTypeIdentifiers

@MainActor
enum ExportDestinationPicker {
    /// Asks for an export destination without blocking the main thread.
    ///
    /// `NSSavePanel.runModal()` spins a nested modal run loop in
    /// `NSModalPanelRunLoopMode`, which does not service Swift concurrency's
    /// main-actor jobs. Called from an `async` context — as every export path
    /// here does — that freezes every other main-actor continuation in the app
    /// until the panel closes, and leaves no way out if anything the panel
    /// itself depends on needs the main actor. `begin(completionHandler:)`
    /// keeps the panel app-modal for the user while leaving the run loop and
    /// the main actor free.
    static func chooseDestination(
        suggestedURL: URL,
        contentType: UTType,
        title: String
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true

        let response = await withCheckedContinuation { continuation in
            // `begin` retains the panel until the handler runs, and the handler
            // is guaranteed to be called exactly once.
            panel.begin { continuation.resume(returning: $0) }
        }

        guard response == .OK else { return nil }
        return panel.url
    }
}
