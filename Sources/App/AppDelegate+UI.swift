import Branding
import Capture
import Cocoa
import SwiftUI
import UI
import Defaults

@MainActor
extension AppDelegate {
    func setupWindowObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func setupPowerObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    func setupDisplayObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        displayReconfigurationTask?.cancel()
        displayReconfigurationTask = Task { @MainActor [weak self] in
            // Debounce slightly so displays and ScreenCaptureKit have time to settle after reconnect or wake
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await self.handleDisplayConfigurationChange()
        }
    }

    func handleDisplayConfigurationChange() async {
        guard isCaptureRunning else { return }

        let online = DisplayIdentity.onlineDisplayIDs()
        guard !online.isEmpty else { return }

        let isDual = AppSettings.captureMode == CaptureMode.dualSideBySide.rawValue

        if isDual {
            let pref1 = AppSettings.captureDisplayID
            let pref2 = AppSettings.captureDisplayID2
            let resolved1 = DisplayIdentity.resolve(pref1, among: online)
            let remainingOnline = online.filter { $0 != resolved1 }
            let resolved2 = DisplayIdentity.resolve(pref2, among: remainingOnline) ?? remainingOnline.first

            let captured1 = await captureManager.capturedDisplayID1
            let captured2 = await captureManager.capturedDisplayID2
            let fallback1 = await captureManager.isUsingFallbackDisplay1
            let fallback2 = await captureManager.isUsingFallbackDisplay2

            let targetChanged1 = resolved1 != nil && resolved1 != captured1
            let targetChanged2 = resolved2 != nil && resolved2 != captured2
            let fallbackActive = fallback1 || fallback2

            if (targetChanged1 || targetChanged2 || fallbackActive),
               let resolved1, let resolved2, resolved1 != resolved2 {
                captureRecoveryLogger.info(
                    "Display configuration changed; re-targeting dual capture to preferred displays (\(resolved1), \(resolved2))"
                )
                await restartFullPipeline()
            }
        } else {
            let priorities = AppSettings.captureDisplayPriorities
            let effectivePriorities = !priorities.isEmpty ? priorities : [AppSettings.captureDisplayID].filter { !$0.isEmpty }
            guard !effectivePriorities.isEmpty else { return }

            let resolved = DisplayIdentity.resolveFirst(in: effectivePriorities, among: online)
            let captured = await captureManager.capturedDisplayID
            let isFallback = await captureManager.isUsingFallbackDisplay

            if let resolved, (isFallback || resolved != captured) {
                captureRecoveryLogger.info(
                    "Display priority resolution changed (resolved: \(resolved), previous: \(String(describing: captured)), wasFallback: \(isFallback)); re-targeting capture"
                )
                await restartFullPipeline()
            }
        }
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        areScreensAwake = false
        prepareCaptureForAutomaticResume(reason: "system sleep")
    }

    @objc private func systemDidWake(_ notification: Notification) {
        areScreensAwake = true
        scheduleCaptureRecoveryIfNeeded(reason: "system wake")
    }

    @objc private func screensDidSleep(_ notification: Notification) {
        areScreensAwake = false
        prepareCaptureForAutomaticResume(reason: "screens sleeping")
    }

    @objc private func screensDidWake(_ notification: Notification) {
        areScreensAwake = true
        scheduleCaptureRecoveryIfNeeded(reason: "screen wake")
    }

    @objc private func sessionDidResignActive(_ notification: Notification) {
        isWorkspaceSessionActive = false
        prepareCaptureForAutomaticResume(reason: "session resigned active")
    }

    @objc private func sessionDidBecomeActive(_ notification: Notification) {
        isWorkspaceSessionActive = true
        scheduleCaptureRecoveryIfNeeded(reason: "session reactivated")
    }

    private func prepareCaptureForAutomaticResume(reason: String) {
        guard isCaptureRunning || shouldResumeCaptureAfterInterruption else {
            return
        }
        captureRecoveryLogger.info(
            "Observed \(reason, privacy: .public); preserving recording for automatic resume"
        )
        beginRecoverableCaptureInterruption(reason: reason)
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow {
            mainWindowState.isWindowVisible = window.isVisible
        }
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy(bringVisibleWindowToFront: true)
        }
    }

    func updateActivationPolicy(bringVisibleWindowToFront: Bool = false) {
        if enforceOnboardingWindowExclusivity() {
            return
        }

        let visibleWindows = NSApp.windows.filter { window in
            window.isVisible && window.styleMask.contains(.titled)
        }
        let hasVisibleWindows = !visibleWindows.isEmpty

        if hasVisibleWindows {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }

            guard bringVisibleWindowToFront else {
                return
            }

            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }

            if let windowToFront = NSApp.keyWindow ?? visibleWindows.first {
                windowToFront.makeKeyAndOrderFront(nil)
                windowToFront.orderFrontRegardless()
            }
        } else {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func installMainWindowOpener(_ opener: @escaping () -> Void) {
        mainWindowOpener = opener
    }

    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.identifier = NSUserInterfaceItemIdentifier("ReplayMacMainWindow")
        let delegate = SharedWindowDelegate(appDelegate: self, forwarding: window.delegate)
        mainWindowDelegate = delegate
        window.delegate = delegate
        window.isReleasedWhenClosed = false
        let restored = window.setFrameUsingName("ReplayMacMainWindow")
        let screen = NSScreen.screens.max { lhs, rhs in
            let a = window.frame.intersection(lhs.visibleFrame)
            let b = window.frame.intersection(rhs.visibleFrame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            let titleHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
            window.contentMinSize = NSSize(width: min(1040, visible.width), height: min(640, max(1, visible.height - titleHeight)))
            if !restored {
                window.setContentSize(NSSize(width: min(1120, visible.width), height: min(720, max(1, visible.height - titleHeight))))
                window.center()
            }
            window.setFrame(MainWindowGeometry.visibleFrame(window.frame, within: visible), display: true)
        }
        mainWindowState.isWindowVisible = window.isVisible
        mainWindowState.isFullScreen = window.styleMask.contains(.fullScreen)
        _ = enforceOnboardingWindowExclusivity()
    }

    /// Opens the main window, respecting the start page chosen in Settings when
    /// reopening after closure or on fresh launch, or retaining the current page
    /// when already open or minimized.
    func openMainWindow(page: MainWindowPage? = nil) {
        guard !enforceOnboardingWindowExclusivity() else { return }
        mainWindowState.willOpenWindow(page: page)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            mainWindow.deminiaturize(nil)
            mainWindow.makeKeyAndOrderFront(nil)
        } else { mainWindowOpener?() }
    }

    func openClipLibraryWindow() { openMainWindow(page: .library) }

    func toggleClipLibraryWindow() {
        let frontmost = mainWindow.map {
            $0.isVisible && NSApp.isActive && ($0.isKeyWindow || $0.isMainWindow)
        } ?? false
        if mainWindowState.routeLibraryShortcut(windowIsFrontmost: frontmost) {
            hideMainWindow()
        } else { openMainWindow(page: .library) }
    }

    func hideMainWindow() {
        mainWindowState.windowDidClose()
        mainWindow?.orderOut(nil)
        updateActivationPolicy()
    }

    func showOnboardingWindow() {
        if onboardingWindowController == nil {
            let hostingController = NSHostingController(rootView: OnboardingView { [weak self] in
                self?.completeOnboarding()
            })
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Welcome to \(AppBranding.name)"
            // Setup establishes the user-selected output location required by
            // the sandbox, so it cannot be dismissed before completion.
            window.styleMask = [.titled, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onboardingWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
            onboardingWindowController = NSWindowController(window: window)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.showWindow(nil)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
        enforceOnboardingWindowExclusivity()
    }

    private func completeOnboarding() {
        Defaults[.hasCompletedOnboarding] = true
        onboardingWindowController?.close()
        openMainWindow()
    }

    /// Cleans up the window and starts recording only after the setup assistant
    /// has explicitly completed. App termination must not complete onboarding.
    @objc private func onboardingWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == onboardingWindowController?.window else {
            return
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        onboardingWindowController = nil

        // Game auto-record keeps the app idle until a game runs, so it must not
        // begin an always-on buffer straight out of onboarding.
        if Defaults[.hasCompletedOnboarding],
           AppSettings.autoStartRecordingOnLaunch,
           !AppSettings.autoRecordGamesEnabled,
           !isCaptureRunning {
            startCapturePipeline(userInitiated: false)
        }
    }

    func openSettingsWindow() { openMainWindow(page: .general) }

    /// SwiftUI may restore Settings or Clip Library state while AppDelegate is
    /// presenting first-run setup. Keep onboarding as the only visible titled
    /// window until the user has completed the required folder selection.
    @discardableResult
    private func enforceOnboardingWindowExclusivity() -> Bool {
        guard !Defaults[.hasCompletedOnboarding],
              let onboardingWindow = onboardingWindowController?.window,
              onboardingWindow.isVisible else {
            return false
        }

        // Folder selection is part of onboarding. Once an open/save panel or
        // one of its modal sheets is active, do not reorder *any* windows.
        // Stealing key status back from the panel breaks nested UI such as its
        // New Folder sheet and leaves the modal session apparently frozen.
        let hasActivePanel = NSApp.windows.contains(where: {
            $0.isVisible && ($0 is NSSavePanel || $0.sheetParent is NSSavePanel)
        })
        if NSApp.modalWindow != nil || hasActivePanel {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            return true
        }

        for window in NSApp.windows where window != onboardingWindow {
            if window.isVisible,
               window.styleMask.contains(.titled) {
                window.orderOut(nil)
            }
        }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if NSApp.keyWindow != onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
        }
        onboardingWindow.orderFrontRegardless()
        return true
    }

}

/// Preserve SwiftUI's delegate methods while supplying menu-bar close behaviour.
@MainActor
final class SharedWindowDelegate: NSObject, NSWindowDelegate {
    weak var appDelegate: AppDelegate?
    // Assigned once; Objective-C introspection may read the delegate off actor.
    nonisolated(unsafe) weak var forwarding: (any NSWindowDelegate)?
    private var fullscreenTransition = false

    init(appDelegate: AppDelegate, forwarding: (any NSWindowDelegate)?) {
        self.appDelegate = appDelegate
        self.forwarding = forwarding
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwarding?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { forwarding }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        appDelegate?.hideMainWindow()
        return false
    }
    func windowDidBecomeKey(_ notification: Notification) {
        appDelegate?.mainWindowState.isWindowVisible = true
        forwarding?.windowDidBecomeKey?(notification)
    }
    func windowDidMiniaturize(_ notification: Notification) {
        appDelegate?.mainWindowState.windowDidHide()
        forwarding?.windowDidMiniaturize?(notification)
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        appDelegate?.mainWindowState.isWindowVisible = true
        forwarding?.windowDidDeminiaturize?(notification)
    }
    func windowDidMove(_ notification: Notification) {
        saveFrame()
        forwarding?.windowDidMove?(notification)
    }
    func windowDidResize(_ notification: Notification) {
        saveFrame()
        forwarding?.windowDidResize?(notification)
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        fullscreenTransition = true
        appDelegate?.mainWindowState.isFullScreen = true
        forwarding?.windowWillEnterFullScreen?(notification)
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        appDelegate?.mainWindowState.isFullScreen = false
        forwarding?.windowWillExitFullScreen?(notification)
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenTransition = false
        saveFrame()
        forwarding?.windowDidExitFullScreen?(notification)
    }
    private func saveFrame() {
        guard !fullscreenTransition, let window = appDelegate?.mainWindow,
              !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: "ReplayMacMainWindow")
    }
}
