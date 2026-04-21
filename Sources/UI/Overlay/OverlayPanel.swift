import AppKit
import SwiftUI

@MainActor
public final class OverlayPanel: @unchecked Sendable {
    private let model = RecordingDotModel()
    private var panel: NSPanel?
    private var isEnabled = true
    private var corner: OverlayCorner = .topRight

    public init() {}

    public func applySettings(isEnabled: Bool, corner: OverlayCorner) {
        self.isEnabled = isEnabled
        self.corner = corner

        if isEnabled {
            ensurePanel()
            updatePanelFrame(animated: false)
            showIfNeeded()
        } else {
            panel?.orderOut(nil)
        }
    }

    public func setRecording(_ isRecording: Bool) {
        model.isRecording = isRecording
        if isRecording {
            showIfNeeded()
        } else {
            panel?.orderOut(nil)
        }
    }

    public func showSavedToast() {
        guard isEnabled else {
            return
        }
        ensurePanel()
        model.flashSavedToast()
        showIfNeeded()
    }

    private func ensurePanel() {
        guard panel == nil else {
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        let rootView = RecordingDotView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .allowsHitTesting(false)
            .background(Color.clear)

        panel.contentView = NSHostingView(rootView: rootView)
        self.panel = panel
    }

    private func showIfNeeded() {
        guard isEnabled, (model.isRecording || model.showSavedToast) else {
            return
        }
        updatePanelFrame(animated: false)
        panel?.orderFrontRegardless()
    }

    private func updatePanelFrame(animated: Bool) {
        guard let panel,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let visible = screen.visibleFrame
        let width: CGFloat = 220
        let height: CGFloat = 60
        let inset: CGFloat = 16

        let origin: CGPoint
        switch corner {
        case .topLeft:
            origin = CGPoint(x: visible.minX + inset, y: visible.maxY - height - inset)
        case .topRight:
            origin = CGPoint(x: visible.maxX - width - inset, y: visible.maxY - height - inset)
        case .bottomLeft:
            origin = CGPoint(x: visible.minX + inset, y: visible.minY + inset)
        case .bottomRight:
            origin = CGPoint(x: visible.maxX - width - inset, y: visible.minY + inset)
        }

        panel.setFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)), display: true, animate: animated)
    }
}
