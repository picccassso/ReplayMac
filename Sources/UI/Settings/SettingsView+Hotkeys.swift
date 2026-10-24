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
                Text("Primary")
            }

            if AppSettings.isFeatureEnabled(.quickSaveAndThumbnail) || AppSettings.isFeatureEnabled(.extendedReplay) {
                Section {
                    if AppSettings.isFeatureEnabled(.quickSaveAndThumbnail) {
                        KeyboardShortcuts.Recorder("Save last 15 seconds", name: .saveLast15Seconds)
                        KeyboardShortcuts.Recorder("Save last 60 seconds", name: .saveLast60Seconds)
                    }
                    if AppSettings.isFeatureEnabled(.extendedReplay) {
                        KeyboardShortcuts.Recorder("Save extended replay", name: .saveLongBuffer)
                        Label(
                            "Save extended replay saves the last 5, 10, or 30 minutes from a separate, longer buffer kept on disk. Turn on Extended replay buffer in Settings → Video.",
                            systemImage: "info.circle"
                        )
                        .foregroundStyle(AppTheme.textSecondary)
                        .font(.system(size: 12, design: .rounded))
                    }
                } header: {
                    Text("Quick Presets")
                }
            }

            if AppSettings.isFeatureEnabled(.sessionRecording) {
                Section {
                    KeyboardShortcuts.Recorder("Start/stop session recording", name: .toggleSessionRecording)
                    Label(
                        "Records until you stop, then saves one file with screen, system audio, and mic. Separate from the instant-replay buffer.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
                } header: {
                    Text("Session Recording")
                }
            }

            if AppSettings.isFeatureEnabled(.audioMixing) {
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
                    Text("Audio")
                }
            }

            Section {
                KeyboardShortcuts.Recorder("Copy last saved clip", name: .copyLastClip)
                KeyboardShortcuts.Recorder("Show or hide clip library", name: .openClipLibrary)
                if AppSettings.isFeatureEnabled(.quickSaveAndThumbnail) {
                    KeyboardShortcuts.Recorder("Edit last clip", name: .editLastClip)
                    Label(
                        "Edit last clip shows a thumbnail of your most recent clip with Trim, Copy, and Show in Finder. It won't take focus from your game. To show it after every replay save, turn it on in Settings → General.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.system(size: 12, design: .rounded))
                }
            } header: {
                Text("Library")
            }
        }
        .formStyle(.grouped)
    }
}
