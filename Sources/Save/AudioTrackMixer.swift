import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia

enum AudioTrackMixError: Error {
    case noAudioSamples
    case unsupportedFormat
    case cannotCreateFormatDescription(OSStatus)
    case cannotCreateBlockBuffer(OSStatus)
    case cannotCopyAudioData(OSStatus)
    case cannotCreateSampleBuffer(OSStatus)
}

enum AudioTrackMixer {
    static func merge(
        systemAudioSamples: [CMSampleBuffer],
        micAudioSamples: [CMSampleBuffer]
    ) throws -> [CMSampleBuffer] {
        guard !systemAudioSamples.isEmpty || !micAudioSamples.isEmpty else {
            throw AudioTrackMixError.noAudioSamples
        }

        let systemTrack = try PCMTrack(samples: systemAudioSamples)
        let micTrack = try PCMTrack(samples: micAudioSamples)
        guard let sampleRate = systemTrack.sampleRate ?? micTrack.sampleRate else {
            throw AudioTrackMixError.unsupportedFormat
        }

        if let systemRate = systemTrack.sampleRate, systemRate != sampleRate {
            throw AudioTrackMixError.unsupportedFormat
        }
        if let micRate = micTrack.sampleRate, micRate != sampleRate {
            throw AudioTrackMixError.unsupportedFormat
        }

        let outputChannels = max(systemTrack.channelCount, micTrack.channelCount, 1)
        let formatDescription = try makeFormatDescription(sampleRate: sampleRate, channels: outputChannels)
        let chunks = (systemTrack.chunks + micTrack.chunks)
        guard let firstFrame = chunks.map(\.startFrame).min(),
              let lastFrame = chunks.map(\.endFrame).max(),
              lastFrame > firstFrame else {
            throw AudioTrackMixError.noAudioSamples
        }

        let maxFramesPerBuffer = 2_048
        var outputBuffers: [CMSampleBuffer] = []
        var currentFrame = firstFrame
        var systemIndex = 0
        var micIndex = 0

        while currentFrame < lastFrame {
            let frameCount = min(maxFramesPerBuffer, Int(lastFrame - currentFrame))
            var mixed = [Float](repeating: 0, count: frameCount * outputChannels)

            mix(
                track: systemTrack,
                cursor: &systemIndex,
                output: &mixed,
                outputStartFrame: currentFrame,
                outputFrameCount: frameCount,
                outputChannels: outputChannels
            )
            mix(
                track: micTrack,
                cursor: &micIndex,
                output: &mixed,
                outputStartFrame: currentFrame,
                outputFrameCount: frameCount,
                outputChannels: outputChannels
            )

            for index in mixed.indices {
                mixed[index] = min(max(mixed[index], -1), 1)
            }

            outputBuffers.append(
                try makeSampleBuffer(
                    samples: mixed,
                    frameCount: frameCount,
                    sampleRate: sampleRate,
                    startFrame: currentFrame,
                    formatDescription: formatDescription
                )
            )
            currentFrame += Int64(frameCount)
        }

        return outputBuffers
    }

    private static func mix(
        track: PCMTrack,
        cursor: inout Int,
        output: inout [Float],
        outputStartFrame: Int64,
        outputFrameCount: Int,
        outputChannels: Int
    ) {
        guard !track.chunks.isEmpty else { return }

        let outputEndFrame = outputStartFrame + Int64(outputFrameCount)
        while cursor < track.chunks.count, track.chunks[cursor].endFrame <= outputStartFrame {
            cursor += 1
        }

        var index = cursor
        while index < track.chunks.count {
            let chunk = track.chunks[index]
            guard chunk.startFrame < outputEndFrame else { break }

            let overlapStart = max(outputStartFrame, chunk.startFrame)
            let overlapEnd = min(outputEndFrame, chunk.endFrame)
            if overlapEnd > overlapStart {
                let frameCount = Int(overlapEnd - overlapStart)
                let sourceOffset = Int(overlapStart - chunk.startFrame)
                let outputOffset = Int(overlapStart - outputStartFrame)

                for frame in 0..<frameCount {
                    let sourceFrame = sourceOffset + frame
                    let outputFrame = outputOffset + frame
                    for channel in 0..<outputChannels {
                        let sourceChannel = chunk.channels == 1
                            ? 0
                            : min(channel, chunk.channels - 1)
                        output[(outputFrame * outputChannels) + channel] +=
                            chunk.samples[(sourceFrame * chunk.channels) + sourceChannel]
                    }
                }
            }

            index += 1
        }
    }

    private static func makeFormatDescription(sampleRate: Int32, channels: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw AudioTrackMixError.cannotCreateFormatDescription(status)
        }
        return formatDescription
    }

    private static func makeSampleBuffer(
        samples: [Float],
        frameCount: Int,
        sampleRate: Int32,
        startFrame: Int64,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw AudioTrackMixError.cannotCreateBlockBuffer(status)
        }

        status = samples.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return OSStatus(kCMBlockBufferBadPointerParameterErr)
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == noErr else {
            throw AudioTrackMixError.cannotCopyAudioData(status)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: startFrame, timescale: CMTimeScale(sampleRate)),
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
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw AudioTrackMixError.cannotCreateSampleBuffer(status)
        }
        return sampleBuffer
    }
}

private struct PCMTrack {
    let chunks: [PCMChunk]
    let sampleRate: Int32?
    let channelCount: Int

    init(samples: [CMSampleBuffer]) throws {
        guard !samples.isEmpty else {
            chunks = []
            sampleRate = nil
            channelCount = 0
            return
        }

        var sampleRate: Int32?
        var maxChannelCount = 0
        var chunks: [PCMChunk] = []

        for sample in samples {
            guard let formatDescription = sample.formatDescription,
                  let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
                throw AudioTrackMixError.unsupportedFormat
            }
            let asbd = asbdPointer.pointee
            let channels = Int(asbd.mChannelsPerFrame)
            let currentSampleRate = Int32(asbd.mSampleRate.rounded())
            guard channels > 0,
                  currentSampleRate > 0,
                  asbd.mFormatID == kAudioFormatLinearPCM,
                  asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  asbd.mBitsPerChannel == 32 else {
                throw AudioTrackMixError.unsupportedFormat
            }

            if let sampleRate, sampleRate != currentSampleRate {
                throw AudioTrackMixError.unsupportedFormat
            }
            sampleRate = currentSampleRate
            maxChannelCount = max(maxChannelCount, channels)

            guard let dataBuffer = sample.dataBuffer else {
                throw AudioTrackMixError.unsupportedFormat
            }

            let frameCount = CMSampleBufferGetNumSamples(sample)
            let byteCount = frameCount * channels * MemoryLayout<Float>.size
            guard byteCount > 0 else { continue }

            var bytes = [UInt8](repeating: 0, count: byteCount)
            let status = bytes.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return OSStatus(kCMBlockBufferBadPointerParameterErr)
                }
                return CMBlockBufferCopyDataBytes(
                    dataBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: baseAddress
                )
            }
            guard status == noErr else {
                throw AudioTrackMixError.cannotCopyAudioData(status)
            }

            let floats = bytes.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Float.self))
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isValid else { continue }
            let startFrame = Int64((pts.seconds * Double(currentSampleRate)).rounded())
            chunks.append(
                PCMChunk(
                    startFrame: startFrame,
                    frameCount: frameCount,
                    channels: channels,
                    samples: floats
                )
            )
        }

        self.chunks = chunks.sorted { $0.startFrame < $1.startFrame }
        self.sampleRate = sampleRate
        channelCount = maxChannelCount
    }
}

private struct PCMChunk {
    let startFrame: Int64
    let frameCount: Int
    let channels: Int
    let samples: [Float]

    var endFrame: Int64 {
        startFrame + Int64(frameCount)
    }
}
