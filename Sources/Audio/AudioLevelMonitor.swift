import Foundation
@preconcurrency import CoreMedia

public struct AudioLevelSnapshot: Sendable {
    public let systemAudio: Double
    public let microphone: Double
}

public final class AudioLevelMonitor: @unchecked Sendable {
    public static let shared = AudioLevelMonitor()

    private struct LevelState {
        var value: Double = 0
        var updatedAt: TimeInterval = 0
    }

    private let lock = NSLock()
    private var systemAudio = LevelState()
    private var microphone = LevelState()
    private var lastSnapshotAt: TimeInterval?

    private init() {}

    public func recordSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        record(sampleBuffer, source: .systemAudio)
    }

    public func recordMicrophone(_ sampleBuffer: CMSampleBuffer) {
        record(sampleBuffer, source: .microphone)
    }

    /// Feeds an already-normalized level (0...1). Used by the idle level
    /// preview, which measures audio without running the capture pipeline.
    public func recordSystemAudio(level: Double) {
        record(level: level, source: .systemAudio)
    }

    public func recordMicrophone(level: Double) {
        record(level: level, source: .microphone)
    }

    public func snapshot() -> AudioLevelSnapshot {
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        lastSnapshotAt = now
        let systemAudio = displayedLevel(for: systemAudio, now: now)
        let microphone = displayedLevel(for: microphone, now: now)
        lock.unlock()

        return AudioLevelSnapshot(systemAudio: systemAudio, microphone: microphone)
    }

    /// How long ago a meter last read the levels, or nil if none ever has.
    /// The idle level preview uses this as a liveness signal: no reader means
    /// nothing is displaying levels, so measuring them is wasted work.
    public func secondsSinceLastSnapshot() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastSnapshotAt else { return nil }
        return max(0, ProcessInfo.processInfo.systemUptime - lastSnapshotAt)
    }

    public func reset() {
        lock.lock()
        systemAudio = LevelState()
        microphone = LevelState()
        lock.unlock()
    }

    public func resetMicrophone() {
        lock.lock()
        microphone = LevelState()
        lock.unlock()
    }

    public func resetSystemAudio() {
        lock.lock()
        systemAudio = LevelState()
        lock.unlock()
    }

    private func record(_ sampleBuffer: CMSampleBuffer, source: Source) {
        guard let level = Self.normalizedLevel(for: sampleBuffer) else {
            return
        }
        record(level: level, source: source)
    }

    private func record(level: Double, source: Source) {
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        switch source {
        case .systemAudio:
            systemAudio.value = max(level, systemAudio.value * 0.72)
            systemAudio.updatedAt = now
        case .microphone:
            microphone.value = max(level, microphone.value * 0.72)
            microphone.updatedAt = now
        }
        lock.unlock()
    }

    private func displayedLevel(for state: LevelState, now: TimeInterval) -> Double {
        let age = max(0, now - state.updatedAt)
        guard age > 0.2 else {
            return state.value
        }
        guard age < 0.8 else {
            return 0
        }
        return state.value * (1 - ((age - 0.2) / 0.6))
    }

    /// Maps a linear RMS amplitude onto the 0...1 meter scale (-60 dBFS and
    /// below reads empty, 0 dBFS reads full).
    public static func normalizedLevel(forRootMeanSquare rms: Double) -> Double {
        guard rms.isFinite, rms > 0 else {
            return 0
        }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 60))
    }

    /// RMS amplitude of an interleaved float32 buffer, before any volume
    /// scaling the caller wants to apply.
    public static func rootMeanSquare(of sampleBuffer: CMSampleBuffer) -> Double? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let totalBytes = CMBlockBufferGetDataLength(dataBuffer)
        let floatCount = totalBytes / MemoryLayout<Float>.size
        guard floatCount > 0 else {
            return nil
        }

        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &dataPointer
        ) == noErr, let dataPointer else {
            return nil
        }

        let sumOfSquares = dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { samples in
            var sum = 0.0
            for index in 0..<floatCount {
                let sample = Double(samples[index])
                sum += sample * sample
            }
            return sum
        }

        return sqrt(sumOfSquares / Double(floatCount))
    }

    private static func normalizedLevel(for sampleBuffer: CMSampleBuffer) -> Double? {
        guard let rms = rootMeanSquare(of: sampleBuffer) else {
            return nil
        }
        return normalizedLevel(forRootMeanSquare: rms)
    }

    private enum Source {
        case systemAudio
        case microphone
    }
}
