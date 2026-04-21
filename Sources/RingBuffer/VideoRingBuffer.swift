import Foundation
@preconcurrency import CoreMedia
import DequeModule

public final class VideoRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var deque = Deque<CMSampleBuffer>()
    private var keyframeIndices: [Int] = []
    private var _currentMemoryBytes: Int = 0

    public let timeCap: TimeInterval
    public let memoryCap: Int

    public init(timeCap: TimeInterval = 30.0, memoryCap: Int = 1_500_000_000) {
        self.timeCap = timeCap
        self.memoryCap = memoryCap
    }

    public func append(encodedSample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        deque.append(encodedSample)
        _currentMemoryBytes += CMSampleBufferGetTotalSampleSize(encodedSample)

        if isKeyframe(encodedSample) {
            keyframeIndices.append(deque.count - 1)
        }

        evictIfNeeded()
    }

    public func samples(last seconds: TimeInterval) -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }

        guard !deque.isEmpty else { return [] }
        guard !keyframeIndices.isEmpty else { return Array(deque) }

        let newestPTS = presentationTimeStamp(of: deque.last!)
        let cutoffPTS = newestPTS - seconds

        var resultIndex = 0
        if let firstKeyframeIndex = keyframeIndices.first {
            let firstPTS = presentationTimeStamp(of: deque[firstKeyframeIndex])
            if firstPTS > cutoffPTS {
                resultIndex = firstKeyframeIndex
            } else {
                var low = 0
                var high = keyframeIndices.count - 1
                var bestIndex = firstKeyframeIndex
                while low <= high {
                    let mid = (low + high) / 2
                    let idx = keyframeIndices[mid]
                    let pts = presentationTimeStamp(of: deque[idx])
                    if pts <= cutoffPTS {
                        bestIndex = idx
                        low = mid + 1
                    } else {
                        high = mid - 1
                    }
                }
                resultIndex = bestIndex
            }
        }

        return Array(deque[resultIndex...])
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        deque.removeAll()
        keyframeIndices.removeAll()
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

    public var keyframeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return keyframeIndices.count
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
            guard keyframeIndices.count >= 2 else { break }
            evictOldestGOP()
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
            guard keyframeIndices.count >= 2 else { break }
            evictOldestGOP()
        }
        return max(0, startingBytes - _currentMemoryBytes)
    }

    private func evictIfNeeded() {
        while true {
            guard let oldest = deque.first, let newest = deque.last else { break }
            let duration = presentationTimeStamp(of: newest) - presentationTimeStamp(of: oldest)
            if duration > timeCap {
                evictOldestGOP()
            } else {
                break
            }
        }

        while _currentMemoryBytes > memoryCap {
            guard deque.count > 1 else { break }
            evictOldestGOP()
        }
    }

    private func evictOldestGOP() {
        guard keyframeIndices.count >= 2 else { return }
        let secondKeyframeIndex = keyframeIndices[1]

        var bytesToRemove = 0
        for i in 0..<secondKeyframeIndex {
            bytesToRemove += CMSampleBufferGetTotalSampleSize(deque[i])
        }
        _currentMemoryBytes = max(0, _currentMemoryBytes - bytesToRemove)

        deque.removeFirst(secondKeyframeIndex)
        keyframeIndices.removeFirst()
        for i in keyframeIndices.indices {
            keyframeIndices[i] -= secondKeyframeIndex
        }
    }

    private func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachment = attachments.first else {
            return true
        }
        if let notSync = attachment[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            return !notSync
        }
        return true
    }

    private func presentationTimeStamp(of sampleBuffer: CMSampleBuffer) -> Double {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return pts.isValid ? pts.seconds : 0
    }
}
