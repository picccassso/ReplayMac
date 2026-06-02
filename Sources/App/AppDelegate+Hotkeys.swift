import Hotkeys

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
        hotkeyManager.start()
    }

}
