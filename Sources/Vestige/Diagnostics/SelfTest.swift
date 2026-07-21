import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// End-to-end verification of the capture pipeline, minus the screen.
///
/// Run with `Vestige --self-test`. Synthetic frames are pushed through the real
/// `VideoEncoder`, the real `ReplayBuffer`, and the real `ClipWriter`, and the
/// resulting MP4 is reopened and inspected with AVFoundation.
///
/// This exists because the parts of Vestige most likely to break subtly — the
/// keyframe-aligned trimming and the passthrough mux — cannot be checked by
/// looking at the UI, and because the pipeline depends on hardware that varies
/// between Macs. A user reporting "clips won't save" can run this and get a
/// specific answer rather than a shrug.
enum SelfTest {
    private static let width = 640
    private static let height = 360
    private static let frameRate = 30

    /// Runs every check and exits with a non-zero status if any fail.
    static func runAndExit() -> Never {
        // Unbuffered, so progress survives a crash. When stdout is a pipe it is
        // block-buffered by default and an abort takes the pending output with
        // it, which hides the very line that would say where it failed.
        setvbuf(stdout, nil, _IONBF, 0)

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failures = 0

        Task {
            failures = await run()
            semaphore.signal()
        }
        semaphore.wait()

        exit(failures == 0 ? 0 : 1)
    }

    private static func run() async -> Int {
        var failures = 0

        func check(_ label: String, _ passed: Bool, detail: String = "") {
            let mark = passed ? "  ok  " : " FAIL "
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }

        print("Vestige self-test")
        print("Encoding \(width)x\(height) @\(frameRate)fps\n")

        // MARK: Encoder

        let configuration = EncoderConfiguration(
            width: width, height: height, frameRate: frameRate, codec: .h264
        )

        // A 2-second retention window against 6 seconds of input, so trimming
        // is exercised many times rather than incidentally.
        let buffer = ReplayBuffer(duration: 2.0, bitrate: configuration.bitrate)

        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder.make(
                configuration: configuration,
                onFrame: { buffer.append($0) },
                onFailure: { error in print("      encoder error: \(error.localizedDescription)") }
            )
        } catch {
            check("Create encoder", false, detail: error.localizedDescription)
            return failures
        }
        check("Create encoder", true, detail: encoder.isHardwareAccelerated ? "hardware" : "software")

        // MARK: Feed frames

        let totalFrames = frameRate * 6
        for index in 0..<totalFrames {
            guard let pixelBuffer = makePixelBuffer(frameIndex: index) else {
                check("Allocate pixel buffer", false)
                return failures
            }
            encoder.encode(
                pixelBuffer,
                presentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)),
                duration: CMTime(value: 1, timescale: CMTimeScale(frameRate))
            )
        }

        // Flushing the session drains every pending frame to the callback.
        encoder.invalidate()

        // MARK: Buffer behaviour

        let statistics = buffer.statistics
        check("Frames reached the buffer", statistics.frameCount > 0,
              detail: "\(statistics.frameCount) frames, \(statistics.byteCount / 1024) KB")

        // The buffer holds its window plus at most one keyframe interval, since
        // it can only trim on keyframe boundaries.
        let upperBound = 2.0 + EncoderConfiguration.keyframeInterval + 0.5
        check("Trimmed to the retention window",
              statistics.bufferedSeconds > 1.0 && statistics.bufferedSeconds <= upperBound,
              detail: String(format: "%.2fs held (window 2s, bound %.1fs)", statistics.bufferedSeconds, upperBound))

        check("Older frames were discarded", statistics.frameCount < totalFrames,
              detail: "\(statistics.frameCount) of \(totalFrames) retained")

        let snapshot = buffer.snapshot()
        check("Buffer starts on a keyframe", snapshot.video.first?.isKeyframe == true)

        // MARK: Muxing

        let destination = FileManager.default.temporaryDirectory
            .appending(path: "vestige-selftest-\(UUID().uuidString).mp4")

        do {
            try await ClipWriter().write(snapshot, to: destination)
            check("Wrote MP4", true)
        } catch {
            check("Wrote MP4", false, detail: error.localizedDescription)
            return failures
        }

        defer { try? FileManager.default.removeItem(at: destination) }

        // MARK: Verify the file

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        check("File is non-empty", size > 1024, detail: "\(size / 1024) KB")

        let asset = AVURLAsset(url: destination)

        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            check("File duration matches the buffer",
                  abs(seconds - snapshot.duration) < 0.5,
                  detail: String(format: "%.2fs in file, %.2fs buffered", seconds, snapshot.duration))

            let tracks = try await asset.loadTracks(withMediaType: .video)
            check("File has a video track", tracks.count == 1)

            if let track = tracks.first {
                let size = try await track.load(.naturalSize)
                check("Dimensions survived the mux",
                      Int(size.width) == width && Int(size.height) == height,
                      detail: "\(Int(size.width))x\(Int(size.height))")
            }

            // A file that reports a duration but cannot be read frame by frame
            // is the exact failure mode a mid-GOP start produces.
            if let track = tracks.first {
                check("Video decodes", await canDecodeFirstFrame(asset: asset, track: track))
            }
        } catch {
            check("Read back the file", false, detail: error.localizedDescription)
        }

        // MARK: Audio mixing

        print("\nAudio mixing (system + microphone):")
        failures += runAudioMixerChecks(check: check)

        // MARK: Writing audio into a clip

        print("\nWriting a clip with audio:")
        failures += await runAudioTrackChecks(videoFrames: snapshot.video, check: check)

        print("\n\(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")")
        return failures
    }

    /// Writes a clip containing audio and checks the audio survived.
    ///
    /// This exists because a failure here is invisible: `ClipWriter` falls back
    /// to writing video only when the audio track cannot be encoded, which
    /// preserves the clip but produces a silent one with nothing to indicate
    /// why. The PCM fed in matches what ScreenCaptureKit actually delivers —
    /// 48 kHz stereo 32-bit float, non-interleaved — so if AAC conversion from
    /// that layout is broken, this catches it.
    private static func runAudioTrackChecks(
        videoFrames: [BufferedVideoFrame],
        check: (String, Bool, String) -> Void
    ) async -> Int {
        var failures = 0
        func verify(_ label: String, _ passed: Bool, _ detail: String = "") {
            check(label, passed, detail)
            if !passed { failures += 1 }
        }

        guard !videoFrames.isEmpty, let format = AudioMixer.makeFormatDescription() else {
            verify("Prepare audio", false)
            return failures
        }

        // Audio spanning the same timeline as the buffered video, so it is not
        // filtered out for starting before the clip does.
        let start = videoFrames[0].presentationTime
        let seconds = 2.0
        var audio: [BufferedAudioFrame] = []

        let chunk = AudioMixer.framesPerChunk
        var offset = 0
        while offset < Int(seconds * AudioMixer.sampleRate) {
            let count = min(chunk, Int(seconds * AudioMixer.sampleRate) - offset)
            let samples = (0..<count).map { index -> Float in
                // A quiet tone, so a silent track is distinguishable from a
                // present one by more than just its existence.
                sin(Float(offset + index) * 0.05) * 0.3
            }
            let time = CMTimeAdd(
                start,
                CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(AudioMixer.sampleRate))
            )
            if let buffer = AudioMixer.makeSampleBuffer(
                left: samples, right: samples, frames: count,
                presentationTime: time, format: format
            ), let frame = BufferedAudioFrame(sampleBuffer: buffer) {
                audio.append(frame)
            }
            offset += count
        }

        verify("Build PCM audio", !audio.isEmpty, "\(audio.count) buffers")
        guard !audio.isEmpty else { return failures }

        let snapshot = ReplaySnapshot(video: videoFrames, audio: audio)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "vestige-audio-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await ClipWriter().write(snapshot, to: destination)
            verify("Write clip with audio", true)
        } catch {
            verify("Write clip with audio", false, error.localizedDescription)
            return failures
        }

        let asset = AVURLAsset(url: destination)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

        // The important one. ClipWriter silently degrades to a video-only clip
        // when audio fails, so an empty track list here is precisely the
        // "my clip has no sound" bug.
        verify("Clip contains an audio track", audioTracks.count == 1,
               "\(audioTracks.count) audio track(s)")

        if let track = audioTracks.first {
            let duration = (try? await track.load(.timeRange).duration).map(CMTimeGetSeconds) ?? 0
            verify("Audio track has content", duration > 0.5,
                   String(format: "%.2fs", duration))
        }

        // The regression that produced silent clips. `CMSampleBufferGetDuration`
        // returns invalid for some audio buffers, and `CMTimeAdd` with an
        // invalid operand yields an invalid `CMTime` that compares false against
        // everything — so the "does this frame overlap the clip" filter rejected
        // every single buffer. Buffers built without timing information
        // reproduce that exactly.
        let untimed = audio.compactMap { frame -> BufferedAudioFrame? in
            guard let stripped = Self.strippingDuration(frame.sampleBuffer) else { return nil }
            return BufferedAudioFrame(sampleBuffer: stripped)
        }

        verify("Rebuild audio without timing", untimed.count == audio.count,
               "\(untimed.count) of \(audio.count)")

        if untimed.count == audio.count {
            verify("Duration recovered from sample count",
                   untimed.allSatisfy { $0.duration.isValid && $0.duration.seconds > 0 },
                   String(format: "%.4fs each", untimed.first?.duration.seconds ?? 0))

            let untimedSnapshot = ReplaySnapshot(video: videoFrames, audio: untimed)
            let untimedURL = FileManager.default.temporaryDirectory
                .appending(path: "vestige-untimed-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: untimedURL) }

            do {
                try await ClipWriter().write(untimedSnapshot, to: untimedURL)
                let tracks = (try? await AVURLAsset(url: untimedURL)
                    .loadTracks(withMediaType: .audio)) ?? []
                verify("Untimed audio still produces sound", tracks.count == 1,
                       "\(tracks.count) audio track(s)")
            } catch {
                verify("Untimed audio still produces sound", false, error.localizedDescription)
            }
        }

        return failures
    }

    /// Rebuilds a sample buffer with no timing information, mimicking the
    /// buffers whose duration the system reports as invalid.
    private static func strippingDuration(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: .invalid
        )

        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &result
        ) == noErr else {
            _ = format
            return nil
        }
        return result
    }

    /// Exercises `AudioMixer` with synthetic PCM.
    ///
    /// The mixer builds `CMSampleBuffer`s by hand and walks raw float pointers,
    /// and it only ever runs at the moment a clip is saved — the worst possible
    /// place to discover a fault. Feeding it known constants makes the arithmetic
    /// checkable: two steady tones must sum to a predictable level, and a pair
    /// loud enough to clip must come back inside full scale.
    private static func runAudioMixerChecks(
        check: (String, Bool, String) -> Void
    ) -> Int {
        var failures = 0
        func verify(_ label: String, _ passed: Bool, _ detail: String = "") {
            check(label, passed, detail)
            if !passed { failures += 1 }
        }

        guard let format = AudioMixer.makeFormatDescription() else {
            verify("Create PCM format", false)
            return failures
        }
        verify("Create PCM format", true, "48kHz stereo float")

        let seconds = 2.0
        let system = makeTone(level: 0.5, seconds: seconds, format: format)
        let microphone = makeTone(level: 0.25, seconds: seconds, format: format)

        guard let mixed = AudioMixer.mix(
            system: system,
            microphone: microphone,
            from: .zero,
            duration: seconds,
            microphoneGain: 1.0
        ) else {
            verify("Mix two streams", false)
            return failures
        }
        verify("Mix two streams", true, "\(mixed.count) buffers")

        let mixedFrames = mixed.reduce(0) { $0 + Int(CMSampleBufferGetNumSamples($1)) }
        let expectedFrames = Int(seconds * AudioMixer.sampleRate)
        verify("Output length matches input", mixedFrames == expectedFrames,
               "\(mixedFrames) of \(expectedFrames) frames")

        // 0.5 + 0.25 = 0.75, below the 0.8 limiter threshold, so it must be
        // summed exactly rather than compressed.
        if let first = mixed.first {
            let channels = AudioMixer.extractChannels(from: first)
            let sample = channels.first?.dropFirst(100).first ?? 0
            verify("Levels sum correctly", abs(sample - 0.75) < 0.001,
                   String(format: "%.4f, expected 0.7500", sample))
            verify("Both channels present", channels.count == 2, "\(channels.count) channels")
        } else {
            verify("Levels sum correctly", false)
        }

        // 0.9 + 0.9 would be 1.8. Anything above 1.0 is inaudible distortion at
        // best, so the limiter must pull it back inside full scale.
        let loudA = makeTone(level: 0.9, seconds: 0.5, format: format)
        let loudB = makeTone(level: 0.9, seconds: 0.5, format: format)

        if let clipped = AudioMixer.mix(
            system: loudA, microphone: loudB,
            from: .zero, duration: 0.5, microphoneGain: 1.0
        ), let first = clipped.first {
            let peak = AudioMixer.extractChannels(from: first)
                .first?.dropFirst(100).prefix(1000).map(abs).max() ?? 0
            verify("Loud mixes stay inside full scale", peak <= 1.0 && peak > 0.8,
                   String(format: "peak %.4f", peak))
        } else {
            verify("Loud mixes stay inside full scale", false)
        }

        return failures
    }

    /// A constant-level PCM stream, delivered in 100 ms frames like real capture.
    private static func makeTone(
        level: Float,
        seconds: Double,
        format: CMAudioFormatDescription
    ) -> [BufferedAudioFrame] {
        let chunk = AudioMixer.framesPerChunk
        let total = Int(seconds * AudioMixer.sampleRate)
        var frames: [BufferedAudioFrame] = []

        var offset = 0
        while offset < total {
            let count = min(chunk, total - offset)
            let samples = [Float](repeating: level, count: count)
            let time = CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(AudioMixer.sampleRate))

            if let buffer = AudioMixer.makeSampleBuffer(
                left: samples, right: samples, frames: count,
                presentationTime: time, format: format
            ), let frame = BufferedAudioFrame(sampleBuffer: buffer) {
                frames.append(frame)
            }
            offset += count
        }
        return frames
    }

    /// Decodes the opening frames to prove the clip actually starts at a
    /// keyframe rather than merely claiming a duration.
    private static func canDecodeFirstFrame(asset: AVURLAsset, track: AVAssetTrack) async -> Bool {
        guard let reader = try? AVAssetReader(asset: asset) else { return false }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        guard reader.canAdd(output) else { return false }
        reader.add(output)

        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }

        return output.copyNextSampleBuffer() != nil
    }

    /// Builds a bi-planar YUV frame containing a moving band.
    ///
    /// The motion matters: a static image compresses to almost nothing and
    /// would not produce the inter-frame deltas that make keyframe placement —
    /// the thing under test — observable.
    private static func makePixelBuffer(frameIndex: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary, &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        // Luma plane: a diagonal gradient with a bright band that sweeps across.
        if let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let bytes = luma.assumingMemoryBound(to: UInt8.self)
            let bandX = (frameIndex * 11) % width

            for y in 0..<height {
                for x in 0..<width {
                    let base = UInt8(truncatingIfNeeded: (x + y) / 4 + 16)
                    let isBand = abs(x - bandX) < 40
                    bytes[y * stride + x] = isBand ? 235 : base
                }
            }
        }

        // Chroma plane: neutral grey, shifted slowly so colour also changes.
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let bytes = chroma.assumingMemoryBound(to: UInt8.self)
            let shift = UInt8(truncatingIfNeeded: 128 + (frameIndex % 32) - 16)

            for y in 0..<(height / 2) {
                for x in 0..<(width / 2) {
                    bytes[y * stride + x * 2] = shift
                    bytes[y * stride + x * 2 + 1] = 128
                }
            }
        }

        return pixelBuffer
    }
}
