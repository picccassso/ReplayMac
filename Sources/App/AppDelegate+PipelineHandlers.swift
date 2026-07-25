@preconcurrency import CoreMedia

import Audio
import Capture
import Encode
import RingBuffer
import Save
import UI

func replayCapVideoEncodeHandler(_ encoder: VideoEncoder) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        encoder.encode(sampleBuffer: sampleBuffer)
    }
}

func replayCapPrimaryFrameCompositorHandler(_ frameCompositor: FrameCompositor) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        frameCompositor.pushPrimaryFrame(sampleBuffer)
    }
}

func replayCapSecondaryFrameCompositorHandler(_ frameCompositor: FrameCompositor) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        frameCompositor.pushSecondaryFrame(sampleBuffer)
    }
}

func replayCapSystemAudioProcessHandler(_ systemAudioCapture: SystemAudioCapture) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        if AppSettings.captureSystemAudio {
            systemAudioCapture.process(sampleBuffer: sampleBuffer)
        }
    }
}

func replayCapPerAppAudioHandler(_ systemAudioCapture: SystemAudioCapture) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        systemAudioCapture.process(sampleBuffer: sampleBuffer)
    }
}

// The append pump is always fed: it drives the session recorder as well as the
// extended-replay recorder, and each recorder ignores samples while disabled.
// Only the ring buffers are gated, since those exist solely for replay saves.
func replayCapPrimaryVideoOutputHandler(
    videoRingBuffer: VideoRingBuffer,
    longBufferAppendPump: LongBufferAppendPump,
    replayBufferGate: ReplayBufferGate
) -> VideoEncoder.OutputHandler {
    { sampleBuffer in
        if replayBufferGate.isEnabled {
            videoRingBuffer.append(encodedSample: sampleBuffer)
        }
        longBufferAppendPump.enqueueVideo(LongBufferSample(sampleBuffer))
    }
}

func replayCapDualVideoOutputHandler(
    _ videoRingBuffer: VideoRingBuffer,
    replayBufferGate: ReplayBufferGate
) -> VideoEncoder.OutputHandler {
    { sampleBuffer in
        if replayBufferGate.isEnabled {
            videoRingBuffer.append(encodedSample: sampleBuffer)
        }
    }
}

func replayCapFrameCompositorOutputHandler(_ videoEncoder: VideoEncoder) -> FrameCompositor.OutputHandler {
    replayCapVideoEncodeHandler(videoEncoder)
}

func replayCapAudioEncodeHandler(_ audioEncoder: AudioEncoder) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        audioEncoder.encode(sampleBuffer: sampleBuffer)
    }
}

func replayCapSystemAudioOutputHandler(
    systemAudioRingBuffer: AudioRingBuffer,
    longBufferAppendPump: LongBufferAppendPump,
    replayBufferGate: ReplayBufferGate
) -> AudioEncoder.OutputHandler {
    { sampleBuffer in
        if replayBufferGate.isEnabled {
            systemAudioRingBuffer.append(sampleBuffer)
        }
        longBufferAppendPump.enqueueSystemAudio(LongBufferSample(sampleBuffer))
    }
}

func replayCapMicrophoneOutputHandler(
    micAudioRingBuffer: AudioRingBuffer,
    longBufferAppendPump: LongBufferAppendPump,
    replayBufferGate: ReplayBufferGate
) -> AudioEncoder.OutputHandler {
    { sampleBuffer in
        if replayBufferGate.isEnabled {
            micAudioRingBuffer.append(sampleBuffer)
        }
        longBufferAppendPump.enqueueMicrophone(LongBufferSample(sampleBuffer))
    }
}
