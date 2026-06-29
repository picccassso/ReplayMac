import Darwin.Mach
import Foundation

import UI

@MainActor
extension AppDelegate {
    func syncMemoryCapsToSettings() {
        let dualMode = AppSettings.captureMode == CaptureMode.dualSideBySide.rawValue
        let caps = AppSettings.ringBufferMemoryCaps(
            isDualMode: dualMode,
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

    func startMonitoring() {
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
                print("RingBuffer | Video: \(String(format: "%.1f", videoDuration))s \(videoMemory / (1024 * 1024))MB keyframes=\(videoKeyframes) samples=\(videoSamples) | Dual1: \(String(format: "%.1f", dualDisplay1Duration))s \(dualDisplay1Memory / (1024 * 1024))MB | Dual2: \(String(format: "%.1f", dualDisplay2Duration))s \(dualDisplay2Memory / (1024 * 1024))MB | SystemAudio: \(audioSamples) samples \(audioMemory / 1024)KB \(String(format: "%.1f", systemAudioDuration))s | Mic: \(micSamples) samples \(String(format: "%.1f", micDuration))s | LongBuffer pending=\(longBufferStats.pendingSamples) pumpDropped=\(longBufferStats.droppedSamples)")

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

    func enforceMemoryBudgets(
        totalRingMemory: Int,
        dualDisplay1Memory: Int,
        dualDisplay2Memory: Int,
        systemAudioMemory: Int,
        micAudioMemory: Int
    ) {
        _ = totalRingMemory
        _ = dualDisplay1Memory
        _ = dualDisplay2Memory
        _ = systemAudioMemory
        _ = micAudioMemory

        // Per-buffer memory caps are enforced inside each ring buffer via setMemoryCap().
        // Keep this hook for system-wide memory pressure trimming only.

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

    static func estimatedAvailableMemoryBytes() -> UInt64? {
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
