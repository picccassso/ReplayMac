import Foundation
import os

import Audio
import Capture
import Defaults
import Encode
import Feedback
import Save
import UI

let captureRecoveryLogger = Logger(subsystem: "com.replaymac", category: "CaptureRecovery")

@MainActor
extension AppDelegate {
    func configurePipelines() {
        videoEncoder.outputHandler = replayMacPrimaryVideoOutputHandler(
            videoRingBuffer: videoRingBuffer,
            longBufferAppendPump: longBufferAppendPump
        )
        dualDisplay1VideoEncoder.outputHandler = replayMacDualVideoOutputHandler(dualDisplay1VideoRingBuffer)
        dualDisplay2VideoEncoder.outputHandler = replayMacDualVideoOutputHandler(dualDisplay2VideoRingBuffer)

        frameCompositor.outputHandler = replayMacFrameCompositorOutputHandler(videoEncoder)

        systemAudioEncoder.outputHandler = replayMacSystemAudioOutputHandler(
            systemAudioRingBuffer: systemAudioRingBuffer,
            longBufferAppendPump: longBufferAppendPump
        )
        systemAudioCapture.setHandler(replayMacAudioEncodeHandler(systemAudioEncoder))
        perAppAudioCapture.setHandler(replayMacPerAppAudioHandler(systemAudioCapture))

        micAudioEncoder.outputHandler = replayMacMicrophoneOutputHandler(
            micAudioRingBuffer: micAudioRingBuffer,
            longBufferAppendPump: longBufferAppendPump
        )
        micAudioCapture.setHandler(replayMacAudioEncodeHandler(micAudioEncoder))
    }

    func startCapturePipeline(userInitiated: Bool = true) {
        if userInitiated {
            shouldResumeCaptureAfterInterruption = false
            captureRecoveryAttempts = 0
            captureRecoveryTask?.cancel()
            captureRecoveryTask = nil
        }
        Task {
            await startCapturePipelineAsync(userInitiated: userInitiated)
        }
    }

    func startCapturePipelineAsync(
        userInitiated: Bool = true,
        showFailureNotification: Bool = true,
        isRecoveryAttempt: Bool = false
    ) async {
        guard !isCaptureRunning else {
            return
        }

        do {
            videoRingBuffer.clear()
            dualDisplay1VideoRingBuffer.clear()
            dualDisplay2VideoRingBuffer.clear()
            systemAudioRingBuffer.clear()
            micAudioRingBuffer.clear()
            AudioLevelMonitor.shared.reset()
            longBufferAppendPump.reset()
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
                        originalDualPointPixelScale1 = dualConfigs.config1.sourcePointPixelScale
                        originalDualPixelWidth1 = dualConfigs.config1.sourcePixelWidth
                        originalDualPixelHeight1 = dualConfigs.config1.sourcePixelHeight
                        originalDualWidth2 = dualConfigs.config2.sourceWidth
                        originalDualHeight2 = dualConfigs.config2.sourceHeight
                        originalDualPointPixelScale2 = dualConfigs.config2.sourcePointPixelScale
                        originalDualPixelWidth2 = dualConfigs.config2.sourcePixelWidth
                        originalDualPixelHeight2 = dualConfigs.config2.sourcePixelHeight

                        let scaled1 = AppSettings.scaledDimensions(
                            displayWidth: originalDualWidth1,
                            displayHeight: originalDualHeight1,
                            pointPixelScale: originalDualPointPixelScale1,
                            maxPixelWidth: originalDualPixelWidth1,
                            maxPixelHeight: originalDualPixelHeight1
                        )
                        let scaled2 = AppSettings.scaledDimensions(
                            displayWidth: originalDualWidth2,
                            displayHeight: originalDualHeight2,
                            pointPixelScale: originalDualPointPixelScale2,
                            maxPixelWidth: originalDualPixelWidth2,
                            maxPixelHeight: originalDualPixelHeight2
                        )

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

                        print("Dual capture started: Display1=\(originalDualWidth1)x\(originalDualHeight1) @\(originalDualPointPixelScale1)x -> \(scaled1.width)x\(scaled1.height), Display2=\(originalDualWidth2)x\(originalDualHeight2) @\(originalDualPointPixelScale2)x -> \(scaled2.width)x\(scaled2.height), Composite=\(compositeWidth)x\(compositeHeight)")
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
                if !isRecoveryAttempt {
                    shouldResumeCaptureAfterInterruption = false
                    captureRecoveryAttempts = 0
                }
                menuBarState.setRecording(true)
                menuBarState.setExtendedBufferRecording(
                    AppSettings.longBufferEnabled && !isSeparateDualSaveMode
                )
                statusItemController.refreshPresentation()
                startMonitoring()
        } catch {
            if !userInitiated,
               !UserDefaults.standard.bool(forKey: "hasPromptedForScreenCapture") {
                UserDefaults.standard.set(true, forKey: "hasPromptedForScreenCapture")
                await startCapturePipelineAsync(
                    userInitiated: true,
                    showFailureNotification: showFailureNotification,
                    isRecoveryAttempt: isRecoveryAttempt
                )
                return
            }

            await cleanupAfterFailedCaptureStart()
            isCaptureRunning = false
            menuBarState.setRecording(false)
            statusItemController.refreshPresentation()
            let message = CaptureStartErrorMapper.userMessage(for: error)
            if showFailureNotification {
                NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            }
            print("Failed to start capture: \(error)")
        }
    }

    func cleanupAfterFailedCaptureStart() async {
        await captureManager.stop()
        await perAppAudioCapture.stop()
        longBufferAppendPump.reset()
        await longBufferRecorder.stop(deleteSegments: false)
        micAudioCapture.stop()
        videoEncoder.stop()
        dualDisplay1VideoEncoder.stop()
        dualDisplay2VideoEncoder.stop()
        systemAudioEncoder.stop()
        micAudioEncoder.stop()
        frameCompositor.reset()
        AudioLevelMonitor.shared.reset()
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
        originalDisplayPointPixelScale = config.sourcePointPixelScale
        originalDisplayPixelWidth = config.sourcePixelWidth
        originalDisplayPixelHeight = config.sourcePixelHeight

        let scaled = AppSettings.scaledDimensions(
            displayWidth: originalDisplayWidth,
            displayHeight: originalDisplayHeight,
            pointPixelScale: originalDisplayPointPixelScale,
            maxPixelWidth: originalDisplayPixelWidth,
            maxPixelHeight: originalDisplayPixelHeight
        )

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

        print("Single capture started: Display=\(originalDisplayWidth)x\(originalDisplayHeight) @\(originalDisplayPointPixelScale)x -> \(scaled.width)x\(scaled.height)")
    }

    func stopCapturePipeline() {
        Task {
            await stopCapturePipelineAsync()
        }
    }

    func stopCapturePipelineAsync(preserveResumeIntent: Bool = false) async {
        if !preserveResumeIntent {
            shouldResumeCaptureAfterInterruption = false
            captureRecoveryAttempts = 0
            captureRecoveryTask?.cancel()
            captureRecoveryTask = nil
        }
        guard isCaptureRunning else {
            return
        }

        monitoringTask?.cancel()
        monitoringTask = nil

        await captureManager.stop()
        await perAppAudioCapture.stop()
        longBufferAppendPump.reset()
        await longBufferRecorder.stop(deleteSegments: !preserveResumeIntent)
        micAudioCapture.stop()
        videoEncoder.stop()
        dualDisplay1VideoEncoder.stop()
        dualDisplay2VideoEncoder.stop()
        systemAudioEncoder.stop()
        micAudioEncoder.stop()
        frameCompositor.reset()
        AudioLevelMonitor.shared.reset()

        isCaptureRunning = false
        menuBarState.setRecording(false)
        menuBarState.setExtendedBufferRecording(false)
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
        menuBarState.setExtendedBufferRecording(enabled && isCaptureRunning)

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
        let shouldRecoverUnexpectedStop = CaptureRecoveryPolicy.shouldRecoverUnexpectedStreamStop(
            automaticResumeEnabled: AppSettings.resumeRecordingAfterWake,
            captureWasRunning: isCaptureRunning
        )
        if shouldRecoverUnexpectedStop {
            switch interruption {
            case .permissionRevoked:
                break
            case .systemStopped:
                beginRecoverableCaptureInterruption(reason: "ScreenCaptureKit system stop")
                return
            case .displayDisconnected:
                beginRecoverableCaptureInterruption(reason: "display became unavailable")
                return
            case .stopped(let reason):
                beginRecoverableCaptureInterruption(reason: "unexpected stream stop: \(reason)")
                return
            }
        }

        let shouldRecoverTransitionStop = CaptureRecoveryPolicy.shouldPreserveTransitionStop(
            automaticResumeEnabled: AppSettings.resumeRecordingAfterWake,
            shouldResume: shouldResumeCaptureAfterInterruption,
            isSessionActive: isWorkspaceSessionActive,
            areScreensAwake: areScreensAwake,
            isPreparingRecovery: isPreparingCaptureRecovery
        )
        if shouldRecoverTransitionStop {
            switch interruption {
            case .permissionRevoked:
                break
            case .systemStopped:
                beginRecoverableCaptureInterruption(reason: "ScreenCaptureKit system stop")
                return
            case .displayDisconnected:
                beginRecoverableCaptureInterruption(reason: "display changed during sleep or session transition")
                return
            case .stopped(let reason):
                beginRecoverableCaptureInterruption(
                    reason: "stream stopped during sleep or session transition: \(reason)"
                )
                return
            }
        }

        switch interruption {
        case .systemStopped:
            beginRecoverableCaptureInterruption(reason: "ScreenCaptureKit system stop")
        case .permissionRevoked, .displayDisconnected, .stopped:
            if let message = interruption.userMessage {
                NotificationManager.shared.showOperationalNotification(title: message.title, body: message.body)
            }
            if case .stopped(let reason) = interruption {
                print("Capture stopped: \(reason)")
            }
            stopCapturePipeline()
        }
    }

    func beginRecoverableCaptureInterruption(reason: String) {
        guard AppSettings.resumeRecordingAfterWake else {
            NotificationManager.shared.showOperationalNotification(
                title: "Recording Paused",
                body: "macOS interrupted screen capture. Choose Start Recording to continue."
            )
            stopCapturePipeline()
            return
        }
        guard isCaptureRunning || shouldResumeCaptureAfterInterruption else {
            return
        }
        guard !isPreparingCaptureRecovery else { return }

        shouldResumeCaptureAfterInterruption = true
        isPreparingCaptureRecovery = true
        captureRecoveryLogger.warning("Preparing capture recovery after \(reason, privacy: .public)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopCapturePipelineAsync(preserveResumeIntent: true)
            self.isPreparingCaptureRecovery = false
            self.scheduleCaptureRecoveryIfNeeded(reason: reason)
        }
    }

    func scheduleCaptureRecoveryIfNeeded(reason: String) {
        let shouldSchedule = CaptureRecoveryPolicy.shouldScheduleRecovery(
            automaticResumeEnabled: AppSettings.resumeRecordingAfterWake,
            shouldResume: shouldResumeCaptureAfterInterruption,
            isSessionActive: isWorkspaceSessionActive,
            areScreensAwake: areScreensAwake,
            isPreparingRecovery: isPreparingCaptureRecovery,
            hasScheduledRecovery: captureRecoveryTask != nil
        )
        guard shouldSchedule else {
            captureRecoveryLogger.debug(
                "Recovery not scheduled reason=\(reason, privacy: .public) enabled=\(AppSettings.resumeRecordingAfterWake, privacy: .public) shouldResume=\(self.shouldResumeCaptureAfterInterruption, privacy: .public) sessionActive=\(self.isWorkspaceSessionActive, privacy: .public) screensAwake=\(self.areScreensAwake, privacy: .public) preparing=\(self.isPreparingCaptureRecovery, privacy: .public) alreadyScheduled=\(self.captureRecoveryTask != nil, privacy: .public)"
            )
            return
        }

        captureRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var shouldRetry = false
            defer {
                self.captureRecoveryTask = nil
                if shouldRetry {
                    self.scheduleCaptureRecoveryIfNeeded(reason: reason)
                }
            }

            // External displays can take substantially longer than the user
            // session to return. Back off across attempts so ScreenCaptureKit
            // receives fresh display objects rather than exhausting retries in
            // the first few seconds after loginwindow disappears.
            let delay = CaptureRecoveryPolicy.retryDelay(
                completedAttempts: self.captureRecoveryAttempts
            )
            captureRecoveryLogger.info(
                "Scheduling capture recovery attempt \(self.captureRecoveryAttempts + 1, privacy: .public) after \(delay, privacy: .public)s; reason=\(reason, privacy: .public)"
            )
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  AppSettings.resumeRecordingAfterWake,
                  self.shouldResumeCaptureAfterInterruption,
                  self.isWorkspaceSessionActive,
                  self.areScreensAwake else {
                return
            }

            if self.isCaptureRunning {
                await self.stopCapturePipelineAsync(preserveResumeIntent: true)
            }
            await self.startCapturePipelineAsync(
                userInitiated: false,
                showFailureNotification: false,
                isRecoveryAttempt: true
            )

            if self.isCaptureRunning {
                captureRecoveryLogger.info(
                    "Validating capture recovery attempt \(self.captureRecoveryAttempts + 1, privacy: .public) for video callbacks"
                )
                try? await Task.sleep(for: .seconds(5))
            }
            guard !Task.isCancelled else {
                return
            }

            let stats = self.isDualMode
                ? self.captureManager.captureStats1()
                : self.captureManager.captureStats()
            let now = Date()
            let isStable = CaptureRecoveryPolicy.isStableRestart(
                isCaptureRunning: self.isCaptureRunning,
                lastVideoSampleDate: stats.lastVideoSampleDate,
                now: now
            )

            if isStable {
                self.shouldResumeCaptureAfterInterruption = false
                self.captureRecoveryAttempts = 0
                captureRecoveryLogger.info("Capture recovery succeeded after \(reason, privacy: .public)")
                NotificationManager.shared.showOperationalNotification(
                    title: "Recording Resumed",
                    body: "ReplayMac resumed recording after \(reason)."
                )
            } else {
                self.captureRecoveryAttempts += 1
                let lastVideoAge = stats.lastVideoSampleDate
                    .map { now.timeIntervalSince($0) } ?? -1
                captureRecoveryLogger.error(
                    "Capture recovery attempt \(self.captureRecoveryAttempts, privacy: .public) was not stable after \(reason, privacy: .public); running=\(self.isCaptureRunning, privacy: .public) lastVideoAge=\(lastVideoAge, privacy: .public)"
                )
                shouldRetry = self.captureRecoveryAttempts < CaptureRecoveryPolicy.maximumAttempts
                if !shouldRetry {
                    NotificationManager.shared.showOperationalNotification(
                        title: "Recording Could Not Resume",
                        body: "ReplayMac could not restore screen capture automatically. Choose Start Recording to try again."
                    )
                }
            }
        }
    }

}
