import AppKit
import SwiftUI

/// The floating card shown after a save (when enabled) or from the Edit last
/// clip hotkey. It is a non-activating panel, so a game in front keeps keyboard
/// and mouse focus; only Trim brings ReplayMac forward.
@MainActor
public final class ClipThumbnailPanelController {
    /// Opens the Trim & Export editor. The app delegate owns activation.
    public var onTrim: ((URL) -> Void)?

    static let cardSize = CGSize(width: 260, height: 160)
    static let screenInset: CGFloat = 20
    private static let copiedDismissDelay: Duration = .milliseconds(900)

    private let model = SavedClipCardModel()
    private var panel: ClipThumbnailPanel?
    private var hideTask: Task<Void, Never>?
    private var isDismissing = false

    public init() {}

    /// Shows the card for `url`. A card already on screen switches to the new
    /// clip in place instead of stacking a second one.
    public func show(url: URL) {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.load(url)

        // The fade-in below supersedes a fade-out still in progress.
        isDismissing = false
        if !panel.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                panel.setFrame(Self.frame(for: Self.cardSize, in: visible), display: false)
            }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        scheduleAutoHide()
    }

    public func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible, !isDismissing else { return }
        isDismissing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                // A show() during the fade brings the card back; leave it up.
                guard let self, self.isDismissing else { return }
                self.isDismissing = false
                panel.orderOut(nil)
                self.model.reset()
            }
        }
    }

    /// Bottom-left corner of the screen's visible area, clear of the Dock.
    static func frame(for size: CGSize, in visibleFrame: CGRect) -> CGRect {
        CGRect(x: visibleFrame.minX + screenInset, y: visibleFrame.minY + screenInset,
               width: size.width, height: size.height)
    }

    /// How long the card stays when not hovered, or nil to keep it until dismissed.
    static func autoHideDelay(seconds: Int) -> Duration? {
        seconds > 0 ? .seconds(seconds) : nil
    }

    private func makePanel() -> ClipThumbnailPanel {
        let panel = ClipThumbnailPanel(contentRect: CGRect(origin: .zero, size: Self.cardSize))
        let view = SavedClipCard(
            model: model,
            onClose: { [weak self] in self?.dismiss() },
            onReveal: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
            onCopy: { [weak self] url in self?.copy(url) },
            onTrim: { [weak self] url in
                self?.dismiss()
                self?.onTrim?(url)
            }
        )
        .themedWindowRoot()
        let hostingView = ClipThumbnailHostingView(rootView: view)
        hostingView.onHoverChanged = { [weak self] hovering in
            self?.model.isHovered = hovering
            if hovering {
                self?.hideTask?.cancel()
            } else {
                self?.scheduleAutoHide()
            }
        }
        panel.contentView = hostingView
        return panel
    }

    private func copy(_ url: URL) {
        StatusItemController.copyToPasteboard(url)
        model.showsCopied = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.copiedDismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = nil
        guard !model.isHovered,
              let delay = Self.autoHideDelay(seconds: AppSettings.clipThumbnailDurationSeconds) else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}

/// Borderless, non-activating, and present on every Space including fullscreen
/// games, so the card can float over gameplay without taking focus.
private final class ClipThumbnailPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Reports hover with an always-active tracking area and takes the first click,
/// because the panel sits in an app that is usually not frontmost.
private final class ClipThumbnailHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }
}
