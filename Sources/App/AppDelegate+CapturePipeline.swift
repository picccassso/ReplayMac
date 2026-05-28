import Foundation

import Capture
import Defaults
import Encode
import Feedback
import Save
import UI

@MainActor
extension AppDelegate {
    func configurePipelines() {
        videoEncoder.outputHandler = replayMacPrimaryVideoOutputHandler(
            videoRingBuffer: videoRingBuffer,
            longBufferRecorder: longBufferRecorder
        )
        dualDisplay1VideoEncoder.outputHandler = replayMacDualVideoOutputHandler(dualDisplay1VideoRingBuffer)
        dualDisplay2VideoEncoder.outputHandler = replayMacDualVideoOutputHandler(dualDisplay2VideoRingBuffer)

        frameCompositor.outputHandler = replayMacFrameCompositorOutputHandler(videoEncoder)

        systemAudioEncoder.outputHandler = replayMacSystemAudioOutputHandler(
            systemAudioRingBuffer: systemAudioRingBuffer,
            longBufferRecorder: longBufferRecorder
        )
        systemAudioCapture.setHandler(replayMacAudioEncodeHandler(systemAudioEncoder))
        perAppAudioCapture.setHandler(replayMacPerAppAudioHandler(systemAudioCapture))

        micAudioEncoder.outputHandler = replayMacMicrophoneOutputHandler(
            micAudioRingBuffer: micAudioRingBuffer,
            longBufferRecorder: longBufferRecorder
        )
        micAudioCapture.setHandler(replayMacAudioEncodeHandler(micAudioEncoder))
    }

    func startCapturePipeline(userInitiated: Bool = true) {
        Task {
            await startCapturePipelineAsync(userInitiated: userInitiated)
        }
    }

    func startCapturePipelineAsync(userInitiated: Bool = true) async {
        guard !isCaptureRunning else {
            return
        }

        do {
            videoRingBuffer.clear()
            dualDisplay1VideoRingBuffer.clear()
            dualDisplay2VideoRingBuffer.clear()
            systemAudioRingBuffer.clear()
            micAudioRingBuffer.clear()
            await configureLongBufferForCurrentSettings()

                let shouldCaptureMic = AppSettings.captureMicrophone
                let micPermissionGranted = shouldCaptureMic ? await requestMicrophonePermissionIfNeeded() : false
                if shouldCaptureMic && !micPermissionGranted {
                    notifyMicPermissionDeniedIfNeeded()
                }

                let isDual = AppSettings.captureMode == CaptureMode.dualSideBySide.rawValue
                let codec: Encode.VideoCodec = AppSettings.videoCodec == "hevc" ? .hevc : .h264
                let bitrate = Int(AppSettings.bitrateMbps * 1_000_000)
                let fps = AppSettings.frameRate
                let queueDepth = AppSettings.queueDepth
                let excludeOwn = AppSettings.excludeOwnAppAudio
                var captureSystemAudioForSession = AppSettings.captureSystemAudio
                var usePerAppAudio = captureSystemAudioForSession
                    && AppSettings.perAppAudioEnabled
                    && !AppSettings.perAppAudioBundleID.isEmpty

                if usePerAppAudio {
                    do {
                        try await perAppAudioCapture.start(
                            bundleID: AppSettings.perAppAudioBundleID,
                            excludeOwnAppAudio: excludeOwn
                        )
                    } catch {
                        NotificationManager.shared.showOperationalNotification(
                            title: "Per-App Audio Unavailable",
                            body: "No system audio will be captured for this session. \(error.localizedDescription)"
                        )
                        usePerAppAudio = false
                        captureSystemAudioForSession = false
                    }
                }
                let captureMainSystemAudio = captureSystemAudioForSession && !usePerAppAudio

            if isDual {
                    let dualSaveMode = AppSettings.dualCaptureSaveModeEnum
                    await configureDualVideoHandlers(saveMode: dualSaveMode)
                    await captureManager.setAudioHandler1(replayMacSystemAudioProcessHandler(systemAudioCapture))

                    let captureDisplayID1 = AppSettings.captureDisplayID.isEmpty ? nil : AppSettings.captureDisplayID
                    let captureDisplayID2 = AppSettings.captureDisplayID2.isEmpty ? nil : AppSettings.captureDisplayID2

                    let dualConfigs: (config1: CaptureConfig, config2: CaptureConfig)?
                    do {
                        dualConfigs = try await captureManager.startDual(
                            interactivePermissionPrompt: userInitiated,
                            captureDisplayID1: captureDisplayID1,
                            captureDisplayID2: captureDisplayID2,
                            fps: fps,
                            queueDepth: queueDepth,
                            outputWidth1: nil,
                            outputHeight1: nil,
                            outputWidth2: nil,
                            outputHeight2: nil,
                            excludeOwnAppAudio: excludeOwn,
                            captureAudio: captureMainSystemAudio
                        )
                    } catch CaptureError.notEnoughDisplays {
                        Defaults[.captureMode] = CaptureMode.single.rawValue
                        dualConfigs = nil
                        print("Dual capture unavailable; falling back to single display capture.")
                        try await startSingleDisplayCapture(
                            userInitiated: userInitiated,
                            fps: fps,
                            queueDepth: queueDepth,
                            excludeOwnAppAudio: excludeOwn,
                            codec: codec,
                            bitrate: bitrate,
                            captureAudio: captureMainSystemAudio
                        )
                    }

                    if let dualConfigs {
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
                            display2Height: scaled2.height,
                            fps: fps
                        )

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

                        isDualMode = true
                        syncMemoryCapsToSettings()

                        print("Dual capture started: Display1=\(originalDualWidth1)x\(originalDualHeight1) -> \(scaled1.width)x\(scaled1.height), Display2=\(originalDualWidth2)x\(originalDualHeight2) -> \(scaled2.width)x\(scaled2.height), Composite=\(compositeWidth)x\(compositeHeight)")
                    }
                } else {
                    try await startSingleDisplayCapture(
                        userInitiated: userInitiated,
                        fps: fps,
                        queueDepth: queueDepth,
                        excludeOwnAppAudio: excludeOwn,
                        codec: codec,
                        bitrate: bitrate,
                        captureAudio: captureMainSystemAudio
                    )
                }

                currentFPS = fps
                lastMicEnabled = shouldCaptureMic

                if shouldCaptureMic && micPermissionGranted {
                    do {
                        try micAudioCapture.start(deviceID: AppSettings.microphoneID)
                        lastMicDeviceID = AppSettings.microphoneID
                    } catch {
                        print("Warning: Failed to start mic capture: \(error)")
                        NotificationManager.shared.showOperationalNotification(
                            title: "Microphone Unavailable",
                            body: error.localizedDescription
                        )
                    }
                }

                isCaptureRunning = true
                menuBarState.setRecording(true)
                statusItemController.refreshPresentation()
                startMonitoring()
        } catch {
            if !userInitiated,
               !UserDefaults.standard.bool(forKey: "hasPromptedForScreenCapture") {
                UserDefaults.standard.set(true, forKey: "hasPromptedForScreenCapture")
                await startCapturePipelineAsync(userInitiated: true)
                return
            }

            isCaptureRunning = false
            await perAppAudioCapture.stop()
            menuBarState.setRecording(false)
            statusItemController.refreshPresentation()
            let message = CaptureStartErrorMapper.userMessage(for: error)
            NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            print("Failed to start capture: \(error)")
        }
    }

    func startSingleDisplayCapture(
        userInitiated: Bool,
        fps: Int,
        queueDepth: Int,
        excludeOwnAppAudio: Bool,
        codec: Encode.VideoCodec,
        bitrate: Int,
        captureAudio: Bool
    ) async throws {
        await captureManager.setVideoHandler(replayMacVideoEncodeHandler(videoEncoder))
        await captureManager.setAudioHandler(replayMacSystemAudioProcessHandler(systemAudioCapture))

        let config = try await captureManager.start(
            interactivePermissionPrompt: userInitiated,
            captureDisplayID: AppSettings.captureDisplayID.isEmpty ? nil : AppSettings.captureDisplayID,
            fps: fps,
            queueDepth: queueDepth,
            excludeOwnAppAudio: excludeOwnAppAudio,
            captureAudio: captureAudio
        )

        originalDisplayWidth = config.sourceWidth
        originalDisplayHeight = config.sourceHeight

        let scaled = AppSettings.scaledDimensions(displayWidth: originalDisplayWidth, displayHeight: originalDisplayHeight)

        try await captureManager.updateStreamConfiguration(
            fps: fps,
            queueDepth: queueDepth,
            excludeOwnAppAudio: excludeOwnAppAudio,
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
        syncMemoryCapsToSettings()

        print("Single capture started: Display=\(originalDisplayWidth)x\(originalDisplayHeight) -> \(scaled.width)x\(scaled.height)")
    }

    func stopCapturePipeline() {
        Task {
            await stopCapturePipelineAsync()
        }
    }

    func stopCapturePipelineAsync() async {
        guard isCaptureRunning else {
            return
        }

        monitoringTask?.cancel()
        monitoringTask = nil

        await captureManager.stop()
        await perAppAudioCapture.stop()
        await longBufferRecorder.stop(deleteSegments: true)
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
        statusItemController.refreshPresentation()
    }

    func configureLongBufferForCurrentSettings() async {
        let separateDualSave = AppSettings.captureMode == CaptureMode.dualSideBySide.rawValue
            && AppSettings.dualCaptureSaveMode == DualCaptureSaveMode.separateFiles.rawValue
        let enabled = AppSettings.longBufferEnabled && !separateDualSave
        await longBufferRecorder.configure(
            enabled: enabled,
            maxDurationSeconds: TimeInterval(AppSettings.longBufferDurationSeconds),
            outputDirectory: AppSettings.outputDirectoryURL
        )

        if AppSettings.longBufferEnabled && separateDualSave {
            NotificationManager.shared.showOperationalNotification(
                title: "Long Buffer Disabled",
                body: "Extended replay is not available while dual display clips are saved as separate files."
            )
        }
    }

    func toggleCapturePipeline() {
        if isCaptureRunning {
            Task { await stopCapturePipelineAsync() }
        } else {
            startCapturePipeline(userInitiated: true)
        }
    }

    func handleCaptureInterruption(_ interruption: CaptureInterruption) {
        switch interruption {
        case .restartedAfterGPUPressure:
            menuBarState.setRecording(true)
            if let message = interruption.userMessage {
                NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            }
        case .gpuPressurePaused, .permissionRevoked, .displayDisconnected, .stopped:
            if let message = interruption.userMessage {
                NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            }
            if case .stopped(let reason) = interruption {
                print("Capture stopped: \(reason)")
            }
            stopCapturePipeline()
        }
    }

}
