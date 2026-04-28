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
import Defaults

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    let captureManager = CaptureManager()
    let frameCompositor = FrameCompositor()
    let videoEncoder = VideoEncoder()
    let videoRingBuffer = VideoRingBuffer(timeCap: TimeInterval(AppSettings.bufferDurationSeconds))
    let dualDisplay1VideoEncoder = VideoEncoder()
    let dualDisplay2VideoEncoder = VideoEncoder()
    let dualDisplay1VideoRingBuffer = VideoRingBuffer(timeCap: TimeInterval(AppSettings.bufferDurationSeconds))
    let dualDisplay2VideoRingBuffer = VideoRingBuffer(timeCap: TimeInterval(AppSettings.bufferDurationSeconds))

    let systemAudioCapture = SystemAudioCapture()
    let micAudioCapture = MicCapture()
    let systemAudioEncoder = AudioEncoder()
    let micAudioEncoder = AudioEncoder()
    let systemAudioRingBuffer = AudioRingBuffer(timeCap: TimeInterval(AppSettings.bufferDurationSeconds))
    let micAudioRingBuffer = AudioRingBuffer(timeCap: TimeInterval(AppSettings.bufferDurationSeconds))

    lazy var clipSaver = ClipSaver(
        videoRingBuffer: videoRingBuffer,
        dualDisplay1VideoRingBuffer: dualDisplay1VideoRingBuffer,
        dualDisplay2VideoRingBuffer: dualDisplay2VideoRingBuffer,
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
    private var bufferDurationObservation: Defaults.Observation?

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

        setupWindowObservers()

        bufferDurationObservation = Defaults.observe(.bufferDurationSeconds) { [weak self] _ in
            self?.syncBufferDurationToSettings()
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy(bringVisibleWindowToFront: true)
        }
    }

    private func setupWindowObservers() {
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

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy(bringVisibleWindowToFront: true)
        }
    }

    private func updateActivationPolicy(bringVisibleWindowToFront: Bool = false) {
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

    private func configurePipelines() {
        videoEncoder.outputHandler = { [videoRingBuffer] sampleBuffer in
            videoRingBuffer.append(encodedSample: sampleBuffer)
        }
        dualDisplay1VideoEncoder.outputHandler = { [dualDisplay1VideoRingBuffer] sampleBuffer in
            dualDisplay1VideoRingBuffer.append(encodedSample: sampleBuffer)
        }
        dualDisplay2VideoEncoder.outputHandler = { [dualDisplay2VideoRingBuffer] sampleBuffer in
            dualDisplay2VideoRingBuffer.append(encodedSample: sampleBuffer)
        }

        frameCompositor.outputHandler = { [videoEncoder] sampleBuffer in
            videoEncoder.encode(sampleBuffer: sampleBuffer)
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
                videoRingBuffer.clear()
                dualDisplay1VideoRingBuffer.clear()
                dualDisplay2VideoRingBuffer.clear()
                systemAudioRingBuffer.clear()
                micAudioRingBuffer.clear()

                let shouldCaptureMic = AppSettings.captureMicrophone
                let micPermissionGranted = shouldCaptureMic ? await requestMicrophonePermissionIfNeeded() : false
                if shouldCaptureMic && !micPermissionGranted {
                    print("Warning: Microphone permission denied; mic track will be unavailable.")
                }

                let isDual = AppSettings.captureMode == CaptureMode.dualSideBySide.rawValue

                if isDual {
                    await captureManager.setVideoHandler1 { [frameCompositor, dualDisplay1VideoEncoder] sampleBuffer in
                        frameCompositor.pushPrimaryFrame(sampleBuffer)
                        dualDisplay1VideoEncoder.encode(sampleBuffer: sampleBuffer)
                    }
                    await captureManager.setVideoHandler2 { [frameCompositor, dualDisplay2VideoEncoder] sampleBuffer in
                        frameCompositor.pushSecondaryFrame(sampleBuffer)
                        dualDisplay2VideoEncoder.encode(sampleBuffer: sampleBuffer)
                    }
                    await captureManager.setAudioHandler1 { [systemAudioCapture] sampleBuffer in
                        if AppSettings.captureSystemAudio {
                            systemAudioCapture.process(sampleBuffer: sampleBuffer)
                        }
                    }

                    let dualConfigs = try await captureManager.startDual(
                        interactivePermissionPrompt: userInitiated,
                        captureDisplayID1: AppSettings.captureDisplayID.isEmpty ? nil : AppSettings.captureDisplayID,
                        captureDisplayID2: AppSettings.captureDisplayID2.isEmpty ? nil : AppSettings.captureDisplayID2,
                        fps: AppSettings.frameRate,
                        queueDepth: AppSettings.queueDepth
                    )

                    let compositeWidth = dualConfigs.config1.width + dualConfigs.config2.width
                    let compositeHeight = max(dualConfigs.config1.height, dualConfigs.config2.height)

                    frameCompositor.configure(
                        display1Width: dualConfigs.config1.width,
                        display1Height: dualConfigs.config1.height,
                        display2Width: dualConfigs.config2.width,
                        display2Height: dualConfigs.config2.height
                    )

                    try videoEncoder.start(
                        width: compositeWidth,
                        height: compositeHeight,
                        fps: dualConfigs.config1.fps
                    )
                    try dualDisplay1VideoEncoder.start(
                        width: dualConfigs.config1.width,
                        height: dualConfigs.config1.height,
                        fps: dualConfigs.config1.fps
                    )
                    try dualDisplay2VideoEncoder.start(
                        width: dualConfigs.config2.width,
                        height: dualConfigs.config2.height,
                        fps: dualConfigs.config2.fps
                    )

                    print("Dual capture started: Display1=\(dualConfigs.config1.width)x\(dualConfigs.config1.height), Display2=\(dualConfigs.config2.width)x\(dualConfigs.config2.height), Composite=\(compositeWidth)x\(compositeHeight)")
                } else {
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
                        captureDisplayID: AppSettings.captureDisplayID.isEmpty ? nil : AppSettings.captureDisplayID,
                        fps: AppSettings.frameRate,
                        queueDepth: AppSettings.queueDepth
                    )
                    try videoEncoder.start(width: config.width, height: config.height, fps: config.fps)
                }

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
        dualDisplay1VideoEncoder.stop()
        dualDisplay2VideoEncoder.stop()
        systemAudioEncoder.stop()
        micAudioEncoder.stop()
        frameCompositor.reset()

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

        bringSettingsWindowToFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
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
        settingsWindow.orderFrontRegardless()
    }

    private func saveConfiguredClip(lastSeconds: TimeInterval) async {
        menuBarState.flashSavedState()

        do {
            let isSeparateDualSave = AppSettings.captureMode == CaptureMode.dualSideBySide.rawValue
                && AppSettings.dualCaptureSaveMode == DualCaptureSaveMode.separateFiles.rawValue
            let outputDirectory = AppSettings.outputDirectoryURL
            print("Saving clip to output directory: \(outputDirectory.path(percentEncoded: false))")

            let finalURLs: [URL]
            if isSeparateDualSave {
                let savedURLs = try await clipSaver.saveDualDisplayClips(
                    lastSeconds: lastSeconds,
                    outputDirectory: outputDirectory
                )
                var watermarkedURLs: [URL] = []
                for url in savedURLs {
                    let finalURL = try await WatermarkCompositor.applyIfEnabled(
                        to: url,
                        enabled: AppSettings.watermarkSavedClips
                    )
                    watermarkedURLs.append(finalURL)
                }
                finalURLs = watermarkedURLs
            } else {
                let savedURL = try await clipSaver.saveClip(
                    lastSeconds: lastSeconds,
                    outputDirectory: outputDirectory
                )
                let finalURL = try await WatermarkCompositor.applyIfEnabled(
                    to: savedURL,
                    enabled: AppSettings.watermarkSavedClips
                )
                finalURLs = [finalURL]
            }

            if AppSettings.playAudioCueOnSave {
                AudioCue.playSaveSuccess()
            }

            if AppSettings.showNotificationOnSave {
                NotificationManager.shared.showClipSavedNotification(fileURL: finalURLs[0], clipDuration: lastSeconds)
            }
            print("Clip saved: \(finalURLs.map(\.path).joined(separator: ", "))")
        } catch {
            if AppSettings.showNotificationOnSave {
                NotificationManager.shared.showSaveFailedNotification(error: error.localizedDescription)
            }
            print("Failed to save clip: \(error)")
        }
    }

    private func syncBufferDurationToSettings() {
        let duration = TimeInterval(AppSettings.bufferDurationSeconds)
        videoRingBuffer.timeCap = duration
        dualDisplay1VideoRingBuffer.timeCap = duration
        dualDisplay2VideoRingBuffer.timeCap = duration
        systemAudioRingBuffer.timeCap = duration
        micAudioRingBuffer.timeCap = duration

        guard isCaptureRunning else { return }
        videoRingBuffer.trimToDuration(maxSeconds: duration)
        dualDisplay1VideoRingBuffer.trimToDuration(maxSeconds: duration)
        dualDisplay2VideoRingBuffer.trimToDuration(maxSeconds: duration)
        systemAudioRingBuffer.trimToDuration(maxSeconds: duration)
        micAudioRingBuffer.trimToDuration(maxSeconds: duration)
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

                self.systemAudioCapture.setVolume(AppSettings.systemAudioVolume)
                self.micAudioCapture.setVolume(AppSettings.microphoneVolume)

                let videoDuration = self.videoRingBuffer.duration
                self.menuBarState.setBufferedSeconds(videoDuration)

                guard tick % 5 == 0 else {
                    continue
                }

                let videoMemory = self.videoRingBuffer.currentMemoryBytes
                let dualDisplay1Memory = self.dualDisplay1VideoRingBuffer.currentMemoryBytes
                let dualDisplay2Memory = self.dualDisplay2VideoRingBuffer.currentMemoryBytes
                let videoKeyframes = self.videoRingBuffer.keyframeCount
                let videoSamples = self.videoRingBuffer.totalSampleCount
                let systemAudioDuration = self.systemAudioRingBuffer.duration
                let audioMemory = self.systemAudioRingBuffer.currentMemoryBytes
                let audioSamples = self.systemAudioRingBuffer.totalSampleCount
                let micDuration = self.micAudioRingBuffer.duration
                let micMemory = self.micAudioRingBuffer.currentMemoryBytes
                let micSamples = self.micAudioRingBuffer.totalSampleCount
                print("RingBuffer | Video: \(String(format: "%.1f", videoDuration))s \(videoMemory / (1024 * 1024))MB keyframes=\(videoKeyframes) samples=\(videoSamples) | SystemAudio: \(audioSamples) samples \(audioMemory / 1024)KB \(String(format: "%.1f", systemAudioDuration))s | Mic: \(micSamples) samples \(String(format: "%.1f", micDuration))s")

                let totalRingMemory = videoMemory + dualDisplay1Memory + dualDisplay2Memory + audioMemory + micMemory
                self.menuBarState.setBufferMemoryBytes(totalRingMemory)
                self.enforceMemoryBudgets(
                    totalRingMemory: totalRingMemory,
                    dualDisplay1Memory: dualDisplay1Memory,
                    dualDisplay2Memory: dualDisplay2Memory,
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
            menuBarState.setRecording(true)
        case .gpuPressurePaused:
            stopCapturePipeline()
        case .permissionRevoked:
            stopCapturePipeline()
        case .displayDisconnected:
            stopCapturePipeline()
        case .stopped(let reason):
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

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        clipLibraryWindowController?.showWindow(nil)
        clipLibraryWindowController?.window?.makeKeyAndOrderFront(nil)
        clipLibraryWindowController?.window?.orderFrontRegardless()
        updateActivationPolicy(bringVisibleWindowToFront: true)
    }

    private func enforceMemoryBudgets(
        totalRingMemory: Int,
        dualDisplay1Memory: Int,
        dualDisplay2Memory: Int,
        systemAudioMemory: Int,
        micAudioMemory: Int
    ) {
        let capBytes = Int(AppSettings.memoryCapMB * 1024 * 1024)
        if totalRingMemory > capBytes {
            let targetVideoBytes = max(0, capBytes - dualDisplay1Memory - dualDisplay2Memory - systemAudioMemory - micAudioMemory)
            let evictedVideo = videoRingBuffer.evictToMemory(maxBytes: targetVideoBytes)
            var remainingBudget = max(0, capBytes - videoRingBuffer.currentMemoryBytes - systemAudioMemory - micAudioMemory)
            let evictedDisplay1 = dualDisplay1VideoRingBuffer.evictToMemory(maxBytes: remainingBudget / 2)
            remainingBudget = max(0, remainingBudget - dualDisplay1VideoRingBuffer.currentMemoryBytes)
            let evictedDisplay2 = dualDisplay2VideoRingBuffer.evictToMemory(maxBytes: remainingBudget)

            remainingBudget = max(0, capBytes - videoRingBuffer.currentMemoryBytes - dualDisplay1VideoRingBuffer.currentMemoryBytes - dualDisplay2VideoRingBuffer.currentMemoryBytes)
            let targetSystemBytes = remainingBudget / 2
            let evictedSystem = systemAudioRingBuffer.evictToMemory(maxBytes: targetSystemBytes)
            remainingBudget = max(0, remainingBudget - systemAudioRingBuffer.currentMemoryBytes)
            let evictedMic = micAudioRingBuffer.evictToMemory(maxBytes: remainingBudget)

            print("Memory cap exceeded. Evicted video=\(evictedVideo)B display1=\(evictedDisplay1)B display2=\(evictedDisplay2)B systemAudio=\(evictedSystem)B mic=\(evictedMic)B")
        }

        if let availableMemory = Self.estimatedAvailableMemoryBytes(),
           availableMemory < 512 * 1024 * 1024 {
            let reducedSeconds = max(10, AppSettings.bufferDurationSeconds / 2)
            let evictedVideo = videoRingBuffer.trimToDuration(maxSeconds: TimeInterval(reducedSeconds))
            let evictedDisplay1 = dualDisplay1VideoRingBuffer.trimToDuration(maxSeconds: TimeInterval(reducedSeconds))
            let evictedDisplay2 = dualDisplay2VideoRingBuffer.trimToDuration(maxSeconds: TimeInterval(reducedSeconds))
            let evictedSystem = systemAudioRingBuffer.trimToDuration(maxSeconds: TimeInterval(reducedSeconds))
            let evictedMic = micAudioRingBuffer.trimToDuration(maxSeconds: TimeInterval(reducedSeconds))
            print("Critical memory pressure (\(availableMemory / (1024 * 1024))MB avail). Shrunk buffers to \(reducedSeconds)s; evicted video=\(evictedVideo)B display1=\(evictedDisplay1)B display2=\(evictedDisplay2)B systemAudio=\(evictedSystem)B mic=\(evictedMic)B")
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
