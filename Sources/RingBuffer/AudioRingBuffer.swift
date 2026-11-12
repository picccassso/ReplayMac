import Foundation
@preconcurrency import CoreMedia
import DequeModule

/// Time-bounded ring buffer for captured audio.
/// Evicts oldest samples when duration or memory cap is exceeded.
///
/// Capture delivers 32-bit float PCM, which is held here as 16-bit PCM: half
/// the memory for the same audio once it reaches the AAC track in a clip. Each
/// buffer keeps its own timing and format, and is handed back out as the
/// float buffer it came in as, so nothing downstream sees a different stream.
/// Anything that is not packed float PCM is stored untouched.
public final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var deque = Deque<StoredAudio>()
    private var _currentMemoryBytes: Int = 0

    // Caps are only touched under `lock`: the main actor updates them from
    // settings while capture threads read them during append/eviction.
    private var _timeCap: TimeInterval
    private var _memoryCap: Int
    private var _retentionFloor: (@Sendable () -> Double?)?

    /// Maximum buffered duration. Setting it does not evict on its own; the
    /// next append (or an explicit `trimToDuration`) applies the new cap.
    public var timeCap: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _timeCap
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _timeCap = newValue
        }
    }

    public var memoryCap: Int {
        lock.lock()
        defer { lock.unlock() }
        return _memoryCap
    }

    public init(timeCap: TimeInterval = 30.0, memoryCap: Int = 50_000_000) {
        self._timeCap = timeCap
        self._memoryCap = memoryCap
    }

    /// Oldest presentation time something else still needs audio for: the
    /// oldest buffered video frame. Time-based eviction never drops audio at
    /// or after it, so the audio buffer reaches back as far as any clip the
    /// video buffer can produce. Video only evicts whole keyframe groups and
    /// so routinely holds more than `timeCap`; audio trimmed to `timeCap` on
    /// its own left clips opening on silence. The memory cap still applies.
    ///
    /// Called under this buffer's lock, so it must not call back into it.
    public func setRetentionFloor(_ floor: (@Sendable () -> Double?)?) {
        lock.lock()
        defer { lock.unlock() }
        _retentionFloor = floor
    }

    /// Keeps this buffer's audio back to the oldest frame held by any of
    /// `videoBuffers` (empty buffers are ignored), the video a clip can be
    /// saved against.
    public func retainHistory(coveredBy videoBuffers: [VideoRingBuffer]) {
        setRetentionFloor {
            videoBuffers.compactMap(\.oldestPTS).min()
        }
    }

    public func setMemoryCap(_ bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        _memoryCap = max(bytes, 0)
        evictIfNeeded()
    }

    public func append(_ sample: CMSampleBuffer) {
        // Converted before taking the lock, so capture threads only ever wait
        // on each other for the append itself.
        let stored = StoredAudio(sample)

        lock.lock()
        defer { lock.unlock() }

        deque.append(stored)
        _currentMemoryBytes += stored.byteCount
        evictIfNeeded()
    }

    public func samples(last seconds: TimeInterval) -> [CMSampleBuffer] {
        let selected: [StoredAudio] = lock.withLock {
            guard let newest = deque.last else { return [] }
            let cutoffPTS = newest.pts - seconds
            let startIndex = deque.indices.first { deque[$0].pts >= cutoffPTS } ?? 0
            return Array(deque[startIndex...])
        }
        return selected.compactMap { $0.makeSampleBuffer() }
    }

    /// Returns samples whose PTS falls within the provided absolute range.
    /// This is used to align audio extraction to the selected video window.
    public func samples(between startPTS: Double, and endPTS: Double) -> [CMSampleBuffer] {
        guard endPTS >= startPTS else { return [] }

        var selected: [StoredAudio] = lock.withLock {
            // A full scan rather than stopping at the first sample past
            // `endPTS`: capture is meant to append in time order, but a stray
            // out-of-order buffer must not hide the samples after it.
            deque.filter { $0.pts >= startPTS && $0.pts <= endPTS }
        }
        selected.sort { $0.pts < $1.pts }

        // Turned back into float buffers outside the lock: a long window is
        // tens of thousands of buffers, and capture keeps appending meanwhile.
        return selected.compactMap { $0.makeSampleBuffer() }
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
        return max(0, newest.pts - oldest.pts)
    }

    public var totalSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deque.count
    }

    @discardableResult
    public func trimToDuration(maxSeconds: TimeInterval) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let startingBytes = _currentMemoryBytes
        while true {
            guard let oldest = deque.first, let newest = deque.last else { break }
            let duration = newest.pts - oldest.pts
            guard duration > maxSeconds else { break }
            guard deque.count > 1, oldestIsBelowRetentionFloor() else { break }
            evictOldest()
        }
        return max(0, startingBytes - _currentMemoryBytes)
    }

    // MARK: - Private

    private func evictIfNeeded() {
        while true {
            guard let oldest = deque.first, let newest = deque.last else { break }
            let duration = newest.pts - oldest.pts
            if duration > _timeCap, deque.count > 1, oldestIsBelowRetentionFloor() {
                evictOldest()
            } else {
                break
            }
        }

        while _currentMemoryBytes > _memoryCap {
            guard deque.count > 1 else { break }
            evictOldest()
        }
    }

    /// True when the oldest sample ends before the retention floor, so
    /// dropping it cannot cut into audio a clip may still need. The next
    /// sample's start stands in for the oldest one's end.
    private func oldestIsBelowRetentionFloor() -> Bool {
        guard let floor = _retentionFloor?() else { return true }
        guard deque.count > 1 else { return false }
        return deque[deque.index(after: deque.startIndex)].pts <= floor
    }

    private func evictOldest() {
        guard let oldest = deque.first else { return }
        _currentMemoryBytes = max(0, _currentMemoryBytes - oldest.byteCount)
        deque.removeFirst()
    }
}

/// One captured audio buffer as the ring buffer holds it.
private struct StoredAudio {
    private enum Payload {
        /// Float PCM held as 16-bit integers, with what is needed to rebuild
        /// the buffer it came from.
        case compact(samples: [Int16], format: CMFormatDescription, frameCount: CMItemCount, timing: CMSampleTimingInfo)
        /// Any other buffer, kept as it arrived.
        case original(CMSampleBuffer)
    }

    /// Full scale for the 16-bit samples. The same factor is used both ways,
    /// so full-scale float audio comes back as exactly full scale.
    private static let fullScale: Float = 32_767

    let pts: Double
    /// Bytes of audio this entry holds, which is what the memory cap counts.
    let byteCount: Int
    private let payload: Payload

    init(_ sample: CMSampleBuffer) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        pts = presentationTime.isValid ? presentationTime.seconds : 0

        if let compact = Self.compact(sample) {
            payload = compact.payload
            byteCount = compact.byteCount
        } else {
            payload = .original(sample)
            byteCount = Self.dataSize(of: sample)
        }
    }

    /// The buffer as it was captured. A compacted buffer is rebuilt with its
    /// original format, frame count and timing; nil only if Core Media cannot
    /// allocate it.
    func makeSampleBuffer() -> CMSampleBuffer? {
        switch payload {
        case .original(let sample):
            return sample
        case .compact(let samples, let format, let frameCount, let timing):
            let byteCount = samples.count * MemoryLayout<Float>.size
            var blockBuffer: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            ) == noErr, let blockBuffer else {
                return nil
            }

            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer
            ) == noErr, let dataPointer else {
                return nil
            }
            dataPointer.withMemoryRebound(to: Float.self, capacity: samples.count) { floats in
                for index in samples.indices {
                    floats[index] = Float(samples[index]) / Self.fullScale
                }
            }

            var timing = timing
            var sampleBuffer: CMSampleBuffer?
            guard CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: format,
                sampleCount: frameCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            ) == noErr else {
                return nil
            }
            return sampleBuffer
        }
    }

    /// The 16-bit form of `sample`, or nil when it is not a buffer this can
    /// rebuild exactly: packed native-endian 32-bit float PCM with a single
    /// timing entry and one float per channel per frame. The samples are
    /// converted in the order they sit in the buffer, so interleaved and
    /// planar audio both come back laid out as they went in.
    private static func compact(_ sample: CMSampleBuffer) -> (payload: Payload, byteCount: Int)? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              asbd.mBitsPerChannel == 32,
              asbd.mChannelsPerFrame > 0,
              let dataBuffer = CMSampleBufferGetDataBuffer(sample) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sample)
        let floatCount = frameCount * Int(asbd.mChannelsPerFrame)
        let byteCount = floatCount * MemoryLayout<Float>.size
        guard frameCount > 0, CMBlockBufferGetDataLength(dataBuffer) == byteCount else {
            return nil
        }

        var timingCount: CMItemCount = 0
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 1, arrayToFill: &timing, entriesNeededOut: &timingCount
        ) == noErr, timingCount == 1 else {
            return nil
        }

        var floats = [Float](repeating: 0, count: floatCount)
        let copyStatus = floats.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: byteCount, destination: destination.baseAddress!)
        }
        guard copyStatus == noErr else { return nil }

        let samples = [Int16](unsafeUninitializedCapacity: floatCount) { buffer, initializedCount in
            for index in 0..<floatCount {
                let scaled = (floats[index] * fullScale).rounded()
                // Anything past full scale is held at it; a non-finite sample
                // from a misbehaving device becomes silence, not a click.
                if scaled.isNaN {
                    buffer[index] = 0
                } else {
                    buffer[index] = Int16(max(-fullScale, min(fullScale, scaled)))
                }
            }
            initializedCount = floatCount
        }

        return (
            .compact(samples: samples, format: format, frameCount: frameCount, timing: timing),
            floatCount * MemoryLayout<Int16>.size
        )
    }

    /// Returns the actual data size of a CMSampleBuffer.
    /// CMSampleBufferGetTotalSampleSize returns 0 for uncompressed audio (PCM),
    /// so we fall back to CMBlockBufferGetDataLength.
    private static func dataSize(of sampleBuffer: CMSampleBuffer) -> Int {
        let totalSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        if totalSize > 0 { return totalSize }

        if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            return CMBlockBufferGetDataLength(dataBuffer)
        }
        return 0
    }
}
