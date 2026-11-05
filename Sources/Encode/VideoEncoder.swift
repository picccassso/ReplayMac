import Foundation
import VideoToolbox
@preconcurrency import CoreMedia
import CoreVideo
import os.log

public enum VideoCodec: Sendable {
    case hevc
    case h264
}

public struct VideoEncoderConfiguration: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let codec: VideoCodec
    public let bitrate: Int
    public var captureHDR: Bool = false
}

public enum VideoEncoderError: Error {
    case hdrRequiresHEVC
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
    encoder.handleEncodedFrame(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
}

public final class VideoEncoder: @unchecked Sendable {
    // @unchecked: mutable state is only touched inside `stateLock` (deinit aside, which has the object to itself).
    public typealias OutputHandler = @Sendable (CMSampleBuffer) -> Void

    private static let logger = Logger(subsystem: "com.replaycap", category: "VideoEncoder")
    private var compressionSession: VTCompressionSession?
    private let stateLock = NSLock()
    private var _outputHandler: OutputHandler?
    private var _currentConfiguration: VideoEncoderConfiguration?
    private var encodeCount: Int64 = 0
    private var droppedFrameCount: Int64 = 0

    private var _simulatesDroppedFrame: (@Sendable (CMTime) -> Bool)?

    /// Test seam: when set, the output callback treats a frame for which this
    /// returns true as dropped by VideoToolbox (no sample buffer), the way a
    /// real-time session reports frames it could not encode in time.
    var simulatesDroppedFrame: (@Sendable (CMTime) -> Bool)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _simulatesDroppedFrame
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _simulatesDroppedFrame = newValue
        }
    }
    private var forcesKeyframeOnNextFrame = false

    // Idle refresh (see `IdleFrameRefreshPolicy`). The last frame handed to the
    // session is kept so it can be repeated while the screen is still.
    private let idleRefreshEnabled: Bool
    private let idleRefreshQueue = DispatchQueue(label: "com.replaycap.video.idle-refresh", qos: .userInitiated)
    private var idleRefreshTimer: DispatchSourceTimer?
    private var lastSubmittedPixelBuffer: CVPixelBuffer?
    private var lastSubmittedPTS: CMTime = .invalid
    /// Host-clock time the last frame was handed to the session. Idleness is
    /// judged from this, not from the frame's capture time: frames that reach
    /// the encoder late are still a live stream, not a still screen.
    private var lastSubmitClockTime: CMTime = .invalid
    private var idleRefreshSuspended = false
    private let clock: @Sendable () -> CMTime
    private var lastKeyframePTS: CMTime = .invalid
    private var idleRefreshCount: Int64 = 0

    /// Serializes frame submission so a repeated frame and a real one cannot
    /// interleave and reach the session out of order. Never taken by the
    /// output callback, which may run inside `VTCompressionSessionEncodeFrame`.
    private let submitLock = NSLock()

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

    /// - Parameter idleRefreshEnabled: repeat the last frame on a timer while
    ///   no new frame arrives. Tests turn it off and drive `refreshIfIdle(now:)`
    ///   with their own clock.
    /// - Parameter clock: the host clock capture stamps frames with. Tests
    ///   pass a simulated one.
    public init(
        idleRefreshEnabled: Bool = true,
        clock: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
    ) {
        self.idleRefreshEnabled = idleRefreshEnabled
        self.clock = clock
    }

    public var currentConfiguration: VideoEncoderConfiguration? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentConfiguration
    }

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
        bitrate: Int = 20_000_000,
        captureHDR: Bool = false
    ) throws {
        guard !captureHDR || codec == .hevc else { throw VideoEncoderError.hdrRequiresHEVC }
        stop()

        let codecType: CMVideoCodecType
        switch codec {
        case .hevc:
            codecType = kCMVideoCodecType_HEVC
        case .h264:
            codecType = kCMVideoCodecType_H264
        }

        Self.logger.info("Starting \(String(describing: codec), privacy: .public) encoder: \(width)x\(height) @ \(fps) fps, bitrate=\(bitrate) bps")

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
            imageBufferAttributes: captureHDR ? [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ] as CFDictionary : nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard createStatus == noErr, let session else {
            throw VideoEncoderError.failedToCreateSession(createStatus)
        }

        let bytesPerSecond = Double(bitrate) / 8.0
        var properties: [NSString: AnyObject] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: NSNumber(value: fps * 2),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: NSNumber(value: 2.0),
            kVTCompressionPropertyKey_AverageBitRate: NSNumber(value: bitrate),
            kVTCompressionPropertyKey_DataRateLimits: [
                NSNumber(value: bytesPerSecond * 1.5),
                NSNumber(value: 1.0)
            ] as NSArray,
            // Tag the output BT.709 (same primaries as the sRGB capture) so the
            // MP4 tells players which matrix to use instead of leaving them to
            // guess — an untagged stream is what made saved clips look drab.
            kVTCompressionPropertyKey_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        ]

        if captureHDR {
            // Record portable HLG, without synthesizing optional Dolby Vision
            // metadata. Auto invokes HDR image statistics on live SCK buffers;
            // that path can reject frames with kVTParameterErr (-12902).
            // Main 10 and the Rec.2020/HLG colour tags still signal HDR.
            properties[kVTCompressionPropertyKey_HDRMetadataInsertionMode] = kVTHDRMetadataInsertionMode_None
            properties[kVTCompressionPropertyKey_ProfileLevel] = kVTProfileLevel_HEVC_Main10_AutoLevel
            properties[kVTCompressionPropertyKey_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            properties[kVTCompressionPropertyKey_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            properties[kVTCompressionPropertyKey_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        }

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
        _currentConfiguration = VideoEncoderConfiguration(
            width: width,
            height: height,
            fps: fps,
            codec: codec,
            bitrate: bitrate,
            captureHDR: captureHDR
        )
        stateLock.unlock()

        if idleRefreshEnabled {
            startIdleRefreshTimer()
        }
    }

    /// Forces the next encoded frame to be a keyframe.
    ///
    /// A recorder can only begin a file on a keyframe — earlier frames
    /// reference one that will not be in the file — so anything that starts
    /// writing mid-stream would otherwise have to discard frames until the
    /// encoder's next scheduled keyframe, up to `MaxKeyFrameIntervalDuration`
    /// away. Asking for one here keeps that wait down to a single frame.
    public func requestKeyframe() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard compressionSession != nil else { return }
        forcesKeyframeOnNextFrame = true
    }

    public func encode(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        submitLock.lock()
        defer { submitLock.unlock() }
        submitFrameLocked(pixelBuffer: pixelBuffer, proposedPTS: pts, duration: duration, submittedAt: clock(), isIdleRefresh: false)
    }

    /// Repeats the last frame if the encoder has gone
    /// `IdleFrameRefreshPolicy.idleInterval` without one. The repeat is
    /// stamped the last frame's capture time plus the time since it was
    /// submitted, which is `now` for a stream without latency and keeps any
    /// steady capture latency intact otherwise. The idle timer calls this with
    /// the encoder's clock; tests call it directly. Returns true when a frame
    /// was submitted.
    @discardableResult
    func refreshIfIdle(now: CMTime) -> Bool {
        submitLock.lock()
        defer { submitLock.unlock() }

        stateLock.lock()
        let pixelBuffer = lastSubmittedPixelBuffer
        let isIdle = compressionSession != nil
            && !idleRefreshSuspended
            && IdleFrameRefreshPolicy.shouldRefresh(lastSubmitTime: lastSubmitClockTime, now: now)
        let refreshPTS = CMTimeAdd(lastSubmittedPTS, CMTimeSubtract(now, lastSubmitClockTime))
        let fps = _currentConfiguration?.fps ?? 60
        stateLock.unlock()

        guard isIdle, let pixelBuffer else { return false }
        // One frame's worth, like a captured frame. Without a duration the
        // writer stretches a clip's final frame over the whole gap before it,
        // so a save taken on a still screen ran a quarter second long.
        let duration = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        return submitFrameLocked(pixelBuffer: pixelBuffer, proposedPTS: refreshPTS, duration: duration, submittedAt: now, isIdleRefresh: true)
    }

    /// Caller must hold `submitLock`.
    @discardableResult
    private func submitFrameLocked(
        pixelBuffer: CVPixelBuffer,
        proposedPTS: CMTime,
        duration: CMTime,
        submittedAt: CMTime,
        isIdleRefresh: Bool
    ) -> Bool {
        // Every frame keeps the capture time it arrived with; nothing later in
        // the pipeline re-stamps it. A frame with no usable time cannot be
        // placed against the audio, so it is dropped rather than guessed at.
        guard proposedPTS.isNumeric, proposedPTS.seconds > 0 else {
            Self.logger.error("Dropping frame with unusable timestamp \(proposedPTS.seconds, privacy: .public)")
            return false
        }

        stateLock.lock()
        guard let session = compressionSession else {
            stateLock.unlock()
            return false
        }
        let pts = IdleFrameRefreshPolicy.monotonicPTS(proposedPTS, after: lastSubmittedPTS)
        let requestedKeyframe = forcesKeyframeOnNextFrame
        let backstopKeyframe = !requestedKeyframe
            && IdleFrameRefreshPolicy.shouldForceKeyframe(pts: pts, lastKeyframePTS: lastKeyframePTS)
        let forcesKeyframe = requestedKeyframe || backstopKeyframe
        forcesKeyframeOnNextFrame = false

        let previousPTS = lastSubmittedPTS
        let previousSubmitClockTime = lastSubmitClockTime
        let previousPixelBuffer = lastSubmittedPixelBuffer
        let previousKeyframePTS = lastKeyframePTS
        if forcesKeyframe {
            // Counted as soon as it is asked for, so the frames still in
            // flight before its output arrives do not force another.
            lastKeyframePTS = pts
        }
        lastSubmittedPTS = pts
        lastSubmitClockTime = submittedAt
        lastSubmittedPixelBuffer = pixelBuffer
        encodeCount += 1
        let isFirstFrame = encodeCount == 1
        if isIdleRefresh {
            idleRefreshCount += 1
        }
        let refreshCount = idleRefreshCount
        stateLock.unlock()

        if isFirstFrame {
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            Self.logger.notice("First input frame: \(width, privacy: .public)x\(height, privacy: .public), pixelFormat=\(format, privacy: .public)")
        }
        if isIdleRefresh, refreshCount == 1 || refreshCount % 600 == 0 {
            Self.logger.debug("Screen idle; repeating last frame (refresh #\(refreshCount, privacy: .public))")
        }

        let frameProperties: CFDictionary? = forcesKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        guard status == noErr else {
            stateLock.lock()
            // The frame never reached the encoder, so put back what it claimed:
            // a keyframe request that rode along with it carries over to the
            // next frame, and the idle clock still runs from the last frame
            // that did go in.
            forcesKeyframeOnNextFrame = forcesKeyframeOnNextFrame || requestedKeyframe
            lastSubmittedPTS = previousPTS
            lastSubmitClockTime = previousSubmitClockTime
            lastSubmittedPixelBuffer = previousPixelBuffer
            lastKeyframePTS = previousKeyframePTS
            stateLock.unlock()
            Self.logger.error("VTCompressionSessionEncodeFrame failed with status \(status)")
            return false
        }
        return true
    }

    private func startIdleRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: idleRefreshQueue)
        let interval = IdleFrameRefreshPolicy.checkInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.refreshIfIdle(now: self.clock())
        }

        stateLock.lock()
        let previous = idleRefreshTimer
        idleRefreshTimer = timer
        stateLock.unlock()

        previous?.cancel()
        timer.resume()
    }

    /// Stops repeating frames without stopping the session. Capture teardown
    /// calls this first: between the screen stream stopping and the encoder
    /// being stopped (several awaits later), repeats would otherwise keep
    /// arriving, and a repeated keyframe could open a recorder segment that
    /// holds nothing but the frozen last frame. Cleared by the next `start`.
    public func stopIdleRefresh() {
        submitLock.lock()
        defer { submitLock.unlock() }
        stateLock.lock()
        let timer = idleRefreshTimer
        idleRefreshTimer = nil
        idleRefreshSuspended = true
        lastSubmittedPixelBuffer = nil
        stateLock.unlock()
        timer?.cancel()
    }

    public func stop() {
        // Holding the submit lock means no frame, real or repeated, can be
        // handed to the session while it is being torn down.
        submitLock.lock()
        defer { submitLock.unlock() }

        stateLock.lock()
        let session = compressionSession
        let timer = idleRefreshTimer
        idleRefreshTimer = nil
        compressionSession = nil
        _currentConfiguration = nil
        encodeCount = 0
        droppedFrameCount = 0
        forcesKeyframeOnNextFrame = false
        lastSubmittedPixelBuffer = nil
        lastSubmittedPTS = .invalid
        lastSubmitClockTime = .invalid
        idleRefreshSuspended = false
        lastKeyframePTS = .invalid
        idleRefreshCount = 0
        stateLock.unlock()

        timer?.cancel()

        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    /// VideoToolbox stamps each output with the presentation time of the frame
    /// it encoded, so outputs are passed on exactly as they come. Matching
    /// outputs to inputs by order instead (an earlier design) broke on the
    /// first dropped frame: a real-time session reports a drop as a callback
    /// with no sample, every later output took an older frame's time, and
    /// video fell further behind audio with each drop.
    fileprivate func handleEncodedFrame(status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        var sampleBuffer = sampleBuffer
        if let candidate = sampleBuffer,
           let dropsFrame = simulatesDroppedFrame,
           dropsFrame(CMSampleBufferGetPresentationTimeStamp(candidate)) {
            sampleBuffer = nil
        }

        guard status == noErr, let sampleBuffer else {
            if status != noErr {
                Self.logger.error("Output callback error \(status)")
            } else {
                stateLock.lock()
                droppedFrameCount += 1
                let dropped = droppedFrameCount
                stateLock.unlock()
                if dropped == 1 || dropped % 300 == 0 {
                    let flagged = infoFlags.contains(.frameDropped)
                    Self.logger.notice("Encoder dropped a frame (total \(dropped, privacy: .public), flagged=\(flagged, privacy: .public))")
                }
            }
            return
        }

        let outputPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard outputPTS.isNumeric else {
            Self.logger.error("Encoder output has no presentation time; dropping it")
            return
        }

        stateLock.lock()
        let handler = _outputHandler
        if Self.isKeyframe(sampleBuffer),
           !lastKeyframePTS.isNumeric || CMTimeCompare(outputPTS, lastKeyframePTS) > 0 {
            lastKeyframePTS = outputPTS
        }
        stateLock.unlock()

        handler?(sampleBuffer)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else {
            return true
        }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let notSync = CFDictionaryGetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        guard let notSync else { return true }
        return !CFBooleanGetValue(unsafeBitCast(notSync, to: CFBoolean.self))
    }
}
