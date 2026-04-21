import Cocoa
import Capture
import Encode
import RingBuffer
import Audio
import Save
import UI
import Hotkeys
import Feedback
import Update
import AVFoundation
import Darwin.Mach
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    let captureManager = CaptureManager()
    let videoEncoder = VideoEncoder()
    let videoRingBuffer = VideoRingBuffer()

    let systemAudioCapture = SystemAudioCapture()
    let micAudioCapture = MicCapture()
    let systemAudioEncoder = AudioEncoder()
    let micAudioEncoder = AudioEncoder()
    let systemAudioRingBuffer = AudioRingBuffer()
    let micAudioRingBuffer = AudioRingBuffer()

    lazy var clipSaver = ClipSaver(
        videoRingBuffer: videoRingBuffer,
        systemAudioRingBuffer: systemAudioRingBuffer,
        micRingBuffer: micAudioRingBuffer
    )

    let menuBarState = MenuBarState()
    let statusItemController = StatusItemController()
    let hotkeyManager = HotkeyManager()
    let sparkleController = SparkleController()

    var isCaptureRunning = false
    var monitoringTask: Task<Void, Never>?
    var clipLibraryWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestAuthorization()

        configurePipelines()

        statusItemController.onSaveClip = { [weak self] in
            self?.saveClipFromUI()
        }
        statusItemController.onOpenClipLibrary = { [weak self] in
            self?.openClipLibraryWindow()
        }
        statusItemController.onOpenSettings = { [weak self] in
            self?.openSettingsWindow()
        }
        statusItemController.setup(state: menuBarState)
        configureHotkeys()
        Task {
            await captureManager.activateDelegateCallbacks()
            await captureManager.setInterruptionHandler { [weak self] interruption in
                Task { @MainActor in
                    self?.handleCaptureInterruption(interruption)
                }
            }
        }

        sparkleController.start(appcastURLString: AppSettings.sparkleAppcastURLString)

        if AppSettings.autoStartRecordingOnLaunch {
            startCapturePipeline(userInitiated: false)
        }

        NSApp.setActivationPolicy(.accessory)
        setupWindowObservers()
    }

    private func setupWindowObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowVisibilityChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateActivationPolicy()
        }
    }

    private func updateActivationPolicy() {
        let hasVisibleWindows = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled)
        }

        if hasVisibleWindows {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        } else {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func configurePipelines() {
        videoEncoder.outputHandler = { [videoRingBuffer] sampleBuffer in
            videoRingBuffer.append(encodedSample: sampleBuffer)
        }

        systemAudioEncoder.outputHandler = { [systemAudioRingBuffer] sampleBuffer in
            systemAudioRingBuffer.append(sampleBuffer)
        }
        systemAudioCapture.setHandler { [systemAudioEncoder] sampleBuffer in
            systemAudioEncoder.encode(sampleBuffer: sampleBuffer)
        }

        micAudioEncoder.outputHandler = { [micAudioRingBuffer] sampleBuffer in
            micAudioRingBuffer.append(sampleBuffer)
        }
        micAudioCapture.setHandler { [micAudioEncoder] sampleBuffer in
            micAudioEncoder.encode(sampleBuffer: sampleBuffer)
        }
    }

    private func startCapturePipeline(userInitiated: Bool = true) {
        guard !isCaptureRunning else {
            return
        }

        Task {
            do {
                let shouldCaptureMic = AppSettings.captureMicrophone
                let micPermissionGranted = shouldCaptureMic ? await requestMicrophonePermissionIfNeeded() : false
                if shouldCaptureMic && !micPermissionGranted {
                    print("Warning: Microphone permission denied; mic track will be unavailable.")
                }

                await captureManager.setVideoHandler { [videoEncoder] sampleBuffer in
                    videoEncoder.encode(sampleBuffer: sampleBuffer)
                }
                await captureManager.setAudioHandler { [systemAudioCapture] sampleBuffer in
                    if AppSettings.captureSystemAudio {
                        systemAudioCapture.process(sampleBuffer: sampleBuffer)
                    }
                }

                let config = try await captureManager.start(
                    interactivePermissionPrompt: userInitiated,
                    fps: AppSettings.frameRate,
                    queueDepth: AppSettings.queueDepth
                )
                try videoEncoder.start(width: config.width, height: config.height, fps: config.fps)

                if shouldCaptureMic && micPermissionGranted {
                    do {
                        try micAudioCapture.start()
                    } catch {
                        print("Warning: Failed to start mic capture: \(error)")
                    }
                }

                isCaptureRunning = true
                menuBarState.setRecording(true)
                startMonitoring()
            } catch {
                isCaptureRunning = false
                menuBarState.setRecording(false)
                print("Failed to start capture: \(error)")
            }
        }
    }

    private func stopCapturePipeline() {
        guard isCaptureRunning else {
            return
        }

        monitoringTask?.cancel()
        monitoringTask = nil

        captureManager.stop()
        micAudioCapture.stop()
        videoEncoder.stop()
        systemAudioEncoder.stop()
        micAudioEncoder.stop()

        isCaptureRunning = false
        menuBarState.setRecording(false)
        menuBarState.setBufferedSeconds(0)
    }

    private func toggleCapturePipeline() {
        if isCaptureRunning {
            stopCapturePipeline()
        } else {
            startCapturePipeline(userInitiated: true)
        }
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitoringTask?.cancel()
        stopCapturePipeline()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func saveClipFromUI() {
        saveClip(lastSeconds: TimeInterval(AppSettings.bufferDurationSeconds))
    }

    private func configureHotkeys() {
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
        hotkeyManager.start()
    }

    private func saveClip(lastSeconds: TimeInterval) {
        Task {
            await saveConfiguredClip(lastSeconds: lastSeconds)
        }
    }

    private func openSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.bringSettingsWindowToFront()
        }
    }

    private func bringSettingsWindowToFront() {
        guard let settingsWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.titled) && $0 != clipLibraryWindowController?.window
        }) else {
            return
        }
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    private func saveConfiguredClip(lastSeconds: TimeInterval) async {
        do {
            let savedURL = try await clipSaver.saveClip(
                lastSeconds: lastSeconds,
                outputDirectory: AppSettings.outputDirectoryURL
            )
            let finalURL = try await WatermarkCompositor.applyIfEnabled(
                to: savedURL,
                enabled: AppSettings.watermarkSavedClips
            )

            menuBarState.flashSavedState()

            if AppSettings.playAudioCueOnSave {
                AudioCue.playSaveSuccess()
            }

            if AppSettings.showNotificationOnSave {
                NotificationManager.shared.showClipSavedNotification(fileURL: finalURL, clipDuration: lastSeconds)
            }
            print("Clip saved: \(finalURL.path)")
        } catch {
            if AppSettings.showNotificationOnSave {
                NotificationManager.shared.showSaveFailedNotification(error: error.localizedDescription)
            }
            print("Failed to save clip: \(error)")
        }
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task {
            var tick = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }

                tick += 1
                let videoDuration = self.videoRingBuffer.duration
                self.menuBarState.setBufferedSeconds(videoDuration)

                guard tick % 5 == 0 else {
                    continue
                }

                let videoMemory = self.videoRingBuffer.currentMemoryBytes
                let videoKeyframes = self.videoRingBuffer.keyframeCount
                let videoSamples = self.videoRingBuffer.totalSampleCount
                let systemAudioDuration = self.systemAudioRingBuffer.duration
                let audioMemory = self.systemAudioRingBuffer.currentMemoryBytes
                let audioSamples = self.systemAudioRingBuffer.totalSampleCount
                let micDuration = self.micAudioRingBuffer.duration
                let micMemory = self.micAudioRingBuffer.currentMemoryBytes
                let micSamples = self.micAudioRingBuffer.totalSampleCount
                print("RingBuffer | Video: \(String(format: "%.1f", videoDuration))s \(videoMemory / (1024 * 1024))MB keyframes=\(videoKeyframes) samples=\(videoSamples) | SystemAudio: \(audioSamples) samples \(audioMemory / 1024)KB \(String(format: "%.1f", systemAudioDuration))s | Mic: \(micSamples) samples \(String(format: "%.1f", micDuration))s")

                let totalRingMemory = videoMemory + audioMemory + micMemory
                self.menuBarState.setBufferMemoryBytes(totalRingMemory)
                self.enforceMemoryBudgets(
                    totalRingMemory: totalRingMemory,
                    systemAudioMemory: audioMemory,
                    micAudioMemory: micMemory
                )

                let stats = self.captureManager.captureStats()
                let now = Date()
                let audioAge = stats.lastAudioSampleDate.map { String(format: "%.1fs ago", now.timeIntervalSince($0)) } ?? "never"
                print("SCKCallbacks | Audio: total=\(stats.audioSampleCount) invalid=\(stats.invalidAudioSampleCount) last=\(audioAge)")
            }
        }
    }

    private func handleCaptureInterruption(_ interruption: CaptureInterruption) {
        switch interruption {
        case .restartedAfterGPUPressure:
            menuBarState.showNotice("Recording resumed")
            menuBarState.setRecording(true)
        case .gpuPressurePaused:
            menuBarState.showNotice("Recording paused - GPU pressure")
            stopCapturePipeline()
        case .permissionRevoked:
            menuBarState.showNotice("Recording stopped - permission revoked")
            stopCapturePipeline()
        case .displayDisconnected:
            menuBarState.showNotice("Recording stopped - display disconnected")
            stopCapturePipeline()
        case .stopped(let reason):
            menuBarState.showNotice("Recording stopped")
            print("Capture stopped: \(reason)")
            stopCapturePipeline()
        }
    }

    private func openClipLibraryWindow() {
        if clipLibraryWindowController == nil {
            let hostingController = NSHostingController(rootView: ClipLibraryView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Clip Library"
            window.setContentSize(NSSize(width: 980, height: 620))
            window.styleMask = NSWindow.StyleMask([.titled, .closable, .miniaturizable, .resizable])
            clipLibraryWindowController = NSWindowController(window: window)
        }

        clipLibraryWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateActivationPolicy()
    }

    private func enforceMemoryBudgets(
        totalRingMemory: Int,
        systemAudioMemory: Int,
        micAudioMemory: Int
    ) {
        let capBytes = Int(AppSettings.memoryCapMB * 1024 * 1024)
        if totalRingMemory > capBytes {
            let targetVideoBytes = max(0, capBytes - systemAudioMemory - micAudioMemory)
            let evictedVideo = videoRingBuffer.evictToMemory(maxBytes: targetVideoBytes)

            var remainingBudget = max(0, capBytes - videoRingBuffer.currentMemoryBytes)
            let targetSystemBytes = remainingBudget / 2
            let evictedSystem = systemAudioRingBuffer.evictToMemory(maxBytes: targetSystemBytes)
            remainingBudget = max(0, remainingBudget - systemAudioRingBuffer.currentMemoryBytes)
            let evictedMic = micAudioRingBuffer.evictToMemory(maxBytes: remainingBudget)

            print("Memory cap exceeded. Evicted video=\(evictedVideo)B systemAudio=\(evictedSystem)B mic=\(evictedMic)B")
        }

        if let availableMemory = Self.estimatedAvailableMemoryBytes(),
           availableMemory < 512 * 1024 * 1024 {
            let reducedSeconds = max(10, AppSettings.bufferDurationSeconds / 2)
            let evictedVideo = videoRingBuffer.trimToDuration(maxSeconds: TimeInterval(reducedSeconds))
            let evictedSystem = systemAudioRingBuffer.trimToDuration(maxSeconds: TimeInterval(reducedSeconds))
            let evictedMic = micAudioRingBuffer.trimToDuration(maxSeconds: TimeInterval(reducedSeconds))
            print("Critical memory pressure (\(availableMemory / (1024 * 1024))MB avail). Shrunk buffers to \(reducedSeconds)s; evicted video=\(evictedVideo)B systemAudio=\(evictedSystem)B mic=\(evictedMic)B")
        }
    }

    private static func estimatedAvailableMemoryBytes() -> UInt64? {
        let physical = ProcessInfo.processInfo.physicalMemory

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        let used = UInt64(info.resident_size)
        return physical > used ? physical - used : 0
    }
}
