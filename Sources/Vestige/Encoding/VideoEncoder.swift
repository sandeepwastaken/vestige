import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Wraps a `VTCompressionSession` configured for continuous, low-overhead
/// real-time encoding.
///
/// Encoding runs for the whole session, not just when a clip is saved, so every
/// setting minimises sustained cost rather than maximising quality. B-frames in
/// particular are disabled: they would compress slightly better, but they make
/// decode order differ from presentation order, which complicates trimming the
/// ring buffer and delays a captured frame reaching the buffer.
final class VideoEncoder: @unchecked Sendable {
    enum EncoderError: LocalizedError {
        case sessionCreationFailed(OSStatus)
        case encodeFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .sessionCreationFailed(let status):
                "The video encoder could not be started (error \(status))."
            case .encodeFailed(let status):
                "The video encoder stopped unexpectedly (error \(status))."
            }
        }
    }

    typealias FrameHandler = @Sendable (BufferedVideoFrame) -> Void
    typealias FailureHandler = @Sendable (EncoderError) -> Void

    let configuration: EncoderConfiguration
    private(set) var isHardwareAccelerated = false

    private let frameHandler: FrameHandler
    private let failureHandler: FailureHandler
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var hasReportedFailure = false

    /// Creates an encoder, falling back from HEVC to H.264 if this Mac cannot
    /// create an HEVC session. Older Intel hardware and some virtualised GPUs
    /// advertise HEVC but fail at session creation.
    static func make(
        configuration: EncoderConfiguration,
        onFrame frameHandler: @escaping FrameHandler,
        onFailure failureHandler: @escaping FailureHandler
    ) throws -> VideoEncoder {
        do {
            return try VideoEncoder(
                configuration: configuration,
                frameHandler: frameHandler,
                failureHandler: failureHandler
            )
        } catch where configuration.codec == .hevc {
            Log.encoder.notice("HEVC unavailable on this hardware; falling back to H.264")
            var fallback = configuration
            fallback.codec = .h264
            return try VideoEncoder(
                configuration: fallback,
                frameHandler: frameHandler,
                failureHandler: failureHandler
            )
        }
    }

    private init(
        configuration: EncoderConfiguration,
        frameHandler: @escaping FrameHandler,
        failureHandler: @escaping FailureHandler
    ) throws {
        self.configuration = configuration
        self.frameHandler = frameHandler
        self.failureHandler = failureHandler

        // Asking for hardware acceleration rather than requiring it: on the rare
        // Mac without a hardware encoder, a software session at 1080p is still
        // usable, whereas requiring it would leave the user with nothing.
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: configuration.codec.codecType,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encoderOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw EncoderError.sessionCreationFailed(status)
        }
        self.session = session

        applyProperties(to: session)
        VTCompressionSessionPrepareToEncodeFrames(session)

        isHardwareAccelerated = booleanProperty(
            kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            on: session
        )

        Log.encoder.info("""
            Encoder ready: \(configuration.width, privacy: .public)x\(configuration.height, privacy: .public) \
            @\(configuration.frameRate, privacy: .public)fps \
            \(configuration.codec.rawValue, privacy: .public) \
            \(configuration.bitrate / 1_000_000, privacy: .public)Mbps \
            hardware=\(self.isHardwareAccelerated, privacy: .public)
            """)
    }

    private func applyProperties(to session: VTCompressionSession) {
        func set(_ key: CFString, _ value: CFTypeRef) {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr {
                // Not fatal: encoders legitimately reject properties they do not
                // implement, and the session still works with its defaults.
                Log.encoder.debug("Encoder rejected \(key as String, privacy: .public) (\(status, privacy: .public))")
            }
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, configuration.bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, configuration.frameRate as CFNumber)

        // Bound short-term bitrate spikes so a chaotic scene cannot briefly
        // balloon the buffer or outrun the disk. 1.5x average over one second.
        let peakBytesPerSecond = Double(configuration.bitrate) * 1.5 / 8.0
        set(kVTCompressionPropertyKey_DataRateLimits, [peakBytesPerSecond, 1.0] as CFArray)

        set(kVTCompressionPropertyKey_MaxKeyFrameInterval,
            Int(Double(configuration.frameRate) * EncoderConfiguration.keyframeInterval) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            EncoderConfiguration.keyframeInterval as CFNumber)

        switch configuration.codec {
        case .h264:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        case .hevc:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        }
    }

    private func booleanProperty(_ key: CFString, on session: VTCompressionSession) -> Bool {
        var value: CFTypeRef?
        // The raw pointer is formed explicitly: passing `&value` directly makes
        // the compiler warn about taking a pointer to an Optional<AnyObject>.
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(
                session,
                key: key,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }

        guard status == noErr, let value else { return false }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    // MARK: - Encoding

    /// Submits a captured frame. Returns immediately; encoded output arrives on
    /// VideoToolbox's own thread via the frame handler.
    func encode(_ imageBuffer: CVImageBuffer, presentationTime: CMTime, duration: CMTime) {
        lock.lock()
        guard let session else {
            lock.unlock()
            return
        }
        lock.unlock()

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        // An invalidated session is teardown, not a fault. The check above and
        // this call cannot be made atomic — the output callback can run inline
        // and takes the same lock — so a frame already in flight when the
        // session is torn down lands here and would otherwise be reported as an
        // encoder failure, triggering a restart of a pipeline that is being
        // shut down on purpose.
        if status != noErr, status != kVTInvalidSessionErr {
            reportFailure(.encodeFailed(status))
        }
    }

    /// Tears the session down. Safe to call more than once.
    func invalidate() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()

        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    fileprivate func handleEncodedFrame(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr else {
            reportFailure(.encodeFailed(status))
            return
        }
        guard let sampleBuffer, let frame = BufferedVideoFrame(sampleBuffer: sampleBuffer) else { return }
        frameHandler(frame)
    }

    /// Reports the first failure only. A broken encoder emits an error for every
    /// subsequent frame, and the recovery path just needs to be told once.
    private func reportFailure(_ error: EncoderError) {
        lock.lock()
        let shouldReport = !hasReportedFailure
        hasReportedFailure = true
        lock.unlock()

        guard shouldReport else { return }
        Log.encoder.error("\(error.localizedDescription, privacy: .public)")
        failureHandler(error)
    }

    deinit {
        invalidate()
    }
}

/// VideoToolbox's C output callback. The refcon is an unretained pointer to the
/// owning encoder, which outlives the session because `invalidate()` runs
/// before deallocation.
private func encoderOutputCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ sourceFrameRefcon: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ flags: VTEncodeInfoFlags,
    _ sampleBuffer: CMSampleBuffer?
) {
    guard let refcon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
    encoder.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
}
