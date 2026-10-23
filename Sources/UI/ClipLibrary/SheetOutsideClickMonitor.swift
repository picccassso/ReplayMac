import SwiftUI
import AppKit

struct SheetOutsideClickMonitor: NSViewRepresentable {
    var onOutsideClick: () -> Void

    func makeNSView(context: Context) -> OutsideClickMonitorView {
        let view = OutsideClickMonitorView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ nsView: OutsideClickMonitorView, context: Context) {
        nsView.onOutsideClick = onOutsideClick
    }
}

final class OutsideClickMonitorView: NSView {
    var onOutsideClick: (() -> Void)?
    // Only touched on the main thread; nonisolated(unsafe) just lets deinit remove it.
    nonisolated(unsafe) private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitorIfNeeded()
        } else {
            removeMonitor()
        }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self,
                  let sheetWindow = self.window,
                  let parentWindow = sheetWindow.sheetParent else {
                return event
            }
            if let eventWindow = event.window,
               eventWindow !== sheetWindow,
               eventWindow !== parentWindow {
                return event
            }
            let screenPoint = NSEvent.mouseLocation
            if !sheetWindow.frame.contains(screenPoint),
               parentWindow.frame.contains(screenPoint) {
                self.removeMonitor()
                DispatchQueue.main.async { [weak self] in
                    self?.onOutsideClick?()
                }
                return nil
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
