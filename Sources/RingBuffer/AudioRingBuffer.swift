import Foundation
@preconcurrency import CoreMedia
import DequeModule

/// Time-bounded ring buffer for encoded audio CMSampleBuffers.
/// Evicts oldest samples when duration or memory cap is exceeded.
public final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var deque = Deque<CMSampleBuffer>()
    private var _currentMemoryBytes: Int = 0

    public var timeCap: TimeInterval
    public let memoryCap: Int

    public init(timeCap: TimeInterval = 30.0, memoryCap: Int = 50_000_000) {
        self.timeCap = timeCap
        self.memoryCap = memoryCap
    }

    public func append(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        deque.append(sample)
        _currentMemoryBytes += dataSize(of: sample)
        evictIfNeeded()
    }

    public func samples(last seconds: TimeInterval) -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }

        guard !deque.isEmpty else { return [] }

        let newestPTS = presentationTimeStamp(of: deque.last!)
        let cutoffPTS = newestPTS - seconds

        let startIndex = deque.indices.first { index in
            presentationTimeStamp(of: deque[index]) >= cutoffPTS
        } ?? 0

        return Array(deque[startIndex...])
    }

    /// Returns samples whose PTS falls within the provided absolute range.
    /// This is used to align audio extraction to the selected video window.
    public func samples(between startPTS: Double, and endPTS: Double) -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }

        guard !deque.isEmpty else { return [] }
        guard endPTS >= startPTS else { return [] }

        var result: [CMSampleBuffer] = []
        result.reserveCapacity(deque.count)

        for sample in deque {
            let pts = presentationTimeStamp(of: sample)
            if pts < startPTS {
                continue
            }
            if pts > endPTS {
                break
            }
            result.append(sample)
        }

        return result
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        deque.removeAll()
        _currentMemoryBytes = 0
    }

    public var currentMemoryBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _currentMemoryBytes
    }

    public var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let oldest = deque.first, let newest = deque.last else { return 0 }
        let oldestPTS = presentationTimeStamp(of: oldest)
        let newestPTS = presentationTimeStamp(of: newest)
        return max(0, newestPTS - oldestPTS)
    }

    public var totalSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deque.count
    }

    @discardableResult
    public func evictToMemory(maxBytes: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let startingBytes = _currentMemoryBytes
        while _currentMemoryBytes > maxBytes, deque.count > 1 {
            evictOldest()
        }
        return max(0, startingBytes - _currentMemoryBytes)
    }

    @discardableResult
    public func trimToDuration(maxSeconds: TimeInterval) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let startingBytes = _currentMemoryBytes
        while true {
            guard let oldest = deque.first, let newest = deque.last else { break }
            let duration = presentationTimeStamp(of: newest) - presentationTimeStamp(of: oldest)
            guard duration > maxSeconds else { break }
            guard deque.count > 1 else { break }
            evictOldest()
        }
        return max(0, startingBytes - _currentMemoryBytes)
    }

    // MARK: - Private

    private func evictIfNeeded() {
        while true {
            guard let oldest = deque.first, let newest = deque.last else { break }
            let duration = presentationTimeStamp(of: newest) - presentationTimeStamp(of: oldest)
            if duration > timeCap {
                evictOldest()
            } else {
                break
            }
        }

        while _currentMemoryBytes > memoryCap {
            guard deque.count > 1 else { break }
            evictOldest()
        }
    }

    private func evictOldest() {
        guard let oldest = deque.first else { return }
        let size = dataSize(of: oldest)
        _currentMemoryBytes = max(0, _currentMemoryBytes - size)
        deque.removeFirst()
    }

    /// Returns the actual data size of a CMSampleBuffer.
    /// CMSampleBufferGetTotalSampleSize returns 0 for uncompressed audio (PCM),
    /// so we fall back to CMBlockBufferGetDataLength.
    private func dataSize(of sampleBuffer: CMSampleBuffer) -> Int {
        let totalSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        if totalSize > 0 { return totalSize }

        if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            return CMBlockBufferGetDataLength(dataBuffer)
        }
        return 0
    }

    private func presentationTimeStamp(of sampleBuffer: CMSampleBuffer) -> Double {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return pts.isValid ? pts.seconds : 0
    }
}
