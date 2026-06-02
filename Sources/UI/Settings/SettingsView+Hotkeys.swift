import SwiftUI
import Hotkeys
import KeyboardShortcuts

extension SettingsView {
    var hotkeysTab: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Save clip", name: .saveClip)
                KeyboardShortcuts.Recorder("Start/stop recording", name: .toggleRecording)
            } header: {
                sectionHeader(icon: "bolt.fill", title: "Primary")
            }

            Section {
                KeyboardShortcuts.Recorder("Save last 15 seconds", name: .saveLast15Seconds)
                KeyboardShortcuts.Recorder("Save last 60 seconds", name: .saveLast60Seconds)
                KeyboardShortcuts.Recorder("Save extended replay", name: .saveLongBuffer)
            } header: {
                sectionHeader(icon: "stopwatch", title: "Quick Presets")
            }
        }
        .formStyle(.grouped)
    }
}
