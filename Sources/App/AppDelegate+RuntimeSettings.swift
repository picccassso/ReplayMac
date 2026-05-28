import AVFoundation
import Capture
import Defaults
import Encode
import Feedback
import UI

@MainActor
extension AppDelegate {
    // MARK: - Runtime settings reconciler

    func setupSettingsObservations() {
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
        settingsObservations.append(Defaults.observe(.microphoneID) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })
        settingsObservations.append(Defaults.observe(.memoryCapMB) { [weak self] _ in
            self?.syncMemoryCapsToSettings()
        })
        settingsObservations.append(Defaults.observe(.captureSystemAudio) { [weak self] _ in
            self?.syncMemoryCapsToSettings()
            self?.scheduleRuntimeSettingsReconcile(needsFullRestart: true)
        })
        settingsObservations.append(Defaults.observe(.perAppAudioEnabled) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile(needsFullRestart: true)
        })
        settingsObservations.append(Defaults.observe(.perAppAudioBundleID) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile(needsFullRestart: true)
        })
        settingsObservations.append(Defaults.observe(.dualCaptureSaveMode) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile()
        })
        settingsObservations.append(Defaults.observe(.longBufferEnabled) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile(needsFullRestart: false)
        })
        settingsObservations.append(Defaults.observe(.longBufferDurationMinutes) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile(needsFullRestart: false)
        })

        // Capture mode and display selection trigger full pipeline restart
        settingsObservations.append(Defaults.observe(.captureMode) { [weak self] _ in
            guard let self else { return }
            guard self.isCaptureRunning else { return }
            self.scheduleRuntimeSettingsReconcile(needsFullRestart: true)
        })
        settingsObservations.append(Defaults.observe(.captureDisplayID) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile(needsFullRestart: true)
        })
        settingsObservations.append(Defaults.observe(.captureDisplayID2) { [weak self] _ in
            self?.scheduleRuntimeSettingsReconcile(needsFullRestart: true)
        })
    }

    // MARK: - Runtime settings reconciler handlers

    func scheduleRuntimeSettingsReconcile(needsFullRestart: Bool = false) {
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

    func reconcileRuntimeSettings(needsFullRestart: Bool) async {
        guard isCaptureRunning else { return }

        do {
            if needsFullRestart {
                await restartFullPipeline()
            } else {
                try await applyPipelineShapeChanges()
                await applyMicSettingIfNeeded()
                await configureLongBufferForCurrentSettings()
            }
        } catch {
            print("Failed to apply runtime settings: \(error)")
        }
    }

    func applyPipelineShapeChanges() async throws {
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
            let dualSaveMode = AppSettings.dualCaptureSaveModeEnum

            let compositeWidth = scaled1.width + scaled2.width
            let compositeHeight = max(scaled1.height, scaled2.height)

            frameCompositor.configure(
                display1Width: scaled1.width,
                display1Height: scaled1.height,
                display2Width: scaled2.width,
                display2Height: scaled2.height,
                fps: fps
            )

            try await captureManager.updateDualStreamConfigurations(
                fps: fps,
                queueDepth: AppSettings.queueDepth,
                excludeOwnAppAudio: AppSettings.excludeOwnAppAudio,
                resolution1: CaptureResolutionConfig(width: scaled1.width, height: scaled1.height),
                resolution2: CaptureResolutionConfig(width: scaled2.width, height: scaled2.height)
            )

            await configureDualVideoHandlers(saveMode: dualSaveMode)

            // Restart encoders with new codec/bitrate/resolution
            try startDualVideoEncoders(
                saveMode: dualSaveMode,
                compositeWidth: compositeWidth,
                compositeHeight: compositeHeight,
                display1Width: scaled1.width,
                display1Height: scaled1.height,
                display2Width: scaled2.width,
                display2Height: scaled2.height,
                fps: fps,
                codec: codec,
                bitrate: bitrate
            )
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

    func configureDualVideoHandlers(saveMode: DualCaptureSaveMode) async {
        switch saveMode {
        case .sideBySide:
            await captureManager.setVideoHandler1(replayMacPrimaryFrameCompositorHandler(frameCompositor))
            await captureManager.setVideoHandler2(replayMacSecondaryFrameCompositorHandler(frameCompositor))
        case .separateFiles:
            await captureManager.setVideoHandler1(replayMacVideoEncodeHandler(dualDisplay1VideoEncoder))
            await captureManager.setVideoHandler2(replayMacVideoEncodeHandler(dualDisplay2VideoEncoder))
        }
    }

    func startDualVideoEncoders(
        saveMode: DualCaptureSaveMode,
        compositeWidth: Int,
        compositeHeight: Int,
        display1Width: Int,
        display1Height: Int,
        display2Width: Int,
        display2Height: Int,
        fps: Int,
        codec: Encode.VideoCodec,
        bitrate: Int
    ) throws {
        switch saveMode {
        case .sideBySide:
            try videoEncoder.start(
                width: compositeWidth,
                height: compositeHeight,
                fps: fps,
                codec: codec,
                bitrate: bitrate
            )
        case .separateFiles:
            try dualDisplay1VideoEncoder.start(
                width: display1Width,
                height: display1Height,
                fps: fps,
                codec: codec,
                bitrate: bitrate
            )
            try dualDisplay2VideoEncoder.start(
                width: display2Width,
                height: display2Height,
                fps: fps,
                codec: codec,
                bitrate: bitrate
            )
        }
    }

    func applyMicSettingIfNeeded() async {
        let shouldCaptureMic = AppSettings.captureMicrophone
        let selectedMicDeviceID = AppSettings.microphoneID
        let micSettingsChanged = shouldCaptureMic != lastMicEnabled || selectedMicDeviceID != lastMicDeviceID
        guard micSettingsChanged else { return }

        if shouldCaptureMic {
            let micPermissionGranted = await requestMicrophonePermissionIfNeeded()
            if micPermissionGranted {
                micAudioCapture.stop()
                micAudioRingBuffer.clear()
                do {
                    try micAudioCapture.start(deviceID: selectedMicDeviceID)
                    lastMicEnabled = true
                    lastMicDeviceID = selectedMicDeviceID
                } catch {
                    print("Warning: Failed to restart mic capture: \(error)")
                    NotificationManager.shared.showOperationalNotification(
                        title: "Microphone Unavailable",
                        body: error.localizedDescription
                    )
                }
            } else {
                notifyMicPermissionDeniedIfNeeded()
            }
        } else {
            micAudioCapture.stop()
            micAudioRingBuffer.clear()
            lastMicEnabled = false
            lastMicDeviceID = selectedMicDeviceID
        }
    }

    func notifyMicPermissionDeniedIfNeeded() {
        guard !hasNotifiedMicDenied else { return }
        hasNotifiedMicDenied = true
        NotificationManager.shared.showOperationalNotification(
            title: "Microphone Access Denied",
            body: "Clips will not include a microphone track. Enable microphone access in System Settings → Privacy & Security → Microphone."
        )
    }

    func restartFullPipeline() async {
        await stopCapturePipelineAsync()
        await startCapturePipelineAsync(userInitiated: false)
    }

    func requestMicrophonePermissionIfNeeded() async -> Bool {
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

}
