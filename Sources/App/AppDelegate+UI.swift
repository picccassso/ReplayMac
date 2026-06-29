import Cocoa
import SwiftUI
import UI

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
        rememberCaptureForAutomaticResume()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        areScreensAwake = true
        scheduleCaptureRecoveryIfNeeded(reason: "system wake")
    }

    @objc private func screensDidSleep(_ notification: Notification) {
        areScreensAwake = false
        rememberCaptureForAutomaticResume()
    }

    @objc private func screensDidWake(_ notification: Notification) {
        areScreensAwake = true
        scheduleCaptureRecoveryIfNeeded(reason: "screen wake")
    }

    @objc private func sessionDidResignActive(_ notification: Notification) {
        isWorkspaceSessionActive = false
        rememberCaptureForAutomaticResume()
    }

    @objc private func sessionDidBecomeActive(_ notification: Notification) {
        isWorkspaceSessionActive = true
        scheduleCaptureRecoveryIfNeeded(reason: "session reactivated")
    }

    private func rememberCaptureForAutomaticResume() {
        if isCaptureRunning {
            shouldResumeCaptureAfterInterruption = true
        }
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy(bringVisibleWindowToFront: true)
        }
    }

    func updateActivationPolicy(bringVisibleWindowToFront: Bool = false) {
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

    func openSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NotificationCenter.default.post(name: .replayMacSettingsShouldOpenGeneral, object: nil)

        bringSettingsWindowToFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            NotificationCenter.default.post(name: .replayMacSettingsShouldOpenGeneral, object: nil)
            self?.bringSettingsWindowToFront()
        }
    }

    func bringSettingsWindowToFront() {
        guard let settingsWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.titled) && $0 != clipLibraryWindowController?.window
        }) else {
            return
        }
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
    }

}
