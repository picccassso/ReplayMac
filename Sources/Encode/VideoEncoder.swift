import Foundation
import VideoToolbox
@preconcurrency import CoreMedia
import CoreVideo

public enum VideoCodec {
    case hevc
    case h264
}

public enum VideoEncoderError: Error {
    case failedToCreateSession(OSStatus)
    case failedToSetProperties(OSStatus)
    case failedToPrepare(OSStatus)
}

private func compressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
}

public final class VideoEncoder: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (CMSampleBuffer) -> Void

    private var compressionSession: VTCompressionSession?
    private let stateLock = NSLock()
    private var _outputHandler: OutputHandler?

    public var outputHandler: OutputHandler? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _outputHandler
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _outputHandler = newValue
        }
    }

    public init() {}

    deinit {
        if compressionSession != nil {
            assertionFailure("VideoEncoder deallocated without calling stop()")
        }
    }

    public func start(
        width: Int,
        height: Int,
        fps: Int,
        codec: VideoCodec = .hevc,
        bitrate: Int = 20_000_000
    ) throws {
        stop()

        let codecType: CMVideoCodecType
        switch codec {
        case .hevc:
            codecType = kCMVideoCodecType_HEVC
        case .h264:
            codecType = kCMVideoCodecType_H264
        }

        var encoderSpecification: CFDictionary?
        if codec == .h264 {
            let spec: [NSString: AnyObject] = [
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue
            ]
            encoderSpecification = spec as CFDictionary
        }

        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard createStatus == noErr, let session else {
            throw VideoEncoderError.failedToCreateSession(createStatus)
        }

        let bytesPerSecond = Double(bitrate) / 8.0
        let properties: [NSString: AnyObject] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: NSNumber(value: fps * 2),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: NSNumber(value: 2.0),
            kVTCompressionPropertyKey_AverageBitRate: NSNumber(value: bitrate),
            kVTCompressionPropertyKey_DataRateLimits: [
                NSNumber(value: bytesPerSecond * 1.5),
                NSNumber(value: 1.0)
            ] as NSArray
        ]

        let propsStatus = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        guard propsStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            throw VideoEncoderError.failedToSetProperties(propsStatus)
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            throw VideoEncoderError.failedToPrepare(prepareStatus)
        }

        stateLock.lock()
        compressionSession = session
        stateLock.unlock()
    }

    public func encode(sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let session = compressionSession
        stateLock.unlock()

        guard let session else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        if status != noErr {
            print("Encoder: VTCompressionSessionEncodeFrame failed with status \(status)")
        }
    }

    public func stop() {
        stateLock.lock()
        let session = compressionSession
        compressionSession = nil
        stateLock.unlock()

        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    fileprivate func handleEncodedFrame(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer else {
            if status != noErr {
                print("Encoder: Output callback error \(status)")
            }
            return
        }

        stateLock.lock()
        let handler = _outputHandler
        stateLock.unlock()

        handler?(sampleBuffer)
    }
}
