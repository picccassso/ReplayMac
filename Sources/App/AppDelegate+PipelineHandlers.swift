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
    longBufferRecorder: LongBufferRecorder
) -> VideoEncoder.OutputHandler {
    { sampleBuffer in
        videoRingBuffer.append(encodedSample: sampleBuffer)
        let longBufferSample = LongBufferSample(sampleBuffer)
        Task {
            await longBufferRecorder.appendVideo(longBufferSample)
        }
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
    longBufferRecorder: LongBufferRecorder
) -> AudioEncoder.OutputHandler {
    { sampleBuffer in
        systemAudioRingBuffer.append(sampleBuffer)
        let longBufferSample = LongBufferSample(sampleBuffer)
        Task {
            await longBufferRecorder.appendSystemAudio(longBufferSample)
        }
    }
}

func replayMacMicrophoneOutputHandler(
    micAudioRingBuffer: AudioRingBuffer,
    longBufferRecorder: LongBufferRecorder
) -> AudioEncoder.OutputHandler {
    { sampleBuffer in
        micAudioRingBuffer.append(sampleBuffer)
        let longBufferSample = LongBufferSample(sampleBuffer)
        Task {
            await longBufferRecorder.appendMicrophone(longBufferSample)
        }
    }
}
