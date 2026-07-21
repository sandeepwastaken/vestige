import CoreMedia
import Foundation

/// A fixed-duration circular buffer of encoded video and PCM audio.
///
/// **A lock, not an actor.** Frames arrive from two threads — VideoToolbox's
/// encoder callback and ScreenCaptureKit's audio queue — and order within each
/// stream must be preserved. Reaching an actor needs a `Task` per append, and
/// concurrent tasks are not guaranteed to arrive in creation order, so frames
/// would interleave. A lock keeps appends synchronous on the calling thread,
/// preserving order by construction and costing less per frame.
///
/// **Trimming is keyframe-aligned.** A clip can only begin at a keyframe, so
/// the buffer never drops past the newest keyframe older than the retention
/// window, holding between `duration` and `duration + keyframeInterval`.
final class ReplayBuffer: @unchecked Sendable {
    struct Statistics: Equatable, Sendable {
        var bufferedSeconds: Double = 0
        var frameCount: Int = 0
        var byteCount: Int = 0

        /// Audio buffers currently retained, and how much wall time they cover.
        var audioFrameCount: Int = 0
        var audioSeconds: Double = 0
        var audioDroppedCount: Int = 0
    }

    private let lock = NSLock()
    private var video: [BufferedVideoFrame] = []
    private var audio: [BufferedAudioFrame] = []

    /// Microphone audio is kept in its own timeline rather than mixed on
    /// arrival, so the two sources stay independent until a clip is saved.
    /// Turning the microphone off mid-session then cannot retroactively
    /// contaminate footage already buffered.
    private var microphone: [BufferedAudioFrame] = []

    private var videoBytes = 0
    private var audioBytes = 0
    private var microphoneBytes = 0

    /// Running totals, for diagnosing audio that goes missing between capture
    /// and the saved clip.
    private var audioAppends = 0
    private var audioDropped = 0

    /// Retention window in seconds.
    private let targetDuration: Double

    /// Hard ceiling on resident bytes, enforced even if it means holding less
    /// than `targetDuration`. Without this, a scene the encoder finds hard to
    /// compress could grow the buffer far past its expected footprint.
    private let byteBudget: Int

    /// - Parameters:
    ///   - duration: seconds of footage to retain.
    ///   - bitrate: the encoder's target bitrate, used to size the memory ceiling.
    init(duration: Double, bitrate: Int) {
        self.targetDuration = duration

        let expectedVideoBytes = Double(bitrate) / 8.0 * duration
        // 2x headroom for bitrate overshoot, plus a flat allowance for audio.
        self.byteBudget = Int(expectedVideoBytes * 2) + 64 * 1024 * 1024
    }

    // MARK: - Ingest

    func append(_ frame: BufferedVideoFrame) {
        lock.lock()
        defer { lock.unlock() }

        // A backwards timestamp means the capture clock restarted underneath us
        // (stream teardown, display change). Keeping both halves would produce a
        // clip that seeks unpredictably, so start clean.
        if let last = video.last, frame.presentationTime < last.presentationTime {
            Log.buffer.error("""
                Capture timeline moved backwards \
                (\(last.presentationTime.seconds, privacy: .public)s -> \
                \(frame.presentationTime.seconds, privacy: .public)s); clearing buffer
                """)
            resetLocked()
        }

        video.append(frame)
        videoBytes += frame.byteCount
        trimLocked()
    }

    func appendMicrophone(_ frame: BufferedAudioFrame) {
        lock.lock()
        defer { lock.unlock() }

        microphone.append(frame)
        microphoneBytes += frame.byteCount

        // Trimmed against the video window like system audio, with the same
        // standalone fallback when video has stalled.
        if let first = video.first {
            trimMicrophoneLocked(before: first.presentationTime)
        } else {
            trimMicrophoneLocked(
                before: CMTimeSubtract(
                    frame.presentationTime,
                    CMTime(seconds: targetDuration, preferredTimescale: 600)
                )
            )
        }
    }

    func append(_ frame: BufferedAudioFrame) {
        lock.lock()
        defer { lock.unlock() }

        audio.append(frame)
        audioBytes += frame.byteCount
        audioAppends += 1

        // Reports what the buffer actually holds, roughly every five seconds of
        // audio. Kept because a clip once came back with 1.3 seconds of sound
        // while capture was demonstrably delivering continuously, with no way
        // to see where it went. Debug level so it is not persisted to disk all
        // session; `log stream --level debug` still shows it live.
        if audioAppends % 250 == 0 {
            let span = audio.isEmpty ? 0 : CMTimeGetSeconds(
                CMTimeSubtract(audio[audio.count - 1].endTime, audio[0].presentationTime)
            )
            let videoSpan = video.isEmpty ? 0 : CMTimeGetSeconds(
                CMTimeSubtract(video[video.count - 1].presentationTime, video[0].presentationTime)
            )
            Log.buffer.debug("""
                Buffer: audio=\(self.audio.count, privacy: .public) frames \
                (\(span, privacy: .public)s) \
                video=\(self.video.count, privacy: .public) frames \
                (\(videoSpan, privacy: .public)s) \
                appended=\(self.audioAppends, privacy: .public) \
                droppedAudio=\(self.audioDropped, privacy: .public)
                """)
        }

        // Audio is trimmed against the video window, but if video has stalled
        // entirely we still bound audio on its own so memory cannot creep.
        if video.isEmpty {
            trimAudioLocked(before: CMTimeSubtract(frame.presentationTime, CMTime(seconds: targetDuration, preferredTimescale: 600)))
        }
    }

    // MARK: - Reading

    /// Takes an immutable copy of the current contents. Cheap: the arrays hold
    /// references, so this copies pointers rather than frame data.
    func snapshot() -> ReplaySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ReplaySnapshot(video: video, audio: audio, microphone: microphone)
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }

        var seconds = 0.0
        if let first = video.first, let last = video.last {
            let end = CMTimeAdd(last.presentationTime, last.duration)
            seconds = CMTimeGetSeconds(CMTimeSubtract(end, first.presentationTime))
        }
        var audioSeconds = 0.0
        if let first = audio.first, let last = audio.last {
            audioSeconds = CMTimeGetSeconds(CMTimeSubtract(last.endTime, first.presentationTime))
        }

        return Statistics(
            bufferedSeconds: max(0, seconds),
            frameCount: video.count,
            byteCount: videoBytes + audioBytes + microphoneBytes,
            audioFrameCount: audio.count,
            audioSeconds: max(0, audioSeconds),
            audioDroppedCount: audioDropped
        )
    }

    // MARK: - Trimming

    private func trimLocked() {
        guard let last = video.last else { return }

        let end = CMTimeAdd(last.presentationTime, last.duration)
        let cutoff = CMTimeSubtract(end, CMTime(seconds: targetDuration, preferredTimescale: 600))

        // Scan only the frames that have aged out — at most one keyframe
        // interval's worth, because this runs on every append.
        var dropCount = 0
        var index = 0
        while index < video.count, video[index].presentationTime <= cutoff {
            if video[index].isKeyframe { dropCount = index }
            index += 1
        }
        dropVideoLocked(dropCount)

        // Memory ceiling: keep discarding whole keyframe segments until we fit.
        while videoBytes + audioBytes + microphoneBytes > byteBudget, let next = nextKeyframeIndexLocked() {
            Log.buffer.notice("Replay buffer over budget; dropping \(next) frames")
            dropVideoLocked(next)
        }

        if let first = video.first {
            trimAudioLocked(before: first.presentationTime)
            trimMicrophoneLocked(before: first.presentationTime)
        }
    }

    /// Index of the second keyframe in the buffer — i.e. how many frames to drop
    /// to discard exactly one leading segment while still starting on a keyframe.
    private func nextKeyframeIndexLocked() -> Int? {
        guard video.count > 1 else { return nil }
        for index in 1..<video.count where video[index].isKeyframe {
            return index
        }
        return nil
    }

    private func dropVideoLocked(_ count: Int) {
        guard count > 0, count <= video.count else { return }
        for index in 0..<count {
            videoBytes -= video[index].byteCount
        }
        video.removeFirst(count)
        videoBytes = max(0, videoBytes)
    }

    /// Drops audio that ends before the first retained video frame begins.
    private func trimAudioLocked(before time: CMTime) {
        var dropCount = 0
        while dropCount < audio.count {
            let frame = audio[dropCount]
            guard CMTimeAdd(frame.presentationTime, frame.duration) < time else { break }
            audioBytes -= frame.byteCount
            dropCount += 1
        }
        if dropCount > 0 {
            audio.removeFirst(dropCount)
            audioBytes = max(0, audioBytes)
            audioDropped += dropCount
        }
    }

    private func trimMicrophoneLocked(before time: CMTime) {
        var dropCount = 0
        while dropCount < microphone.count {
            let frame = microphone[dropCount]
            guard CMTimeAdd(frame.presentationTime, frame.duration) < time else { break }
            microphoneBytes -= frame.byteCount
            dropCount += 1
        }
        if dropCount > 0 {
            microphone.removeFirst(dropCount)
            microphoneBytes = max(0, microphoneBytes)
        }
    }

    private func resetLocked() {
        video.removeAll(keepingCapacity: true)
        audio.removeAll(keepingCapacity: true)
        microphone.removeAll(keepingCapacity: true)
        videoBytes = 0
        audioBytes = 0
        microphoneBytes = 0
    }
}
