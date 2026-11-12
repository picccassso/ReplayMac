import Foundation

public struct LongBufferAppendStats: Sendable {
    public let pendingSamples: Int
    public let droppedSamples: Int
}

public final class LongBufferAppendPump: @unchecked Sendable {
    private enum PendingSample {
        case video(LongBufferSample)
        case systemAudio(LongBufferSample)
        case microphone(LongBufferSample)
    }

    private let recorders: [LongBufferRecorder]
    private let queue = DispatchQueue(label: "com.replaycap.long-buffer.append-pump", qos: .userInitiated)
    private let maxPendingSamples: Int
    private var pendingSamples: [PendingSample] = []
    private var isDraining = false
    private var drainGeneration = 0
    private var droppedSamples = 0

    public init(recorder: LongBufferRecorder, maxPendingSamples: Int = 240) {
        self.recorders = [recorder]
        self.maxPendingSamples = max(1, maxPendingSamples)
    }

    public init(recorders: [LongBufferRecorder], maxPendingSamples: Int = 240) {
        self.recorders = recorders
        self.maxPendingSamples = max(1, maxPendingSamples)
    }

    public func enqueueVideo(_ sample: LongBufferSample) {
        enqueue(.video(sample))
    }

    public func enqueueSystemAudio(_ sample: LongBufferSample) {
        enqueue(.systemAudio(sample))
    }

    public func enqueueMicrophone(_ sample: LongBufferSample) {
        enqueue(.microphone(sample))
    }

    public func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSamples.removeAll(keepingCapacity: true)
            self.isDraining = false
            self.drainGeneration += 1
            self.droppedSamples = 0
        }
    }

    public func snapshot() -> LongBufferAppendStats {
        queue.sync {
            LongBufferAppendStats(
                pendingSamples: pendingSamples.count,
                droppedSamples: droppedSamples
            )
        }
    }

    /// Samples are only queued while a recorder is switched on. Extended
    /// replay and session recording are both off by default, and every
    /// encoded frame and audio buffer used to be queued, handed to a task and
    /// passed to each recorder just to be dropped there.
    private func enqueue(_ sample: PendingSample) {
        guard recorders.contains(where: \.acceptsSamples) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.pendingSamples.count >= self.maxPendingSamples {
                self.pendingSamples.removeFirst()
                self.droppedSamples += 1
            }

            self.pendingSamples.append(sample)
            self.startDrainIfNeeded()
        }
    }

    private func startDrainIfNeeded() {
        guard !isDraining else { return }
        guard !pendingSamples.isEmpty else { return }
        isDraining = true
        drainNext(generation: drainGeneration)
    }

    private func drainNext(generation: Int) {
        guard generation == drainGeneration else { return }
        guard !pendingSamples.isEmpty else {
            isDraining = false
            return
        }

        let sample = pendingSamples.removeFirst()
        let recorders = self.recorders
        Task { [weak self] in
            switch sample {
            case .video(let sample):
                for recorder in recorders {
                    await recorder.appendVideo(sample)
                }
            case .systemAudio(let sample):
                for recorder in recorders {
                    await recorder.appendSystemAudio(sample)
                }
            case .microphone(let sample):
                for recorder in recorders {
                    await recorder.appendMicrophone(sample)
                }
            }

            self?.queue.async { [weak self] in
                self?.drainNext(generation: generation)
            }
        }
    }
}
