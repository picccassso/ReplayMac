import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia

public enum MicCaptureError: Error {
    case cannotCreateTargetFormat
    case cannotCreateFormatDescription(OSStatus)
    case engineStartFailed(Error)
}

/// Captures microphone audio via AVAudioEngine and emits CMSampleBuffers
/// with PTS aligned to the host-time clock (same clock SCK uses for video).
///
/// SCK's `captureMicrophone` output is unreliable on macOS 15 — it delivers
/// a burst of samples then stops — so we use AVAudioEngine instead.
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var handler: ((CMSampleBuffer) -> Void)?
    private var firstBufferHostTime: CMTime?
    private var totalOutputFrames: Int64 = 0

    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var outputFormatDescription: CMAudioFormatDescription?
    private var isRunning = false

    public init() {}

    public func setHandler(_ handler: @escaping (CMSampleBuffer) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    public func start() throws {
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

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            self?.handleInput(buffer: buffer, time: time)
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
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func handleInput(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let converter = converter, let outputFormat = outputFormat else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 512)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return
        }

        var didReturnInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didReturnInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didReturnInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, outputBuffer.frameLength > 0 else { return }

        guard let sampleBuffer = makeSampleBuffer(from: outputBuffer, at: time) else { return }

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

        // Anchor PTS to the first buffer's host time (SCK video clock domain),
        // then derive subsequent PTS by accumulating frame counts. This
        // produces bit-exact contiguous timestamps driven by the audio sample
        // clock — host-time stamping each buffer independently leaves
        // sub-millisecond gaps/overlaps at boundaries that AAC renders as
        // audible clicks at the ~10Hz buffer cadence.
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
