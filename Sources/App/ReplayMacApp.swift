import SwiftUI
import UI

@main
struct ReplayMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }

        Window("Clip Library", id: "library") {
            ClipLibraryView()
        }
    }
}
