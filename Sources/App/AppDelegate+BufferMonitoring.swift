import Dispatch
import Foundation
import os

import Capture
import UI
import CompanionServer

private let bufferMonitorLogger = Logger(subsystem: "com.replaycap", category: "BufferMonitor")

@MainActor
extension AppDelegate {
    func syncMemoryCapsToSettings() {
        // The pipeline's actual shape, not the setting: dual capture falls
        // back to a single display when only one is connected.
        let caps = AppSettings.ringBufferMemoryCaps(
            isDualMode: isDualMode,
            isSeparateDualSave: AppSettings.dualCaptureSaveModeEnum == .separateFiles,
            captureSystemAudio: AppSettings.captureSystemAudio,
            captureMicrophone: AppSettings.captureMicrophone
        )

        videoRingBuffer.setMemoryCap(caps.videoPerBuffer)
        dualDisplay1VideoRingBuffer.setMemoryCap(caps.videoPerBuffer)
        dualDisplay2VideoRingBuffer.setMemoryCap(caps.videoPerBuffer)
        systemAudioRingBuffer.setMemoryCap(caps.audioPerBuffer)
        micAudioRingBuffer.setMemoryCap(caps.audioPerBuffer)
    }

    func syncBufferDurationToSettings() {
        // Retain the requested window plus headroom so GOP-granular eviction never
        // leaves the buffer short of a full "Save Last N Seconds" (see
        // AppSettings.ringBufferHeadroomSeconds).
        // Under critical memory pressure the window is held shorter than the
        // setting until the pressure lifts (see MemoryPressurePolicy).
        let replaySeconds = MemoryPressurePolicy.replaySeconds(
            configured: AppSettings.bufferDurationSeconds,
            level: memoryPressureLevel
        )
        let cap = TimeInterval(replaySeconds) + AppSettings.ringBufferHeadroomSeconds
        // Audio's share of the memory cap is sized from the window.
        syncMemoryCapsToSettings()
        videoRingBuffer.timeCap = cap
        dualDisplay1VideoRingBuffer.timeCap = cap
        dualDisplay2VideoRingBuffer.timeCap = cap
        systemAudioRingBuffer.timeCap = cap
        micAudioRingBuffer.timeCap = cap

        guard isCaptureRunning else { return }
        videoRingBuffer.trimToDuration(maxSeconds: cap)
        dualDisplay1VideoRingBuffer.trimToDuration(maxSeconds: cap)
        dualDisplay2VideoRingBuffer.trimToDuration(maxSeconds: cap)
        systemAudioRingBuffer.trimToDuration(maxSeconds: cap)
        micAudioRingBuffer.trimToDuration(maxSeconds: cap)
    }

    func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task {
            var tick = 0
            let monitoringStartedAt = Date()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }

                tick += 1

                let captureStats = self.isDualMode
                    ? self.captureManager.captureStats1()
                    : self.captureManager.captureStats()
                let now = Date()
                if CaptureHealth.isVideoStalled(
                    isCaptureRunning: self.isCaptureRunning,
                    isSessionActive: self.isWorkspaceSessionActive && self.areScreensAwake,
                    monitoringStartedAt: monitoringStartedAt,
                    lastVideoSampleDate: captureStats.lastVideoSampleDate,
                    now: now
                ) {
                    self.beginRecoverableCaptureInterruption(reason: "capture watchdog")
                    break
                }

                self.applyEffectiveAudioVolumes()

                let isSessionActive = self.isWorkspaceSessionActive && self.areScreensAwake

                // A microphone that dies without posting a configuration change
                // — the engine wedging on a device that went away mid-call —
                // leaves the tap silent with nothing to notice it. Rebuilding
                // just the mic engine is isolated from video, so unlike the
                // capture watchdog above this recovers in place.
                self.micAudioCapture.restartIfStalled(timeout: 10, isSessionActive: isSessionActive)

                // Camera permission revoked mid-recording: tear the session
                // down (drops the green in-use indicator) and drop the stored
                // camera frame; the compositor omits the overlay from then on
                // and the recording continues without it.
                if self.cameraCapture.isRunning, CameraCapture.authorizationStatus() != .authorized {
                    bufferMonitorLogger.warning("Camera access was revoked mid-recording; stopping the camera overlay.")
                    self.cameraCapture.stop()
                    self.frameCompositor.clearCameraFrame()
                    self.notifyCameraPermissionDeniedIfNeeded()
                }

                // Judged against the main SCK stream's samples, so it must be
                // gated on the main stream actually carrying audio: per-app
                // audio runs a separate stream that reports no stats here.
                let systemAudioStalled = CaptureHealth.isAudioStalled(
                    isCaptureRunning: self.isCaptureRunning,
                    isCapturingAudio: self.isCapturingMainSystemAudio,
                    isSessionActive: isSessionActive,
                    monitoringStartedAt: monitoringStartedAt,
                    lastAudioSampleDate: captureStats.lastAudioSampleDate,
                    now: now
                )
                if systemAudioStalled, !self.hasWarnedSystemAudioStalled {
                    self.hasWarnedSystemAudioStalled = true
                    let age = captureStats.lastAudioSampleDate
                        .map { String(format: "%.0fs ago", now.timeIntervalSince($0)) } ?? "never"
                    bufferMonitorLogger.warning("System audio has not delivered a sample (\(age, privacy: .public)). Output device may have changed mid-capture.")
                } else if !systemAudioStalled {
                    self.hasWarnedSystemAudioStalled = false
                }

                let videoDuration = self.videoRingBuffer.duration
                let dualDisplay1Duration = self.dualDisplay1VideoRingBuffer.duration
                let dualDisplay2Duration = self.dualDisplay2VideoRingBuffer.duration
                let bufferedSeconds = SavePreflight.bufferedSeconds(
                    primaryVideo: videoDuration,
                    dualDisplay1: dualDisplay1Duration,
                    dualDisplay2: dualDisplay2Duration,
                    isSeparateDualSave: self.isSeparateDualSaveMode
                )
                self.menuBarState.updateRecordingElapsed()
                self.menuBarState.setBufferedSeconds(bufferedSeconds)
                self.statusItemController.refreshPresentation()

                if self.companionServer.isRunning {
                    let tick = CompanionTelemetryTick(
                        recordingElapsedSeconds: self.menuBarState.recordingElapsedSeconds,
                        extendedBufferElapsedSeconds: self.menuBarState.extendedBufferElapsedSeconds,
                        sessionElapsedSeconds: self.menuBarState.sessionElapsedSeconds,
                        bufferedSeconds: bufferedSeconds,
                        bufferMemoryBytes: self.menuBarState.bufferMemoryBytes,
                        bufferMemoryFormatted: self.menuBarState.formattedBufferMemory
                    )
                    self.companionServer.broadcastTelemetryTick(tick)
                }

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
                let longBufferStats = self.longBufferAppendPump.snapshot()
                bufferMonitorLogger.debug("RingBuffer | Video: \(videoDuration, format: .fixed(precision: 1))s \(videoMemory / (1024 * 1024))MB keyframes=\(videoKeyframes) samples=\(videoSamples) | Dual1: \(dualDisplay1Duration, format: .fixed(precision: 1))s \(dualDisplay1Memory / (1024 * 1024))MB | Dual2: \(dualDisplay2Duration, format: .fixed(precision: 1))s \(dualDisplay2Memory / (1024 * 1024))MB | SystemAudio: \(audioSamples) samples \(audioMemory / 1024)KB \(systemAudioDuration, format: .fixed(precision: 1))s | Mic: \(micSamples) samples \(micDuration, format: .fixed(precision: 1))s | LongBuffer pending=\(longBufferStats.pendingSamples) pumpDropped=\(longBufferStats.droppedSamples)")

                let totalRingMemory = videoMemory + dualDisplay1Memory + dualDisplay2Memory + audioMemory + micMemory
                self.menuBarState.setBufferMemoryBytes(totalRingMemory)

                let audioAge = captureStats.lastAudioSampleDate.map { String(format: "%.1fs ago", now.timeIntervalSince($0)) } ?? "never"
                bufferMonitorLogger.debug("SCKCallbacks | Video: total=\(captureStats.videoSampleCount) | Audio: total=\(captureStats.audioSampleCount) invalid=\(captureStats.invalidAudioSampleCount) last=\(audioAge, privacy: .public)")
            }
        }
    }

    /// Listens for system-wide memory pressure for the life of the app.
    ///
    /// Each ring buffer enforces its own share of the memory cap; this covers
    /// the case the cap cannot see, where the rest of the system has run out.
    /// macOS reports that directly. (An earlier check compared physical memory
    /// with this process's own footprint, which only ever read as low once the
    /// app itself held nearly all the RAM in the machine.)
    func setupMemoryPressureObserver() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.memoryPressureSource else { return }
                let event = source.data
                let level: MemoryPressureLevel
                if event.contains(.critical) {
                    level = .critical
                } else if event.contains(.warning) {
                    level = .warning
                } else {
                    level = .normal
                }
                self.handleMemoryPressure(level)
            }
        }
        memoryPressureSource = source
        source.resume()
    }

    func handleMemoryPressure(_ level: MemoryPressureLevel) {
        guard level != memoryPressureLevel else { return }
        let previous = memoryPressureLevel
        memoryPressureLevel = level

        let configured = AppSettings.bufferDurationSeconds
        let before = MemoryPressurePolicy.replaySeconds(configured: configured, level: previous)
        let after = MemoryPressurePolicy.replaySeconds(configured: configured, level: level)
        guard before != after else { return }

        let heldBefore = videoRingBuffer.currentMemoryBytes
            + dualDisplay1VideoRingBuffer.currentMemoryBytes
            + dualDisplay2VideoRingBuffer.currentMemoryBytes
            + systemAudioRingBuffer.currentMemoryBytes
            + micAudioRingBuffer.currentMemoryBytes
        // Applies the shorter (or restored) window and trims to it right away.
        syncBufferDurationToSettings()
        let heldAfter = videoRingBuffer.currentMemoryBytes
            + dualDisplay1VideoRingBuffer.currentMemoryBytes
            + dualDisplay2VideoRingBuffer.currentMemoryBytes
            + systemAudioRingBuffer.currentMemoryBytes
            + micAudioRingBuffer.currentMemoryBytes

        if level == .critical {
            let freedMB = max(0, heldBefore - heldAfter) / (1024 * 1024)
            bufferMonitorLogger.warning("Critical memory pressure: replay buffer held to \(after, privacy: .public)s (from \(configured, privacy: .public)s), freed \(freedMB, privacy: .public)MB")
        } else {
            bufferMonitorLogger.info("Memory pressure eased: replay buffer back to \(after, privacy: .public)s")
        }
    }
}
