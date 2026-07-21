import CoreMedia

/// A single encoded video frame waiting in the replay buffer.
///
/// `CMSampleBuffer` is a Core Foundation type and so not `Sendable` to the
/// compiler. Crossing that boundary is safe here because once VideoToolbox
/// hands a compressed frame to its output callback the buffer is immutable and
/// solely ours: frames are appended, read, and released, never mutated.
struct BufferedVideoFrame: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let presentationTime: CMTime
    let duration: CMTime

    /// Sync samples (keyframes) are the only points a clip may begin at, since
    /// every other frame is coded as a difference from what came before.
    let isKeyframe: Bool
    let byteCount: Int

    init?(sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }

        self.sampleBuffer = sampleBuffer
        self.presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        self.duration = CMSampleBufferGetDuration(sampleBuffer)
        self.byteCount = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        self.isKeyframe = Self.isSyncSample(sampleBuffer)
    }

    /// A frame is a keyframe unless its attachments mark it as depending on
    /// earlier frames. Buffers with no attachment array count as keyframes,
    /// matching VideoToolbox's own convention.
    private static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0
        else { return true }

        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFDictionary.self)

        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        var value: UnsafeRawPointer?
        guard CFDictionaryGetValueIfPresent(dictionary, key, &value), let value else {
            return true
        }
        return !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }
}

/// A chunk of PCM system audio waiting in the replay buffer.
///
/// Buffered uncompressed and encoded to AAC only when a clip is saved. At
/// 48 kHz stereo that is roughly 380 KB per second — about 45 MB for a
/// two-minute buffer, cheap next to the video, and it avoids running a second
/// real-time encoder all session.
struct BufferedAudioFrame: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let presentationTime: CMTime
    let duration: CMTime
    let byteCount: Int

    /// Builds a buffered frame, copying the audio out of the framework's pool.
    ///
    /// The copy is mandatory, not defensive. ScreenCaptureKit and AVFoundation
    /// vend audio from a fixed pool and stop delivering — silently, no error —
    /// once too many buffers are held. A ring buffer holding minutes of audio
    /// exhausts that pool in about a second, which is what produced
    /// 1.24-second audio tracks in 30-second clips. See `AudioMixer.copy`.
    init?(sampleBuffer incoming: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(incoming),
              let sampleBuffer = AudioMixer.copy(incoming)
        else { return nil }

        self.sampleBuffer = sampleBuffer
        self.presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // `CMSampleBufferGetDuration` reports invalid for some audio buffers,
        // so it is rebuilt from the sample count. Leaving it invalid is not
        // harmless: `CMTimeAdd` with an invalid operand yields an invalid
        // result, and an invalid `CMTime` compares false against everything —
        // silently discarding every audio frame downstream.
        let reported = CMSampleBufferGetDuration(sampleBuffer)
        if reported.isValid, reported.seconds > 0 {
            self.duration = reported
        } else {
            let samples = CMSampleBufferGetNumSamples(sampleBuffer)
            let rate = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
                ?? 48_000
            self.duration = samples > 0 && rate > 0
                ? CMTime(value: CMTimeValue(samples), timescale: CMTimeScale(rate))
                : .zero
        }

        self.byteCount = max(
            CMSampleBufferGetTotalSampleSize(sampleBuffer),
            CMSampleBufferGetNumSamples(sampleBuffer) * 8
        )
    }

    /// When this frame's audio ends. Always valid, so range comparisons are safe.
    var endTime: CMTime {
        CMTimeAdd(presentationTime, duration)
    }
}

/// An immutable copy of the buffer's contents, taken the instant the user hits
/// the hotkey. Capture keeps running against the live buffer while this is
/// written out.
struct ReplaySnapshot: @unchecked Sendable {
    let video: [BufferedVideoFrame]
    let audio: [BufferedAudioFrame]
    let microphone: [BufferedAudioFrame]

    init(
        video: [BufferedVideoFrame],
        audio: [BufferedAudioFrame],
        microphone: [BufferedAudioFrame] = []
    ) {
        self.video = video
        self.audio = audio
        self.microphone = microphone
    }

    var isEmpty: Bool { video.isEmpty }

    /// Keeps only the final `seconds` of the snapshot.
    ///
    /// The cut lands on the newest keyframe at or before the requested point,
    /// because a clip starting anywhere else cannot decode. The result is
    /// therefore never shorter than asked for and up to one keyframe interval
    /// longer, erring toward keeping too much.
    func trimmed(toLast seconds: Double) -> ReplaySnapshot {
        guard let last = video.last, seconds > 0 else { return self }

        let end = CMTimeAdd(last.presentationTime, last.duration)
        let cutoff = CMTimeSubtract(end, CMTime(seconds: seconds, preferredTimescale: 600))

        var startIndex = 0
        for index in video.indices where video[index].isKeyframe {
            if video[index].presentationTime <= cutoff {
                startIndex = index
            } else {
                break
            }
        }

        guard startIndex > 0 else { return self }

        let keptVideo = Array(video[startIndex...])
        guard let firstTime = keptVideo.first?.presentationTime else { return self }

        return ReplaySnapshot(
            video: keptVideo,
            audio: audio.filter { CMTimeAdd($0.presentationTime, $0.duration) > firstTime },
            microphone: microphone.filter { CMTimeAdd($0.presentationTime, $0.duration) > firstTime }
        )
    }

    /// Wall-clock length of the snapshot.
    var duration: Double {
        guard let first = video.first, let last = video.last else { return 0 }
        let end = CMTimeAdd(last.presentationTime, last.duration)
        return CMTimeGetSeconds(CMTimeSubtract(end, first.presentationTime))
    }
}
