@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

/// Re-encodes a saved clip to a smaller file.
///
/// This runs *after* the clip has already been written, never before. Saving
/// stays instant — the raw clip hits disk as a remux the moment the hotkey is
/// pressed — and compression happens afterwards in the background, so a slow
/// re-encode can never cost someone the moment they were trying to capture.
///
/// `AVAssetWriter` is used rather than `AVAssetExportSession` because the export
/// presets only offer fixed quality tiers, and hitting a specific megabyte
/// target requires setting the bitrate directly.
final class ClipCompressor: @unchecked Sendable {
    enum CompressionError: LocalizedError {
        case noVideoTrack
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The clip has no video to compress."
            case .writeFailed(let reason): "Compression failed: \(reason)"
            }
        }
    }

    struct Result: Sendable {
        var url: URL
        var byteCount: Int64
        var replacedOriginal: Bool
    }

    private let queue = DispatchQueue(label: "app.vestige.compressor", qos: .utility)

    /// Compresses `source` according to `settings`.
    ///
    /// Returns the resulting file, which is either a sibling "… (compressed).mp4"
    /// or the original path when the original is not being kept.
    ///
    /// A size target that the first pass misses is retried once with the
    /// bitrate scaled by how far over it landed. Constant bitrate is accurate
    /// where it is supported, so this normally never runs — it exists because a
    /// property VideoToolbox does not honour is dropped silently, and an
    /// unshareable file is a worse outcome than a slower one.
    func compress(
        _ source: URL,
        settings: CompressionSettings,
        captureBitrate: Int
    ) async throws -> Result {
        var result = try await encode(source, settings: settings, captureBitrate: captureBitrate)

        if settings.mode == .targetSize, result.byteCount > settings.targetBytes {
            let overshoot = Double(result.byteCount) / Double(settings.targetBytes)
            Log.storage.notice("""
                Compressed clip missed its size target by \(Int((overshoot - 1) * 100), privacy: .public)%; \
                retrying at a lower bitrate
                """)
            result = try await encode(
                source,
                settings: settings,
                captureBitrate: captureBitrate,
                bitrateScale: 1 / (overshoot * 1.05)
            )
        }

        return result
    }

    private func encode(
        _ source: URL,
        settings: CompressionSettings,
        captureBitrate: Int,
        bitrateScale: Double = 1
    ) async throws -> Result {
        let codec = settings.codec
        let asset = AVURLAsset(url: source)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompressionError.noVideoTrack
        }

        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let includesAudio = audioTrack != nil

        let bitrate = max(200_000, Int(Double(settings.targetBitrate(
            duration: duration,
            captureBitrate: captureBitrate,
            includesAudio: includesAudio
        )) * bitrateScale))

        let destination = source
            .deletingLastPathComponent()
            .appending(path: "\(source.deletingPathExtension().lastPathComponent) (compressed).mp4")
        try? FileManager.default.removeItem(at: destination)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        // Decode to the encoder's native pixel format so no conversion is
        // needed between the two halves of the pipeline.
        let readerVideoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        readerVideoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerVideoOutput) else {
            throw CompressionError.writeFailed("cannot read the video track")
        }
        reader.add(readerVideoOutput)

        let frameRate = Double(nominalFrameRate) > 0 ? Double(nominalFrameRate) : 60

        // Size the picture to the bits it will actually get, rather than
        // starving the source resolution and getting a blocky clip for it.
        let plan = EncodePlan.fitting(
            bitrate: bitrate,
            sourceSize: naturalSize,
            frameRate: frameRate
        )
        Log.storage.info(
            "Compressing to \(plan.width, privacy: .public)x\(plan.height, privacy: .public) \(codec.rawValue, privacy: .public) @ \(bitrate / 1000, privacy: .public)kbps"
        )

        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: true,
            // Compression is background work on a clip that is already safely
            // on disk, so there is nothing to gain by trading quality for speed.
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: false
        ]
        if settings.mode == .targetSize, duration > 0 {
            // Constant bitrate, because hitting a size target is exactly what
            // it is for. `DataRateLimits` is the obvious alternative and was
            // what this used, but it ignores the requested bitrate entirely and
            // settles at about 73% of the cap — measured identical output for
            // 700, 850, and 1100 kbps requests. That wasted a quarter of the
            // budget and was the main reason compressed clips looked crushed.
            //
            // The two cannot be combined: setting both puts the encoder back
            // into the limited mode, so this deliberately sets only CBR and
            // relies on the size check after writing to catch a platform that
            // does not honour it.
            compressionProperties[kVTCompressionPropertyKey_ConstantBitRate as String] = bitrate
        }
        compressionProperties[AVVideoProfileLevelKey] = codec == .h264
            ? AVVideoProfileLevelH264HighAutoLevel
            : nil

        let writerVideoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: plan.width,
                AVVideoHeightKey: plan.height,
                AVVideoScalingModeKey: AVVideoScalingModeResize,
                AVVideoCompressionPropertiesKey: compressionProperties
            ]
        )
        writerVideoInput.expectsMediaDataInRealTime = false
        writerVideoInput.transform = transform
        guard writer.canAdd(writerVideoInput) else {
            throw CompressionError.writeFailed("cannot write the video track")
        }
        writer.add(writerVideoInput)

        // Audio is re-encoded at a fixed, transparent-enough rate. Squeezing
        // audio to hit a size target trades away far more perceived quality
        // than taking the same bits out of the video.
        var readerAudioOutput: AVAssetReaderTrackOutput?
        var writerAudioInput: AVAssetWriterInput?

        if let audioTrack {
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: CompressionSettings.audioBitrate
                ]
            )
            input.expectsMediaDataInRealTime = false

            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                readerAudioOutput = output
                writerAudioInput = input
            }
        }

        guard reader.startReading() else {
            throw CompressionError.writeFailed(reader.error?.localizedDescription ?? "cannot read")
        }
        guard writer.startWriting() else {
            throw CompressionError.writeFailed(writer.error?.localizedDescription ?? "cannot write")
        }
        writer.startSession(atSourceTime: .zero)

        let videoPipe = Pipe(output: readerVideoOutput, input: writerVideoInput)
        let audioPipe = readerAudioOutput.flatMap { output in
            writerAudioInput.map { Pipe(output: output, input: $0) }
        }

        async let videoDone: Void = transfer(videoPipe, label: "video")
        async let audioDone: Void = {
            guard let audioPipe else { return }
            await transfer(audioPipe, label: "audio")
        }()
        _ = await (videoDone, audioDone)

        // `copyNextSampleBuffer()` returns nil both at the end of the track and
        // when reading fails, and the transfer loop cannot tell them apart.
        // Without this check a read that died halfway finished the file anyway,
        // producing a compressed clip silently truncated to wherever it got to
        // — and then replacing the intact original with it.
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw CompressionError.writeFailed(
                reader.error?.localizedDescription ?? "the clip could not be read"
            )
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw CompressionError.writeFailed(writer.error?.localizedDescription ?? "did not finish")
        }

        let compressedSize = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let originalSize = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        // Re-encoding a clip that was already efficiently encoded can produce a
        // larger file. Keeping it would be strictly worse in both size and
        // quality, so the original stands instead.
        if compressedSize >= originalSize, originalSize > 0 {
            Log.storage.notice("Compressed copy was larger than the original; keeping the original")
            try? FileManager.default.removeItem(at: destination)
            return Result(url: source, byteCount: originalSize, replacedOriginal: false)
        }

        if settings.keepsOriginal {
            return Result(url: destination, byteCount: compressedSize, replacedOriginal: false)
        }

        // Replacing the original: move the compressed file over it so the
        // clip keeps the name the user already knows it by.
        do {
            _ = try FileManager.default.replaceItemAt(source, withItemAt: destination)
            return Result(url: source, byteCount: compressedSize, replacedOriginal: true)
        } catch {
            Log.storage.error("Could not replace original: \(error.localizedDescription, privacy: .public)")
            return Result(url: destination, byteCount: compressedSize, replacedOriginal: false)
        }
    }

    /// One reader/writer pairing.
    private struct Pipe: @unchecked Sendable {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
    }

    /// Pumps samples from a reader output into a writer input, honouring
    /// back-pressure so the whole clip is never resident at once.
    private func transfer(_ pipe: Pipe, label: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = Latch()

            pipe.input.requestMediaDataWhenReady(on: queue) {
                while pipe.input.isReadyForMoreMediaData {
                    guard let sample = pipe.output.copyNextSampleBuffer() else {
                        pipe.input.markAsFinished()
                        finished.once { continuation.resume() }
                        return
                    }
                    if !pipe.input.append(sample) {
                        pipe.input.markAsFinished()
                        finished.once { continuation.resume() }
                        return
                    }
                }
            }
        }
    }

    /// Ensures a continuation resumes exactly once.
    private final class Latch: @unchecked Sendable {
        private var hasFired = false
        private let lock = NSLock()

        func once(_ body: () -> Void) {
            lock.lock()
            let shouldFire = !hasFired
            hasFired = true
            lock.unlock()
            if shouldFire { body() }
        }
    }
}
