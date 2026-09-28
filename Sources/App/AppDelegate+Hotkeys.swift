import Defaults
import Feedback
import Hotkeys
import UI

@MainActor
extension AppDelegate {
    func configureHotkeys() {
        hotkeyManager.onSaveClip = { [weak self] in
            self?.saveClipFromUI()
        }
        hotkeyManager.onToggleRecording = { [weak self] in
            self?.toggleCapturePipeline()
        }
        hotkeyManager.onSaveLast15Seconds = { [weak self] in
            self?.saveClip(lastSeconds: 15)
        }
        hotkeyManager.onSaveLast60Seconds = { [weak self] in
            self?.saveClip(lastSeconds: 60)
        }
        hotkeyManager.onSaveLongBuffer = { [weak self] in
            self?.saveLongBufferFromUI()
        }
        hotkeyManager.onToggleSessionRecording = { [weak self] in
            self?.toggleSessionRecording()
        }
        hotkeyManager.onOpenClipLibrary = { [weak self] in
            self?.toggleClipLibraryWindow()
        }
        hotkeyManager.onToggleMicrophoneMute = { [weak self] in
            self?.toggleMicrophoneMuteFromUI()
        }
        hotkeyManager.onPushToMuteMicrophoneChanged = { [weak self] isPressed in
            self?.setPushToMuteMicrophone(isPressed)
        }
        hotkeyManager.onToggleSystemAudioMute = { [weak self] in
            self?.toggleSystemAudioMuteFromUI()
        }
        hotkeyManager.onCopyLastClip = { [weak self] in
            self?.copyLastClipFromUI()
        }
        hotkeyManager.start()
    }

    func toggleMicrophoneMuteFromUI() {
        isPushToMuteActive = false
        if !AppSettings.captureMicrophone {
            Defaults[.captureMicrophone] = true
            Defaults[.isMicrophoneMuted] = false
        } else {
            Defaults[.isMicrophoneMuted].toggle()
        }

        applyEffectiveAudioVolumes()
        syncAudioMuteStateToUI()

        if AppSettings.playAudioCueOnSave {
            if AppSettings.isMicrophoneMuted {
                AudioCue.playMute()
            } else {
                AudioCue.playUnmute()
            }
        }
    }

    func setPushToMuteMicrophone(_ isPressed: Bool) {
        guard isPushToMuteActive != isPressed else { return }

        if isPressed && !AppSettings.captureMicrophone {
            Defaults[.captureMicrophone] = true
            Defaults[.isMicrophoneMuted] = false
        }

        let wasEffectivelyMuted = AppSettings.isMicrophoneMuted || isPushToMuteActive
        isPushToMuteActive = isPressed
        let isNowEffectivelyMuted = AppSettings.isMicrophoneMuted || isPushToMuteActive

        applyEffectiveAudioVolumes()
        syncAudioMuteStateToUI()

        if wasEffectivelyMuted != isNowEffectivelyMuted, AppSettings.playAudioCueOnSave {
            if isNowEffectivelyMuted {
                AudioCue.playMute()
            } else {
                AudioCue.playUnmute()
            }
        }
    }

    func toggleSystemAudioMuteFromUI() {
        if !AppSettings.captureSystemAudio {
            Defaults[.captureSystemAudio] = true
            Defaults[.isSystemAudioMuted] = false
        } else {
            Defaults[.isSystemAudioMuted].toggle()
        }

        applyEffectiveAudioVolumes()
        syncAudioMuteStateToUI()

        if AppSettings.playAudioCueOnSave {
            if AppSettings.isSystemAudioMuted {
                AudioCue.playMute()
            } else {
                AudioCue.playUnmute()
            }
        }
    }

    func copyLastClipFromUI() {
        if let copiedURL = statusItemController.copyLastClipToPasteboard() {
            if AppSettings.playAudioCueOnSave {
                AudioCue.playSaveSuccess()
            }
            if AppSettings.showNotificationOnSave {
                NotificationManager.shared.showOperationalNotification(
                    title: "Clip Copied to Clipboard",
                    body: "\(copiedURL.lastPathComponent) is ready to paste."
                )
            }
        } else {
            NotificationManager.shared.showOperationalNotification(
                title: "No Saved Clip Found",
                body: "Save a clip first before copying to the clipboard."
            )
        }
    }
}
