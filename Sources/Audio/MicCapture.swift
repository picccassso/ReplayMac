import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreAudio

public enum MicCaptureError: Error {
    case cannotCreateTargetFormat
    case cannotCreateFormatDescription(OSStatus)
    case engineStartFailed(Error)
    case deviceNotFound
    case cannotSetInputDevice(OSStatus)
}

/// Captures microphone audio via AVAudioEngine and emits CMSampleBuffers
/// with PTS aligned to the host-time clock (same clock SCK uses for video).
///
/// SCK's `captureMicrophone` output is unreliable on macOS 15 — it delivers
/// a burst of samples then stops — so we use AVAudioEngine instead.
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "com.replaymac.microphone.processing", qos: .userInitiated)
    private let lock = NSLock()
    private var handler: ((CMSampleBuffer) -> Void)?
    private var firstBufferHostTime: CMTime?
    private var totalOutputFrames: Int64 = 0

    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var outputFormatDescription: CMAudioFormatDescription?
    private var isRunning = false
    private var captureGeneration = 0
    private var volume: Double = 1.0

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

    public func start(deviceID: String? = nil) throws {
        if let deviceID, !deviceID.isEmpty {
            try setInputDevice(uid: deviceID)
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        let channelCount = max(1, inputFormat.channelCount)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: channelCount,
            interleaved: true
        ) else {
            throw MicCaptureError.cannotCreateTargetFormat
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

        self.converter = AVAudioConverter(from: inputFormat, to: target)
        self.outputFormat = target
        self.outputFormatDescription = formatDescription

        print("[MIC] input format: \(inputFormat) channels=\(inputFormat.channelCount) sr=\(inputFormat.sampleRate)")
        print("[MIC] output format: 48kHz float32 interleaved \(channelCount)ch")
        if let deviceID, !deviceID.isEmpty {
            print("[MIC] selected device UID: \(deviceID)")
        }

        lock.lock()
        captureGeneration += 1
        let generation = captureGeneration
        lock.unlock()

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
        isRunning = true
    }

    public func stop() {
        AudioLevelMonitor.shared.resetMicrophone()
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        lock.lock()
        captureGeneration += 1
        firstBufferHostTime = nil
        totalOutputFrames = 0
        lock.unlock()
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
        guard let audioDeviceID = Self.audioDeviceID(forUID: uid) else {
            throw MicCaptureError.deviceNotFound
        }

        guard let inputUnit = engine.inputNode.audioUnit else {
            throw MicCaptureError.deviceNotFound
        }

        var deviceID = audioDeviceID
        let status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MicCaptureError.cannotSetInputDevice(status)
        }
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        for deviceID in deviceIDs {
            guard let deviceUID = deviceUID(for: deviceID), deviceUID == uid else {
                continue
            }
            return deviceID
        }

        return nil
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize) == noErr else {
            return nil
        }

        var uid: CFString?
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, pointer)
        }
        guard status == noErr, let uid else {
            return nil
        }

        return uid as String
    }

    private func handleInput(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let converter = converter, let outputFormat = outputFormat else { return }

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
        let h = handler
        lock.unlock()
        h?(sampleBuffer)
    }

    private func makeSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, at audioTime: AVAudioTime) -> CMSampleBuffer? {
        guard let formatDescription = outputFormatDescription else { return nil }
        guard audioTime.isHostTimeValid else { return nil }

        let sampleRate = pcmBuffer.format.sampleRate
        let frameCount = CMItemCount(pcmBuffer.frameLength)

        lock.lock()
        if firstBufferHostTime == nil {
            firstBufferHostTime = CMClockMakeHostTimeFromSystemUnits(audioTime.hostTime)
        }
        let anchor = firstBufferHostTime!
        let framesBefore = totalOutputFrames
        totalOutputFrames += Int64(frameCount)
        lock.unlock()

        let pts = CMTimeAdd(
            anchor,
            CMTime(value: framesBefore, timescale: CMTimeScale(sampleRate))
        )

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
