import AppKit
import SwiftUI

/// One Trim & Export window per clip. Closing the window ends that edit; an
/// export already running continues in the app-owned coordinator.
@MainActor
final class ClipEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [URL: ClipEditorWindowController] = [:]
    private static let savedFrameName = "ReplayMacTrimExport"
    private let session: ClipEditorSession
    private weak var state: MainWindowState?
    private var fullScreenTransition = false

    static func show(session: ClipEditorSession, state: MainWindowState) {
        let controller = windows[session.url] ?? {
            let controller = ClipEditorWindowController(session: session, state: state)
            windows[session.url] = controller
            return controller
        }()
        controller.window?.deminiaturize(nil)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(session: ClipEditorSession, state: MainWindowState) {
        self.session = session
        self.state = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Trim & Export"
        window.subtitle = session.url.lastPathComponent
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        let editor = ClipTrimView(session: session, exports: session.exports) { [weak self] in self?.close() }
            .tint(AppTheme.accent)
        window.contentViewController = NSHostingController(rootView: editor)
        let titleBarHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            window.setContentSize(NSSize(width: min(1280, visible.width * 0.9),
                                         height: min(800, visible.height * 0.9)))
        }
        window.center()
        _ = window.setFrameUsingName(Self.savedFrameName)
        let restoredScreen = NSScreen.screens.max { lhs, rhs in
            let left = window.frame.intersection(lhs.visibleFrame)
            let right = window.frame.intersection(rhs.visibleFrame)
            return (left.isNull ? 0 : left.width * left.height) < (right.isNull ? 0 : right.width * right.height)
        }
        let screenWithOverlap = restoredScreen.flatMap { window.frame.intersects($0.visibleFrame) ? $0 : nil }
        if let visible = (screenWithOverlap ?? screen)?.visibleFrame {
            window.contentMinSize = NSSize(width: min(960, visible.width),
                                           height: min(640, max(1, visible.height - titleBarHeight)))
            window.setFrame(MainWindowGeometry.visibleFrame(window.frame, within: visible), display: false)
        }
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    // A shared autosave name can belong to only one live NSWindow. Save explicitly
    // so every editor window remembers the last ordinary window frame.
    private func saveFrame() {
        guard !fullScreenTransition, let window,
              !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: Self.savedFrameName)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowWillEnterFullScreen(_ notification: Notification) { fullScreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransition = false
        saveFrame()
    }
    func windowDidMiniaturize(_ notification: Notification) { session.pause() }
    func windowDidDeminiaturize(_ notification: Notification) { session.isVisible = true }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        Self.windows.removeValue(forKey: session.url)
        state?.closeEditor(session.url)
        // Release the hosting view and its player even if an asynchronous callback still
        // retains the controller until the end of this run-loop iteration.
        window?.contentViewController = nil
    }
}
