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
    private var settingsObservations: [Defaults.Observation] = []
    private var settingsReconcileTask: Task<Void, Never>?
    private var pendingRuntimeSettingsReconcile = false
    private var pendingRuntimeFullRestart = false

    // Current capture dimensions for runtime reconfiguration
    // Stores the original (unscaled) display dimensions so resolution
    // scaling can be re-applied on each pipeline-shape change.
    private var originalDisplayWidth: Int = 0
    private var originalDisplayHeight: Int = 0
    private var currentFPS: Int = 60
    private var isDualMode: Bool = false
    private var originalDualWidth1: Int = 0
    private var originalDualHeight1: Int = 0
    private var originalDualWidth2: Int = 0
    private var originalDualHeight2: Int = 0
    private var lastMicEnabled = AppSettings.captureMicrophone

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

        setupSettingsObservations()

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

    // MARK: - Runtime settings reconciler

    private func setupSettingsObservations() {
        // Group 1: Live mutable settings - apply directly
        settingsObservations.append(Defaults.observe(.systemAudioVolume) { [weak self] _ in
            self?.systemAudioCapture.setVolume(AppSettings.systemAudioVolume)
        })
        settingsObservations.append(Defaults.observe(.microphoneVolume) { [weak self] _ in
            self?.micAudioCapture.setVolume(AppSettings.microphoneVolume)
        })

        // Debounced through one reconciler so preset/UI changes do not race.
        settingsObservations.append(Defaults.observe(.frameRate) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })
        settingsObservations.append(Defaults.observe(.queueDepth) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })
        settingsObservations.append(Defaults.observe(.excludeOwnAppAudio) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })

        settingsObservations.append(Defaults.observe(.videoCodec) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })
        settingsObservations.append(Defaults.observe(.bitrateMbps) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })
        settingsObservations.append(Defaults.observe(.captureResolution) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })
        settingsObservations.append(Defaults.observe(.customCaptureWidth) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })
        settingsObservations.append(Defaults.observe(.customCaptureHeight) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })
        settingsObservations.append(Defaults.observe(.captureMicrophone) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })

        // Capture mode and display selection trigger full pipeline restart
        settingsObservations.append(Defaults.observe(.captureMode) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile(needsFullRestart: true)
        })
        settingsObservations.append(Defaults.observe(.captureDisplayID) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile(needsFullRestart: true)
        })
        settingsObservations.append(Defaults.observe(.captureDisplayID2) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile(needsFullRestart: true)
        })
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
        Task {
            await startCapturePipelineAsync(userInitiated: userInitiated)
        }
    }

    private func startCapturePipelineAsync(userInitiated: Bool = true) async {
        guard !isCaptureRunning else {
            return
        }

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
                let codec: Encode.VideoCodec = AppSettings.videoCodec == "hevc" ? .hevc : .h264
                let bitrate = Int(AppSettings.bitrateMbps * 1_000_000)
                let fps = AppSettings.frameRate
                let queueDepth = AppSettings.queueDepth
                let excludeOwn = AppSettings.excludeOwnAppAudio

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

                    let captureDisplayID1 = AppSettings.captureDisplayID.isEmpty ? nil : AppSettings.captureDisplayID
                    let captureDisplayID2 = AppSettings.captureDisplayID2.isEmpty ? nil : AppSettings.captureDisplayID2

                    let dualConfigs = try await captureManager.startDual(
                        interactivePermissionPrompt: userInitiated,
                        captureDisplayID1: captureDisplayID1,
                        captureDisplayID2: captureDisplayID2,
                        fps: fps,
                        queueDepth: queueDepth,
                        outputWidth1: nil,
                        outputHeight1: nil,
                        outputWidth2: nil,
                        outputHeight2: nil,
                        excludeOwnAppAudio: excludeOwn
                    )

                    originalDualWidth1 = dualConfigs.config1.sourceWidth
                    originalDualHeight1 = dualConfigs.config1.sourceHeight
                    originalDualWidth2 = dualConfigs.config2.sourceWidth
                    originalDualHeight2 = dualConfigs.config2.sourceHeight

                    let scaled1 = AppSettings.scaledDimensions(displayWidth: originalDualWidth1, displayHeight: originalDualHeight1)
                    let scaled2 = AppSettings.scaledDimensions(displayWidth: originalDualWidth2, displayHeight: originalDualHeight2)

                    try await captureManager.updateDualStreamConfigurations(
                        fps: fps,
                        queueDepth: queueDepth,
                        excludeOwnAppAudio: excludeOwn,
                        resolution1: CaptureResolutionConfig(width: scaled1.width, height: scaled1.height),
                        resolution2: CaptureResolutionConfig(width: scaled2.width, height: scaled2.height)
                    )

                    let compositeWidth = scaled1.width + scaled2.width
                    let compositeHeight = max(scaled1.height, scaled2.height)

                    frameCompositor.configure(
                        display1Width: scaled1.width,
                        display1Height: scaled1.height,
                        display2Width: scaled2.width,
                        display2Height: scaled2.height
                    )

                    try videoEncoder.start(
                        width: compositeWidth,
                        height: compositeHeight,
                        fps: fps,
                        codec: codec,
                        bitrate: bitrate
                    )
                    try dualDisplay1VideoEncoder.start(
                        width: scaled1.width,
                        height: scaled1.height,
                        fps: fps,
                        codec: codec,
                        bitrate: bitrate
                    )
                    try dualDisplay2VideoEncoder.start(
                        width: scaled2.width,
                        height: scaled2.height,
                        fps: fps,
                        codec: codec,
                        bitrate: bitrate
                    )

                    isDualMode = true

                    print("Dual capture started: Display1=\(originalDualWidth1)x\(originalDualHeight1) -> \(scaled1.width)x\(scaled1.height), Display2=\(originalDualWidth2)x\(originalDualHeight2) -> \(scaled2.width)x\(scaled2.height), Composite=\(compositeWidth)x\(compositeHeight)")
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
                        fps: fps,
                        queueDepth: queueDepth,
                        excludeOwnAppAudio: excludeOwn
                    )

                    originalDisplayWidth = config.sourceWidth
                    originalDisplayHeight = config.sourceHeight

                    let scaled = AppSettings.scaledDimensions(displayWidth: originalDisplayWidth, displayHeight: originalDisplayHeight)

                    try await captureManager.updateStreamConfiguration(
                        fps: fps,
                        queueDepth: queueDepth,
                        excludeOwnAppAudio: excludeOwn,
                        resolution: CaptureResolutionConfig(width: scaled.width, height: scaled.height)
                    )

                    try videoEncoder.start(
                        width: scaled.width,
                        height: scaled.height,
                        fps: fps,
                        codec: codec,
                        bitrate: bitrate
                    )

                    isDualMode = false

                    print("Single capture started: Display=\(originalDisplayWidth)x\(originalDisplayHeight) -> \(scaled.width)x\(scaled.height)")
                }

                currentFPS = fps
                lastMicEnabled = shouldCaptureMic

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

    private func stopCapturePipeline() {
        Task {
            await stopCapturePipelineAsync()
        }
    }

    private func stopCapturePipelineAsync() async {
        guard isCaptureRunning else {
            return
        }

        monitoringTask?.cancel()
        monitoringTask = nil

        await captureManager.stop()
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
            Task { await stopCapturePipelineAsync() }
        } else {
            startCapturePipeline(userInitiated: true)
        }
    }

    // MARK: - Runtime settings reconciler handlers

    private func scheduleRuntimeSettingsReconcile(needsFullRestart: Bool = false) {
        pendingRuntimeSettingsReconcile = true
        pendingRuntimeFullRestart = pendingRuntimeFullRestart || needsFullRestart

        guard settingsReconcileTask == nil else { return }

        settingsReconcileTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    await MainActor.run {
                        self?.settingsReconcileTask = nil
                    }
                    return
                }

                guard let self else { return }
                let needsFullRestart = await MainActor.run {
                    let needsFullRestart = self.pendingRuntimeFullRestart
                    self.pendingRuntimeSettingsReconcile = false
                    self.pendingRuntimeFullRestart = false
                    return needsFullRestart
                }

                await self.reconcileRuntimeSettings(needsFullRestart: needsFullRestart)

                let shouldContinue = await MainActor.run {
                    if self.pendingRuntimeSettingsReconcile {
                        return true
                    }

                    self.settingsReconcileTask = nil
                    return false
                }

                if !shouldContinue {
                    return
                }
            }
        }
    }

    private func reconcileRuntimeSettings(needsFullRestart: Bool) async {
        guard isCaptureRunning else { return }

        do {
            if needsFullRestart {
                await restartFullPipeline()
            } else {
                try await applyPipelineShapeChanges()
                await applyMicSettingIfNeeded()
            }
        } catch {
            print("Failed to apply runtime settings: \(error)")
        }
    }

    private func applyPipelineShapeChanges() async throws {
        let codec: Encode.VideoCodec = AppSettings.videoCodec == "hevc" ? .hevc : .h264
        let bitrate = Int(AppSettings.bitrateMbps * 1_000_000)
        let fps = AppSettings.frameRate

        // Clear video ring buffers since encoded format may change
        videoRingBuffer.clear()
        dualDisplay1VideoRingBuffer.clear()
        dualDisplay2VideoRingBuffer.clear()

        // Stop all video encoders (SCK streams keep running at native resolution)
        videoEncoder.stop()
        if isDualMode {
            dualDisplay1VideoEncoder.stop()
            dualDisplay2VideoEncoder.stop()
        }

        // Recalculate scaled dimensions from original (unscaled) display sizes
        if isDualMode {
            let scaled1 = AppSettings.scaledDimensions(displayWidth: originalDualWidth1, displayHeight: originalDualHeight1)
            let scaled2 = AppSettings.scaledDimensions(displayWidth: originalDualWidth2, displayHeight: originalDualHeight2)

            let compositeWidth = scaled1.width + scaled2.width
            let compositeHeight = max(scaled1.height, scaled2.height)

            frameCompositor.configure(
                display1Width: scaled1.width,
                display1Height: scaled1.height,
                display2Width: scaled2.width,
                display2Height: scaled2.height
            )

            try await captureManager.updateDualStreamConfigurations(
                fps: fps,
                queueDepth: AppSettings.queueDepth,
                excludeOwnAppAudio: AppSettings.excludeOwnAppAudio,
                resolution1: CaptureResolutionConfig(width: scaled1.width, height: scaled1.height),
                resolution2: CaptureResolutionConfig(width: scaled2.width, height: scaled2.height)
            )

            // Restart encoders with new codec/bitrate/resolution
            try videoEncoder.start(width: compositeWidth, height: compositeHeight, fps: fps, codec: codec, bitrate: bitrate)
            try dualDisplay1VideoEncoder.start(width: scaled1.width, height: scaled1.height, fps: fps, codec: codec, bitrate: bitrate)
            try dualDisplay2VideoEncoder.start(width: scaled2.width, height: scaled2.height, fps: fps, codec: codec, bitrate: bitrate)
        } else {
            let scaled = AppSettings.scaledDimensions(displayWidth: originalDisplayWidth, displayHeight: originalDisplayHeight)

            try await captureManager.updateStreamConfiguration(
                fps: fps,
                queueDepth: AppSettings.queueDepth,
                excludeOwnAppAudio: AppSettings.excludeOwnAppAudio,
                resolution: CaptureResolutionConfig(width: scaled.width, height: scaled.height)
            )

            // Restart encoder with new codec/bitrate/resolution
            try videoEncoder.start(width: scaled.width, height: scaled.height, fps: fps, codec: codec, bitrate: bitrate)
        }

        currentFPS = fps
    }

    private func applyMicSettingIfNeeded() async {
        let shouldCaptureMic = AppSettings.captureMicrophone
        guard shouldCaptureMic != lastMicEnabled else { return }

        if shouldCaptureMic {
            let micPermissionGranted = await requestMicrophonePermissionIfNeeded()
            if micPermissionGranted {
                micAudioCapture.stop()
                micAudioRingBuffer.clear()
                do {
                    try micAudioCapture.start()
                    lastMicEnabled = true
                } catch {
                    print("Warning: Failed to restart mic capture: \(error)")
                }
            } else {
                print("Warning: Microphone permission denied.")
            }
        } else {
            micAudioCapture.stop()
            micAudioRingBuffer.clear()
            lastMicEnabled = false
        }
    }

    private func restartFullPipeline() async {
        await stopCapturePipelineAsync()
        await startCapturePipelineAsync(userInitiated: false)
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
        settingsReconcileTask?.cancel()
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
