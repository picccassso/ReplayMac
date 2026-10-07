import Branding
import SwiftUI
import UI

@main
struct ReplayCapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let _ = appDelegate.installMainWindowOpener { openWindow(id: "main") }
        Window(AppBranding.name, id: "main") {
            MainWindowView(state: appDelegate.mainWindowState, menuBar: appDelegate.menuBarState)
                .background(MainWindowRegistration(appDelegate: appDelegate))
        }
        .defaultSize(width: 1120, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.openSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Registers the scene's actual window, so menu/hotkey routing never guesses
/// amongst trim previews, save panels or onboarding windows.
private struct MainWindowRegistration: NSViewRepresentable {
    let appDelegate: AppDelegate
    func makeNSView(context: Context) -> WindowRegistrationView {
        let view = WindowRegistrationView()
        view.register = { appDelegate.registerMainWindow($0) }
        return view
    }
    func updateNSView(_ view: WindowRegistrationView, context: Context) {}
}

private final class WindowRegistrationView: NSView {
    var register: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { register?(window) }
    }
}
