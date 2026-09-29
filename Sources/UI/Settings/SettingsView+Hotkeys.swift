import SwiftUI
import Hotkeys
import KeyboardShortcuts

extension SettingsView {
    var hotkeysTab: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Save clip", name: .saveClip)
                KeyboardShortcuts.Recorder("Start/stop replay buffer", name: .toggleRecording)
                Label(
                    "The replay buffer keeps your most recent footage ready, and Save clip writes it to a file. Stopping the buffer discards anything you haven't saved. To record from start to stop instead, use session recording below.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(AppTheme.textSecondary)
                .font(.system(size: 12, design: .rounded))
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

            Section {
                KeyboardShortcuts.Recorder("Start/stop session recording", name: .toggleSessionRecording)
                Label(
                    "Records until you stop, then saves one file with screen, system audio, and mic. Separate from the instant-replay buffer.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(AppTheme.textSecondary)
                .font(.system(size: 12, design: .rounded))
            } header: {
                sectionHeader(icon: "record.circle", title: "Session Recording")
            }

            Section {
                KeyboardShortcuts.Recorder("Mute/unmute microphone", name: .toggleMicrophoneMute)
                KeyboardShortcuts.Recorder("Push-to-mute microphone (hold)", name: .pushToMuteMicrophone)
                KeyboardShortcuts.Recorder("Mute/unmute system audio", name: .toggleSystemAudioMute)
                Label(
                    "Silences audio live without restarting capture or clearing the replay buffer.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(AppTheme.textSecondary)
                .font(.system(size: 12, design: .rounded))
            } header: {
                sectionHeader(icon: "mic.slash.fill", title: "Audio")
            }

            Section {
                KeyboardShortcuts.Recorder("Copy last saved clip", name: .copyLastClip)
                KeyboardShortcuts.Recorder("Show or hide clip library", name: .openClipLibrary)
            } header: {
                sectionHeader(icon: "film.stack", title: "Library")
            }
        }
        .formStyle(.grouped)
    }
}
