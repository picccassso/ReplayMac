import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreAudio
import os.log

public enum MicCaptureError: Error {
    case cannotCreateTargetFormat
    case cannotCreateFormatDescription(OSStatus)
    case engineStartFailed(Error)
    case deviceNotFound
    case cannotSetInputDevice(OSStatus)
    case invalidInputFormat
    case cannotCreateConverter
}

/// Captures microphone audio via AVAudioEngine and emits CMSampleBuffers
/// with PTS aligned to the host-time clock (same clock SCK uses for video).
///
/// SCK's `captureMicrophone` output is unreliable on macOS 15 — it delivers
/// a burst of samples then stops — so we use AVAudioEngine instead.
///
/// AVAudioEngine stops itself and invalidates its taps whenever the input
/// hardware is reconfigured — a default-device change, a sample-rate change,
/// or Bluetooth headphones flipping into HFP mode when a call starts. Joining
/// a Discord or Zoom call does all three, so the engine is rebuilt in response
/// to `AVAudioEngineConfigurationChange` and by a stall watchdog behind it.
public final class MicCapture: @unchecked Sendable {
    /// A timeline discontinuity larger than this re-anchors the mic clock.
    /// Comfortably above per-buffer host-time jitter (buffers arrive every
    /// ~21ms), and far below the gap a device change produces.
    private static let resyncThresholdSeconds = 0.1

    /// Restart attempts for a single configuration change. A device that has
    /// just changed is often briefly unavailable, so the first try can fail.
    private static let maximumRestartAttempts = 5

    /// Consecutive watchdog rebuilds allowed without a single sample arriving
    /// in between. A device that starts cleanly and stays silent — an unplugged
    /// USB mic whose endpoint still enumerates — would otherwise be rebuilt on
    /// every watchdog tick for the rest of the capture session. The counter
    /// clears the moment real audio arrives, so an intermittent device still
    /// gets recovered indefinitely.
    private static let maximumStallRecoveries = 3

    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "com.replaycap.microphone.processing", qos: .userInitiated)
    private let restartQueue = DispatchQueue(label: "com.replaycap.microphone.restart", qos: .userInitiated)
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.replaycap", category: "MicCapture")
    private var handler: ((CMSampleBuffer) -> Void)?
    private var timeline = MicrophoneTimeline(resyncThresholdSeconds: MicCapture.resyncThresholdSeconds)

    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var outputFormatDescription: CMAudioFormatDescription?
    private var isRunning = false
    private var captureGeneration = 0
    private var volume: Double = 1.0

    /// The device the caller asked for, retained so a restart can re-bind it.
    private var requestedDeviceID: String?

    /// Fixed for the lifetime of a capture run. The downstream asset-writer
    /// input is created once per segment and cannot accept a source channel
    /// count that changes mid-stream, so a restart converts back to the count
    /// negotiated at the original start.
    private var pinnedChannelCount: AVAudioChannelCount?

    private var configurationObserver: NSObjectProtocol?

    /// When the last real sample was delivered. Never set by a restart — a
    /// rebuilt engine that delivers nothing must not look healthy.
    private var lastSampleUptime: TimeInterval?

    /// When the engine last came up, which is what gives a fresh or rebuilt
    /// engine its grace period before the watchdog judges it.
    private var engineReadyUptime: TimeInterval?

    private var stallRecoveryAttempts = 0
    private var hasReportedStallGiveUp = false
    private var isRestarting = false

    /// Invalidates in-flight restart retries. `stop` and `start` bump it so a
    /// retry queued against a previous run cannot tear down a later engine.
    private var restartEpoch = 0

    public init() {}

    public func setHandler(_ handler: @escaping (CMSampleBuffer) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    public func setVolume(_ volume: Double) {
        lock.lock()
        self.volume = volume
        lock.unlock()
    }

    /// Age of the most recently delivered sample, or nil if none has arrived
    /// since `start`.
    public func secondsSinceLastSample() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastSampleUptime else { return nil }
        return max(0, ProcessInfo.processInfo.systemUptime - lastSampleUptime)
    }

    public func start(deviceID: String? = nil) throws {
        lock.lock()
        requestedDeviceID = deviceID
        pinnedChannelCount = nil
        // Retire any retry still queued against a previous run.
        restartEpoch += 1
        isRestarting = false
        stallRecoveryAttempts = 0
        hasReportedStallGiveUp = false
        lock.unlock()

        try configureAndStartEngine(deviceID: deviceID, isRestart: false)

        lock.lock()
        isRunning = true
        engineReadyUptime = ProcessInfo.processInfo.systemUptime
        lastSampleUptime = nil
        lock.unlock()

        installConfigurationChangeObserver()
    }

    public func stop() {
        AudioLevelMonitor.shared.resetMicrophone()
        removeConfigurationChangeObserver()

        lock.lock()
        let wasRunning = isRunning
        isRunning = false
        // Always retire in-flight retries, even on a stop that finds nothing
        // running: a failed restart may still have one queued.
        restartEpoch += 1
        isRestarting = false
        stallRecoveryAttempts = 0
        hasReportedStallGiveUp = false
        lock.unlock()
        guard wasRunning else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        captureGeneration += 1
        timeline.reset()
        lastSampleUptime = nil
        engineReadyUptime = nil
        requestedDeviceID = nil
        pinnedChannelCount = nil
        converter = nil
        outputFormat = nil
        outputFormatDescription = nil
        lock.unlock()
    }

    /// Rebuilds the engine if no sample has arrived for `timeout`. Called by
    /// the capture watchdog; a no-op when the mic is healthy or stopped.
    ///
    /// `isSessionActive` mirrors the video watchdog's gate: a locked screen or
    /// sleeping display is not evidence of a broken microphone, and rebuilding
    /// the engine there would churn for no benefit.
    @discardableResult
    public func restartIfStalled(timeout: TimeInterval, isSessionActive: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let running = isRunning
        // A rebuilt engine is judged from when it came up; a working one from
        // its last real sample. Whichever is later is the freshest evidence
        // that the microphone is alive.
        let reference = max(lastSampleUptime ?? 0, engineReadyUptime ?? 0)
        let attempts = stallRecoveryAttempts
        let alreadyReported = hasReportedStallGiveUp
        lock.unlock()

        let decision = MicrophoneStallPolicy.decide(
            isRunning: running,
            isSessionActive: isSessionActive,
            now: now,
            referenceUptime: reference,
            timeout: timeout,
            recoveriesUsed: attempts,
            maximumRecoveries: Self.maximumStallRecoveries
        )

        switch decision {
        case .wait:
            return false
        case .giveUp:
            if !alreadyReported {
                lock.lock()
                hasReportedStallGiveUp = true
                lock.unlock()
                logger.error(
                    "Microphone still silent after \(Self.maximumStallRecoveries, privacy: .public) rebuilds; leaving it alone until the device or settings change"
                )
            }
            return false
        case .rebuild:
            break
        }

        // A configuration-change rebuild already in flight does its own
        // retrying, so it must not spend the watchdog's budget.
        guard scheduleRestart() else { return false }

        lock.lock()
        stallRecoveryAttempts += 1
        let attempt = stallRecoveryAttempts
        lock.unlock()

        logger.error(
            "Microphone delivered nothing for \(timeout, privacy: .public)s; rebuilding engine (recovery \(attempt, privacy: .public) of \(Self.maximumStallRecoveries, privacy: .public))"
        )
        return true
    }

    // MARK: - Engine lifecycle

    private func configureAndStartEngine(deviceID: String?, isRestart: Bool) throws {
        if let deviceID, !deviceID.isEmpty {
            try setInputDevice(uid: deviceID)
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // A device caught mid-transition reports a zero-rate format. Starting on
        // it yields an engine that runs and never delivers a sample, so fail
        // loudly instead and let the caller surface it.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicCaptureError.invalidInputFormat
        }

        lock.lock()
        let pinned = pinnedChannelCount
        lock.unlock()

        let channelCount = pinned ?? max(1, inputFormat.channelCount)
        var target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: channelCount,
            interleaved: true
        )
        var newConverter = target.flatMap { AVAudioConverter(from: inputFormat, to: $0) }

        // The pinned channel count is preferred, but a device that cannot be
        // converted to it must not take the mic down entirely. The save-time
        // mixer tolerates a mic track whose channel count changes between
        // chunks; the long-buffer writer is the only consumer that does not.
        if newConverter == nil, pinned != nil, pinned != inputFormat.channelCount {
            logger.error(
                "Microphone cannot convert \(inputFormat.channelCount, privacy: .public)ch to pinned \(pinned!, privacy: .public)ch; following the device instead"
            )
            let fallbackChannels = max(1, inputFormat.channelCount)
            target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: fallbackChannels,
                interleaved: true
            )
            newConverter = target.flatMap { AVAudioConverter(from: inputFormat, to: $0) }
        }

        guard let target else {
            throw MicCaptureError.cannotCreateTargetFormat
        }
        guard let newConverter else {
            throw MicCaptureError.cannotCreateConverter
        }

        var asbd = target.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let formatDescription else {
            throw MicCaptureError.cannotCreateFormatDescription(fmtStatus)
        }

        lock.lock()
        converter = newConverter
        outputFormat = target
        outputFormatDescription = formatDescription
        if pinnedChannelCount == nil {
            pinnedChannelCount = target.channelCount
        }
        captureGeneration += 1
        let generation = captureGeneration
        lock.unlock()

        logger.info(
            "Microphone \(isRestart ? "restarted" : "started", privacy: .public) input=\(inputFormat.channelCount, privacy: .public)ch@\(Int(inputFormat.sampleRate), privacy: .public) output=\(target.channelCount, privacy: .public)ch@48000"
        )

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            guard let self, let copiedBuffer = Self.copyPCMBuffer(buffer) else { return }
            self.processingQueue.async { [weak self] in
                guard let self, self.shouldProcessTapBuffer(generation: generation) else { return }
                self.handleInput(buffer: copiedBuffer, time: time)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicCaptureError.engineStartFailed(error)
        }
    }

    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        captureGeneration += 1
        lock.unlock()
    }

    // MARK: - Configuration change recovery

    private func installConfigurationChangeObserver() {
        removeConfigurationChangeObserver()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        lock.lock()
        configurationObserver = observer
        lock.unlock()
    }

    private func removeConfigurationChangeObserver() {
        lock.lock()
        let observer = configurationObserver
        configurationObserver = nil
        lock.unlock()
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
    }

    private func handleConfigurationChange() {
        logger.info("Audio engine configuration changed; rebuilding microphone capture")
        scheduleRestart()
    }

    /// Returns false when a rebuild is already in flight or the mic is stopped.
    @discardableResult
    private func scheduleRestart() -> Bool {
        lock.lock()
        guard isRunning, !isRestarting else {
            lock.unlock()
            return false
        }
        isRestarting = true
        let epoch = restartEpoch
        lock.unlock()

        restartQueue.async { [weak self] in
            self?.performRestart(attempt: 0, epoch: epoch)
        }
        return true
    }

    private func performRestart(attempt: Int, epoch: Int) {
        lock.lock()
        let running = isRunning
        let deviceID = requestedDeviceID
        let isCurrent = epoch == restartEpoch
        // Only the run that owns this epoch may clear the flag; a retired
        // retry must not unlatch a restart belonging to a later run.
        if !running || !isCurrent {
            if isCurrent {
                isRestarting = false
            }
            lock.unlock()
            return
        }
        lock.unlock()

        teardownEngine()

        do {
            try configureAndStartEngine(deviceID: deviceID, isRestart: true)
            lock.lock()
            // `stop` may have landed while the engine was being rebuilt; the
            // rebuilt engine has to come straight back down in that case.
            let superseded = !isRunning || epoch != restartEpoch
            if !superseded {
                // The rebuilt engine has not proved itself yet, so only the
                // grace clock moves — `lastSampleUptime` stays where it was
                // until real audio arrives.
                engineReadyUptime = ProcessInfo.processInfo.systemUptime
                isRestarting = false
            }
            lock.unlock()
            if superseded {
                teardownEngine()
            }
            return
        } catch {
            logger.error(
                "Microphone restart attempt \(attempt + 1, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }

        let nextAttempt = attempt + 1
        guard nextAttempt < Self.maximumRestartAttempts else {
            logger.error("Microphone restart gave up after \(Self.maximumRestartAttempts, privacy: .public) attempts")
            lock.lock()
            if epoch == restartEpoch {
                isRestarting = false
            }
            lock.unlock()
            return
        }

        // The device is often still settling right after the change.
        let delay = min(0.5 * pow(2, Double(attempt)), 4)
        restartQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performRestart(attempt: nextAttempt, epoch: epoch)
        }
    }

    private func shouldProcessTapBuffer(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning && captureGeneration == generation
    }

    private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        for index in source.indices {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else {
                continue
            }
            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }

        return copy
    }

    private func setInputDevice(uid: String) throws {
        try AudioDeviceLookup.applyInputDevice(uid: uid, to: engine)
    }

    private func handleInput(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock()
        let converter = self.converter
        let outputFormat = self.outputFormat
        lock.unlock()

        guard let converter, let outputFormat else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 512)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return
        }

        let inputState = AudioConversionInputState()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputState.didReturnInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.didReturnInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, outputBuffer.frameLength > 0 else { return }

        lock.lock()
        let currentVolume = volume
        lock.unlock()

        if currentVolume != 1.0 {
            let abl = UnsafeMutableAudioBufferListPointer(outputBuffer.mutableAudioBufferList)
            let volumeFloat = Float(currentVolume)
            for buffer in abl {
                guard let data = buffer.mData else { continue }
                let byteSize = Int(buffer.mDataByteSize)
                let floatCount = byteSize / MemoryLayout<Float>.size
                let floatPtr = data.assumingMemoryBound(to: Float.self)
                for i in 0..<floatCount {
                    floatPtr[i] *= volumeFloat
                }
            }
        }

        guard let sampleBuffer = makeSampleBuffer(from: outputBuffer, at: time) else { return }
        AudioLevelMonitor.shared.recordMicrophone(sampleBuffer)

        lock.lock()
        lastSampleUptime = ProcessInfo.processInfo.systemUptime
        // Real audio clears the watchdog's give-up budget, so an intermittent
        // device keeps earning recovery attempts for as long as it recovers.
        stallRecoveryAttempts = 0
        hasReportedStallGiveUp = false
        let h = handler
        lock.unlock()
        h?(sampleBuffer)
    }

    private func makeSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, at audioTime: AVAudioTime) -> CMSampleBuffer? {
        lock.lock()
        let formatDescription = outputFormatDescription
        lock.unlock()
        guard let formatDescription else { return nil }
        guard audioTime.isHostTimeValid else { return nil }

        let sampleRate = pcmBuffer.format.sampleRate
        let frameCount = CMItemCount(pcmBuffer.frameLength)
        let hostPTS = CMClockMakeHostTimeFromSystemUnits(audioTime.hostTime)

        lock.lock()
        let stamp = timeline.stamp(
            hostTime: hostPTS,
            frameCount: Int64(frameCount),
            sampleRate: sampleRate
        )
        lock.unlock()

        if let drift = stamp.reanchoredBySeconds {
            logger.info("Microphone timeline re-anchored across a \(drift, privacy: .public)s discontinuity")
        }
        let pts = stamp.presentationTime

        let abl = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        guard abl.count == 1, let dataPtr = abl[0].mData else { return nil }
        let totalBytes = Int(abl[0].mDataByteSize)

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }

        status = CMBlockBufferReplaceDataBytes(
            with: dataPtr,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: totalBytes
        )
        guard status == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}

private final class AudioConversionInputState: @unchecked Sendable {
    var didReturnInput = false
}
