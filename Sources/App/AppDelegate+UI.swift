import Branding
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

    func openClipLibraryWindow() {
        if enforceOnboardingWindowExclusivity() {
            return
        }

        if clipLibraryWindowController == nil {
            let hostingController = NSHostingController(rootView: ClipLibraryView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Clip Library"
            window.setContentSize(NSSize(width: 980, height: 620))
            window.styleMask = NSWindow.StyleMask([.titled, .closable, .miniaturizable, .resizable])
            clipLibraryWindowController = NSWindowController(window: window)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        clipLibraryWindowController?.showWindow(nil)
        clipLibraryWindowController?.window?.makeKeyAndOrderFront(nil)
        clipLibraryWindowController?.window?.orderFrontRegardless()
        updateActivationPolicy(bringVisibleWindowToFront: true)
    }

    /// Hotkey behaviour: a second press dismisses the library. The window is
    /// only closed when it is already frontmost, so pressing the hotkey from
    /// another app still brings it forward instead of hiding it.
    func toggleClipLibraryWindow() {
        if let window = clipLibraryWindowController?.window,
           window.isVisible,
           NSApp.isActive,
           window.isKeyWindow || window.isMainWindow {
            window.close()
            updateActivationPolicy()
            return
        }

        openClipLibraryWindow()
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

    func openSettingsWindow() {
        if enforceOnboardingWindowExclusivity() {
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NotificationCenter.default.post(name: .replayCapSettingsShouldOpenGeneral, object: nil)

        bringSettingsWindowToFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            NotificationCenter.default.post(name: .replayCapSettingsShouldOpenGeneral, object: nil)
            self?.bringSettingsWindowToFront()
        }
    }

    func bringSettingsWindowToFront() {
        guard let settingsWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.titled)
                && $0 != clipLibraryWindowController?.window
                && $0 != onboardingWindowController?.window
        }) else {
            return
        }
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
    }

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
