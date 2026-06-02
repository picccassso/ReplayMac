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

    private init() {}

    public func recordSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        record(sampleBuffer, source: .systemAudio)
    }

    public func recordMicrophone(_ sampleBuffer: CMSampleBuffer) {
        record(sampleBuffer, source: .microphone)
    }

    public func snapshot() -> AudioLevelSnapshot {
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let systemAudio = displayedLevel(for: systemAudio, now: now)
        let microphone = displayedLevel(for: microphone, now: now)
        lock.unlock()

        return AudioLevelSnapshot(systemAudio: systemAudio, microphone: microphone)
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

    private func record(_ sampleBuffer: CMSampleBuffer, source: Source) {
        guard let level = Self.normalizedLevel(for: sampleBuffer) else {
            return
        }

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

    private static func normalizedLevel(for sampleBuffer: CMSampleBuffer) -> Double? {
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

        let rms = sqrt(sumOfSquares / Double(floatCount))
        guard rms.isFinite, rms > 0 else {
            return 0
        }

        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 60))
    }

    private enum Source {
        case systemAudio
        case microphone
    }
}
