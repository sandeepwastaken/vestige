// AVFoundation predates strict concurrency: AVAssetWriter and its inputs are
// not marked Sendable even though they are documented as safe to use from a
// single serial context, which is exactly how ClipWriter uses them.
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Muxes a `ReplaySnapshot` into an MP4 on disk.
///
/// The video track is written by passthrough: frames were compressed as they
/// were captured, so saving is a remux rather than a re-encode. That is what
/// makes it feel instant — a 120-second clip writes in well under a second
/// because no pixels are touched. Only audio is encoded, PCM to AAC.
///
/// `@unchecked Sendable` because `AVAssetWriter` and its inputs are not
/// `Sendable`, but a `ClipWriter` is created, used, and discarded by a single
/// task with all AVFoundation access confined to `writerQueue`.
final class ClipWriter: @unchecked Sendable {
    enum WriterError: LocalizedError {
        case emptySnapshot
        case noKeyframe
        case unsupportedFormat
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptySnapshot:
                "There was nothing in the replay buffer yet."
            case .noKeyframe:
                "The replay buffer is still filling up. Try again in a moment."
            case .unsupportedFormat:
                "The captured video format could not be written to MP4."
            case .writeFailed(let reason):
                "The clip could not be saved: \(reason)"
            }
        }
    }

    private let writerQueue = DispatchQueue(label: "app.vestige.clip-writer", qos: .userInitiated)

    /// Level applied to microphone audio when mixing it with system audio.
    /// Slightly below unity so game audio stays dominant by default.
    var microphoneGain: Float = 0.8

    /// Writes `snapshot` to `url`.
    ///
    /// If the audio track fails to encode, the clip is rewritten without audio
    /// rather than lost: a silent clip beats no clip.
    func write(_ snapshot: ReplaySnapshot, to url: URL) async throws {
        let hasAudio = !snapshot.audio.isEmpty || !snapshot.microphone.isEmpty
        do {
            try await performWrite(snapshot, to: url, includeAudio: hasAudio)
        } catch where hasAudio {
            Log.storage.notice("Falling back to a video-only clip after audio failure")
            try? FileManager.default.removeItem(at: url)
            try await performWrite(snapshot, to: url, includeAudio: false)
        }
    }

    private func performWrite(_ snapshot: ReplaySnapshot, to url: URL, includeAudio: Bool) async throws {
        guard !snapshot.video.isEmpty else { throw WriterError.emptySnapshot }

        let (videoFrames, formatDescription) = try Self.usableFrames(in: snapshot.video)

        // Timestamps come from the capture clock and are large host-time values.
        // Rebasing to zero keeps the file's timeline conventional.
        let timeOffset = videoFrames[0].presentationTime

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Puts the index at the front of the file so clips scrub immediately and
        // upload previews work before the whole file is read.
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = Self.metadata()

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw WriterError.unsupportedFormat }
        writer.add(videoInput)

        // Audio ending before the first video frame is dropped so the tracks
        // start together, unless that leaves nothing — slightly early audio
        // beats a silent clip. It is retimed against its own offset, normally
        // identical to the video's: when the clocks disagree, the video's
        // offset would place audio at a negative position and the writer would
        // discard every buffer without reporting anything.
        let videoEnd = CMTimeAdd(videoFrames[videoFrames.count - 1].presentationTime,
                                 videoFrames[videoFrames.count - 1].duration)
        let audioTimeOffset = Self.audioOffset(
            for: snapshot.audio,
            videoStart: timeOffset,
            videoEnd: videoEnd
        )

        let systemFrames = includeAudio
            ? Self.overlapping(snapshot.audio, after: audioTimeOffset, label: "system audio")
            : []
        let microphoneFrames = includeAudio
            ? Self.overlapping(snapshot.microphone, after: audioTimeOffset, label: "microphone")
            : []

        // With both sources present they are summed into one track. A single
        // track is what players, editors, and Discord all expect — a second
        // audio track would be silently ignored by most of them.
        let audioFrames: [CMSampleBuffer]
        if !systemFrames.isEmpty, !microphoneFrames.isEmpty,
           let mixed = AudioMixer.mix(
                system: systemFrames,
                microphone: microphoneFrames,
                from: timeOffset,
                duration: snapshot.duration,
                microphoneGain: microphoneGain
           ) {
            audioFrames = mixed
        } else {
            // Whichever one exists is written unchanged.
            audioFrames = (systemFrames.isEmpty ? microphoneFrames : systemFrames).map(\.sampleBuffer)
        }

        var audioInput: AVAssetWriterInput?
        if let first = audioFrames.first {
            if let settings = Self.audioSettings(for: first) {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                } else {
                    Log.storage.error("Writer rejected the audio track; clip will be silent")
                }
            } else {
                Log.storage.error("Could not derive AAC settings from the captured audio; clip will be silent")
            }
        } else if includeAudio {
            Log.storage.error("Audio was requested but no buffers reached the writer; clip will be silent")
        }

        // Enough to diagnose a silent clip from the log alone: whether audio
        // was buffered, whether it survived the overlap filter, and whether the
        // two clocks agree. Audio on a different timeline is retimed negative
        // and dropped by the writer, producing silence with no error anywhere.
        Log.storage.log("""
            Writing clip: video=\(videoFrames.count, privacy: .public) frames \
            audioBuffered=\(snapshot.audio.count, privacy: .public) \
            audioKept=\(audioFrames.count, privacy: .public) \
            audioTrack=\(audioInput != nil, privacy: .public) \
            videoStart=\(timeOffset.seconds, privacy: .public)s \
            audioStart=\(snapshot.audio.first?.presentationTime.seconds ?? -1, privacy: .public)s \
            audioEnd=\(snapshot.audio.last?.endTime.seconds ?? -1, privacy: .public)s
            """)

        guard writer.startWriting() else {
            throw WriterError.writeFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        // Both tracks must be pulled concurrently: AVAssetWriter interleaves as
        // it writes, so an input stops accepting until its counterpart catches
        // up, and feeding video to completion first would deadlock against an
        // audio track nobody is draining.
        let videoHandle = InputHandle(videoInput)
        let audioHandle = audioInput.map(InputHandle.init)

        let videoBatch = SampleBatch(videoFrames.map(\.sampleBuffer))
        let audioBatch = SampleBatch(audioFrames)

        async let videoDone: Void = feed(videoHandle, batch: videoBatch, offset: timeOffset)
        async let audioDone: Void = {
            guard let audioHandle else { return }
            try await feed(audioHandle, batch: audioBatch, offset: audioTimeOffset)
        }()

        do {
            _ = try await (videoDone, audioDone)
        } catch {
            writer.cancelWriting()
            throw error
        }

        await writer.finishWriting()

        if writer.status != .completed {
            throw WriterError.writeFailed(writer.error?.localizedDescription ?? "the file did not finish writing")
        }
    }

    /// The time audio should be rebased against.
    ///
    /// Normally the video's own start, which keeps the two in sync. When the
    /// audio range lies entirely outside the video range the streams are on
    /// different clocks, and the best repair is to align their starts: both
    /// were captured over the same wall-clock window, so their beginnings
    /// correspond even though their timestamps do not.
    private static func audioOffset(
        for audio: [BufferedAudioFrame],
        videoStart: CMTime,
        videoEnd: CMTime
    ) -> CMTime {
        guard let first = audio.first, let last = audio.last else { return videoStart }

        let isDisjoint = last.endTime <= videoStart || first.presentationTime >= videoEnd
        guard isDisjoint else { return videoStart }

        Log.storage.error("""
            Audio and video are on different timelines \
            (audio \(first.presentationTime.seconds, privacy: .public)s–\(last.endTime.seconds, privacy: .public)s, \
            video \(videoStart.seconds, privacy: .public)s–\(videoEnd.seconds, privacy: .public)s); \
            aligning their starts
            """)
        return first.presentationTime
    }

    /// Audio frames that overlap the clip, with a safety net.
    ///
    /// An empty result means a silent clip — a failure the user cannot
    /// diagnose. So a filter that would discard everything is treated as
    /// evidence the comparison is wrong, not that there is no audio.
    private static func overlapping(
        _ frames: [BufferedAudioFrame],
        after time: CMTime,
        label: String
    ) -> [BufferedAudioFrame] {
        guard !frames.isEmpty else { return [] }

        let kept = frames.filter { $0.endTime > time }
        if kept.isEmpty {
            Log.storage.error("""
                Every \(label, privacy: .public) frame fell outside the clip's \
                timeline (\(frames.count, privacy: .public) buffers); keeping them all \
                rather than writing a silent clip
                """)
            return frames
        }
        return kept
    }

    /// Selects the frames that can go into one passthrough track.
    ///
    /// Capture can restart mid-session (display change, sleep, encoder fault)
    /// and each encoder session has its own format description, while a
    /// passthrough track carries exactly one — so only the newest contiguous
    /// run sharing the final frame's format is usable, and it must begin on a
    /// keyframe or it decodes as garbage. Newest rather than largest is
    /// deliberate: the hotkey was pressed to capture what just happened.
    private static func usableFrames(
        in frames: [BufferedVideoFrame]
    ) throws -> ([BufferedVideoFrame], CMFormatDescription) {
        guard let last = frames.last,
              let format = CMSampleBufferGetFormatDescription(last.sampleBuffer)
        else { throw WriterError.emptySnapshot }

        var runStart = frames.count - 1
        while runStart > 0 {
            guard let previous = CMSampleBufferGetFormatDescription(frames[runStart - 1].sampleBuffer),
                  CMFormatDescriptionEqual(previous, otherFormatDescription: format)
            else { break }
            runStart -= 1
        }

        guard let keyframeIndex = frames[runStart...].firstIndex(where: \.isKeyframe) else {
            throw WriterError.noKeyframe
        }

        if runStart > 0 {
            Log.storage.notice("Clip truncated to \(frames.count - keyframeIndex) frames after an encoder restart")
        }

        return (Array(frames[keyframeIndex...]), format)
    }

    /// Pushes buffers into an input, honouring back-pressure.
    ///
    /// `requestMediaDataWhenReady` calls back whenever the input can accept
    /// more; appending past `isReadyForMoreMediaData` would grow an unbounded
    /// internal queue and defeat the point of streaming to disk.
    private func feed(_ handle: InputHandle, batch: SampleBatch, offset: CMTime) async throws {
        let input = handle.input
        let frames = batch.buffers

        guard !frames.isEmpty else {
            input.markAsFinished()
            return
        }

        let state = FeedState(frames: frames)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: writerQueue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = state.next() else {
                        input.markAsFinished()
                        state.finish { continuation.resume() }
                        return
                    }

                    guard let retimed = Self.retime(buffer, by: offset) else {
                        input.markAsFinished()
                        state.finish {
                            continuation.resume(throwing: WriterError.writeFailed("a frame could not be retimed"))
                        }
                        return
                    }

                    guard input.append(retimed) else {
                        input.markAsFinished()
                        state.finish {
                            continuation.resume(throwing: WriterError.writeFailed("the writer rejected a frame"))
                        }
                        return
                    }
                }
            }
        }
    }

    /// Carries sample buffers into the concurrent feed tasks. `CMSampleBuffer`
    /// is not `Sendable`, but these are immutable once produced and each batch
    /// is read by exactly one feed task.
    private struct SampleBatch: @unchecked Sendable {
        let buffers: [CMSampleBuffer]

        init(_ buffers: [CMSampleBuffer]) { self.buffers = buffers }
    }

    /// Carries an input into the concurrent feed tasks. Not `Sendable` either,
    /// but each is touched by one feed task and every call happens on
    /// `writerQueue`.
    private struct InputHandle: @unchecked Sendable {
        let input: AVAssetWriterInput

        init(_ input: AVAssetWriterInput) { self.input = input }
    }

    /// Cursor over the frames being fed, plus a latch so the continuation can
    /// only be resumed once. Confined to `writerQueue`.
    private final class FeedState: @unchecked Sendable {
        private let frames: [CMSampleBuffer]
        private var index = 0
        private var hasFinished = false

        init(frames: [CMSampleBuffer]) { self.frames = frames }

        func next() -> CMSampleBuffer? {
            guard index < frames.count else { return nil }
            defer { index += 1 }
            return frames[index]
        }

        func finish(_ body: () -> Void) {
            guard !hasFinished else { return }
            hasFinished = true
            body()
        }
    }

    /// Shifts every timestamp in a buffer back by `offset` so the clip starts at zero.
    private static func retime(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr else { return nil }

        var timings = [CMSampleTimingInfo](repeating: .invalid, count: max(count, 1))
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count
        ) == noErr else { return nil }

        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeSubtract(timings[index].presentationTimeStamp, offset)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(timings[index].decodeTimeStamp, offset)
            }
        }

        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &result
        ) == noErr else { return nil }

        return result
    }

    /// Derives AAC settings from the captured PCM stream so the output matches
    /// the system's actual sample rate and channel count.
    private static func audioSettings(for sampleBuffer: CMSampleBuffer) -> [String: Any]? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return nil }

        let channels = max(1, Int(description.mChannelsPerFrame))
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: description.mSampleRate > 0 ? description.mSampleRate : 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 2 ? 256_000 : 160_000
        ]

        // AAC requires an explicit channel layout for anything beyond stereo.
        if channels > 2 {
            var layoutSize = 0
            if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutSize) {
                settings[AVChannelLayoutKey] = Data(bytes: layout, count: layoutSize)
            } else {
                return nil
            }
        }

        return settings
    }

    private static func metadata() -> [AVMetadataItem] {
        let software = AVMutableMetadataItem()
        software.identifier = .commonIdentifierSoftware
        software.value = "Vestige" as NSString

        let created = AVMutableMetadataItem()
        created.identifier = .commonIdentifierCreationDate
        created.value = ISO8601DateFormatter().string(from: .now) as NSString

        return [software, created]
    }
}
