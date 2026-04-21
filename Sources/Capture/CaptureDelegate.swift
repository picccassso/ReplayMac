import ScreenCaptureKit
import CoreMedia
import CoreVideo

public struct CaptureStats: Sendable {
    public let audioSampleCount: Int
    public let invalidAudioSampleCount: Int
    public let lastAudioSampleDate: Date?
}

public final class CaptureDelegate: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var videoHandler: ((CMSampleBuffer) -> Void)?
    private var audioHandler: ((CMSampleBuffer) -> Void)?
    private var frameCount = 0
    private var audioSampleCount = 0
    private var invalidAudioSampleCount = 0
    private var lastAudioSampleDate: Date?
    private var streamStoppedHandler: ((Error) -> Void)?

    public func snapshot() -> CaptureStats {
        lock.lock()
        defer { lock.unlock() }
        return CaptureStats(
            audioSampleCount: audioSampleCount,
            invalidAudioSampleCount: invalidAudioSampleCount,
            lastAudioSampleDate: lastAudioSampleDate
        )
    }

    public func setVideoHandler(_ handler: @escaping (CMSampleBuffer) -> Void) {
        lock.lock()
        videoHandler = handler
        lock.unlock()
    }

    public func setAudioHandler(_ handler: @escaping (CMSampleBuffer) -> Void) {
        lock.lock()
        audioHandler = handler
        lock.unlock()
    }

    public func setStreamStoppedHandler(_ handler: @escaping (Error) -> Void) {
        lock.lock()
        streamStoppedHandler = handler
        lock.unlock()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard sampleBuffer.isValid else { return }
            guard let status = frameStatus(of: sampleBuffer), status == .complete else { return }
            frameCount += 1
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                if frameCount % 300 == 0 {
                    print("Frame #\(frameCount) | PTS: \(pts.seconds) | Size: \(width)x\(height)")
                }
            }
            lock.lock()
            let handler = videoHandler
            lock.unlock()
            handler?(sampleBuffer)

        case .audio:
            let now = Date()
            if !sampleBuffer.isValid {
                lock.lock()
                invalidAudioSampleCount += 1
                lastAudioSampleDate = now
                let n = invalidAudioSampleCount
                lock.unlock()
                if n == 1 || n % 100 == 1 {
                    print("[AUDIO] invalid sample #\(n)")
                }
                return
            }
            lock.lock()
            audioSampleCount += 1
            lastAudioSampleDate = now
            let n = audioSampleCount
            let handler = audioHandler
            lock.unlock()
            if n == 1 || n == 2 || n == 5 || n == 10 || n % 100 == 1 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                print("[AUDIO] sample #\(n) PTS: \(pts.seconds)")
            }
            handler?(sampleBuffer)

        default:
            break
        }
    }

    func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else {
            return nil
        }
        guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int else {
            return nil
        }
        return SCFrameStatus(rawValue: statusRawValue)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        if nsError.code == -3821 {
            print("Warning: Stream stopped with error -3821")
        } else {
            print("Stream stopped with error: \(error)")
        }

        lock.lock()
        let handler = streamStoppedHandler
        lock.unlock()
        handler?(error)
    }
}
