import AppKit
import SwiftUI

@MainActor
final class TrimEditorActivity: ObservableObject {
    @Published var isExporting = false
    @Published var isExportingGIF = false
    var isBusy: Bool { isExporting || isExportingGIF }
}

/// Owns editors independently of the library's SwiftUI lifetime.
@MainActor
final class ClipTrimWindowController: NSWindowController, NSWindowDelegate {
    private static var editors: [URL: ClipTrimWindowController] = [:]
    private let sourceURL: URL
    private let activity = TrimEditorActivity()
    private var fullScreenTransition = false
    private static let savedFrameName = "ReplayMacTrimExport"

    static func open(url: URL, onExport: @escaping () -> Void) {
        let key = url.standardizedFileURL
        if let existing = editors[key] {
            existing.window?.deminiaturize(nil)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ClipTrimWindowController(url: key, onExport: onExport)
        editors[key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(url: URL, onExport: @escaping () -> Void) {
        sourceURL = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Trim and Export"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        let editor = ClipTrimView(url: url, onExport: onExport,
                                  onClose: { [weak self] in self?.close() }, activity: activity)
        window.contentViewController = NSHostingController(rootView: editor)
        let titleBarHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            window.setContentSize(NSSize(width: min(1280, visible.width * 0.9),
                                         height: min(800, visible.height * 0.9)))
            window.contentMinSize = NSSize(width: min(960, visible.width),
                                          height: min(640, max(1, visible.height - titleBarHeight)))
        }
        window.center()
        _ = window.setFrameUsingName(Self.savedFrameName)
        let restoredScreen = NSScreen.screens.max { lhs, rhs in
            let left = window.frame.intersection(lhs.visibleFrame)
            let right = window.frame.intersection(rhs.visibleFrame)
            let leftArea = left.isNull ? 0 : left.width * left.height
            let rightArea = right.isNull ? 0 : right.width * right.height
            return leftArea < rightArea
        }
        let screenWithOverlap = restoredScreen.flatMap {
            window.frame.intersects($0.visibleFrame) ? $0 : nil
        }
        if let visible = (screenWithOverlap ?? screen)?.visibleFrame {
            window.contentMinSize = NSSize(width: min(960, visible.width),
                                          height: min(640, max(1, visible.height - titleBarHeight)))
            window.setFrame(Self.visibleFrame(window.frame, within: visible), display: false)
        }
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    static func visibleFrame(_ frame: NSRect, within visible: NSRect) -> NSRect {
        let size = NSSize(width: min(frame.width, visible.width),
                          height: min(frame.height, visible.height))
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !activity.isBusy }

    // A shared autosave name can belong to only one live NSWindow. Save explicitly
    // so every independent clip editor can remember the last ordinary window frame.
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

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        Self.editors.removeValue(forKey: sourceURL)
        // Release the hosting view and its player even if an asynchronous callback still
        // retains the controller until the end of this run-loop iteration.
        window?.contentViewController = nil
    }
}
