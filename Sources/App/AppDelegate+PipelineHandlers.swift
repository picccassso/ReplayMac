@preconcurrency import CoreMedia

import Audio
import Capture
import Encode
import RingBuffer
import Save
import UI

func replayMacVideoEncodeHandler(_ encoder: VideoEncoder) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        encoder.encode(sampleBuffer: sampleBuffer)
    }
}

func replayMacPrimaryFrameCompositorHandler(_ frameCompositor: FrameCompositor) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        frameCompositor.pushPrimaryFrame(sampleBuffer)
    }
}

func replayMacSecondaryFrameCompositorHandler(_ frameCompositor: FrameCompositor) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        frameCompositor.pushSecondaryFrame(sampleBuffer)
    }
}

func replayMacSystemAudioProcessHandler(_ systemAudioCapture: SystemAudioCapture) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        if AppSettings.captureSystemAudio {
            systemAudioCapture.process(sampleBuffer: sampleBuffer)
        }
    }
}

func replayMacPerAppAudioHandler(_ systemAudioCapture: SystemAudioCapture) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        systemAudioCapture.process(sampleBuffer: sampleBuffer)
    }
}

func replayMacPrimaryVideoOutputHandler(
    videoRingBuffer: VideoRingBuffer,
    longBufferAppendPump: LongBufferAppendPump
) -> VideoEncoder.OutputHandler {
    { sampleBuffer in
        videoRingBuffer.append(encodedSample: sampleBuffer)
        longBufferAppendPump.enqueueVideo(LongBufferSample(sampleBuffer))
    }
}

func replayMacDualVideoOutputHandler(_ videoRingBuffer: VideoRingBuffer) -> VideoEncoder.OutputHandler {
    { sampleBuffer in
        videoRingBuffer.append(encodedSample: sampleBuffer)
    }
}

func replayMacFrameCompositorOutputHandler(_ videoEncoder: VideoEncoder) -> FrameCompositor.OutputHandler {
    replayMacVideoEncodeHandler(videoEncoder)
}

func replayMacAudioEncodeHandler(_ audioEncoder: AudioEncoder) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        audioEncoder.encode(sampleBuffer: sampleBuffer)
    }
}

func replayMacSystemAudioOutputHandler(
    systemAudioRingBuffer: AudioRingBuffer,
    longBufferAppendPump: LongBufferAppendPump
) -> AudioEncoder.OutputHandler {
    { sampleBuffer in
        systemAudioRingBuffer.append(sampleBuffer)
        longBufferAppendPump.enqueueSystemAudio(LongBufferSample(sampleBuffer))
    }
}

func replayMacMicrophoneOutputHandler(
    micAudioRingBuffer: AudioRingBuffer,
    longBufferAppendPump: LongBufferAppendPump
) -> AudioEncoder.OutputHandler {
    { sampleBuffer in
        micAudioRingBuffer.append(sampleBuffer)
        longBufferAppendPump.enqueueMicrophone(LongBufferSample(sampleBuffer))
    }
}
