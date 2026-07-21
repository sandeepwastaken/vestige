@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Combines system audio and microphone audio into a single PCM track.
///
/// Mixing happens when a clip is saved, not while capturing: both streams sit
/// in the ring buffer as raw PCM, so a session with the microphone enabled
/// costs no more CPU than one without until the hotkey is pressed.
///
/// Both inputs are 48 kHz stereo 32-bit float, non-interleaved — ScreenCaptureKit
/// is configured to produce that and `MicrophoneCapture` converts to it — so
/// combining them is sample addition, with no resampling or format negotiation.
enum AudioMixer {
    /// Frames per output buffer. 100 ms is long enough that per-buffer overhead
    /// is irrelevant and short enough to keep working memory trivial.
    static let framesPerChunk = 4_800

    static let channelCount = 2
    static let sampleRate = 48_000.0

    /// The PCM format both sources are normalised to, and the mixer emits.
    static func makeFormatDescription() -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr else { return nil }

        return format
    }

    /// Reads a buffer's channels, handing them to `body` as raw pointers.
    ///
    /// `AudioBufferList` is variable-length: the Swift type has inline room for
    /// exactly one `AudioBuffer`, and non-interleaved stereo needs two. Putting
    /// one on the stack and writing a second channel walks off the end of the
    /// struct. `AudioBufferList.allocate` sizes it correctly.
    private static func withChannels<T>(
        of sampleBuffer: CMSampleBuffer,
        _ body: (UnsafeMutableAudioBufferListPointer, Int) -> T
    ) -> T? {
        let list = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(list.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let frames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        return body(list, frames)
    }

    /// Deep-copies an audio buffer into memory Vestige owns.
    ///
    /// **Not optional.** ScreenCaptureKit and AVFoundation vend sample buffers
    /// from a fixed pool, and once it is exhausted they **stop delivering** —
    /// no error, no callback, nothing to notice. The replay buffer retains
    /// audio for minutes, so it drained that pool in about a second: capture
    /// froze at 62 buffers (1.24s) every time and clips came out silent. Video
    /// escaped only because encoded frames are the encoder's own allocations.
    /// An allocation and a memcpy per 20 ms is a trivial price for handing the
    /// framework its buffers straight back.
    static func copy(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }

        var left: [Float] = []
        var right: [Float] = []

        let frames = withChannels(of: sampleBuffer) { buffers, count -> Int in
            guard count > 0, buffers.count > 0, let first = buffers[0].mData else { return 0 }

            let leftSamples = first.assumingMemoryBound(to: Float.self)
            left = Array(UnsafeBufferPointer(start: leftSamples, count: count))

            if buffers.count > 1, let second = buffers[1].mData {
                let rightSamples = second.assumingMemoryBound(to: Float.self)
                right = Array(UnsafeBufferPointer(start: rightSamples, count: count))
            } else {
                // Mono source: both output channels carry the same samples.
                right = left
            }
            return count
        } ?? 0

        guard frames > 0 else { return nil }

        return makeSampleBuffer(
            left: left,
            right: right,
            frames: frames,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            format: format
        )
    }

    /// Reads a mixed buffer back into channel arrays, for verification.
    static func extractChannels(from sampleBuffer: CMSampleBuffer) -> [[Float]] {
        withChannels(of: sampleBuffer) { buffers, frames in
            (0..<buffers.count).map { channel -> [Float] in
                guard let data = buffers[channel].mData else { return [] }
                let samples = data.assumingMemoryBound(to: Float.self)
                return (0..<frames).map { samples[$0] }
            }
        } ?? []
    }

    /// Mixes two PCM streams into one.
    ///
    /// Returns `nil` when there is nothing to mix, letting the caller fall back
    /// to writing whichever single stream it has without paying for a copy.
    static func mix(
        system: [BufferedAudioFrame],
        microphone: [BufferedAudioFrame],
        from startTime: CMTime,
        duration: Double,
        microphoneGain: Float
    ) -> [CMSampleBuffer]? {
        guard !system.isEmpty, !microphone.isEmpty, duration > 0 else { return nil }

        guard let format = CMSampleBufferGetFormatDescription(system[0].sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else {
            Log.storage.notice("Cannot mix audio: unexpected system audio format")
            return nil
        }

        let totalFrames = Int(duration * sampleRate)
        guard totalFrames > 0 else { return nil }

        var output: [CMSampleBuffer] = []
        output.reserveCapacity(totalFrames / framesPerChunk + 1)

        // Cursors into each source. Both are in presentation order, so each
        // chunk resumes where the last left off instead of rescanning.
        var systemCursor = 0
        var microphoneCursor = 0

        var left = [Float](repeating: 0, count: framesPerChunk)
        var right = [Float](repeating: 0, count: framesPerChunk)

        var chunkStart = 0
        while chunkStart < totalFrames {
            let frames = min(framesPerChunk, totalFrames - chunkStart)

            for index in 0..<frames {
                left[index] = 0
                right[index] = 0
            }

            let chunkStartTime = CMTimeAdd(
                startTime,
                CMTime(value: CMTimeValue(chunkStart), timescale: CMTimeScale(sampleRate))
            )

            accumulate(system, cursor: &systemCursor, into: &left, and: &right,
                       frames: frames, chunkStartTime: chunkStartTime, gain: 1.0)
            accumulate(microphone, cursor: &microphoneCursor, into: &left, and: &right,
                       frames: frames, chunkStartTime: chunkStartTime, gain: microphoneGain)

            // Summing two full-scale sources can exceed ±1.0. Hard clipping
            // would be audible as crackle on every loud moment, so samples past
            // the threshold are compressed toward the limit instead.
            softLimit(&left, count: frames)
            softLimit(&right, count: frames)

            if let buffer = makeSampleBuffer(
                left: left, right: right, frames: frames,
                presentationTime: chunkStartTime, format: format
            ) {
                output.append(buffer)
            }

            chunkStart += frames
        }

        return output.isEmpty ? nil : output
    }

    /// Adds whatever part of `source` overlaps this chunk into the accumulators.
    private static func accumulate(
        _ source: [BufferedAudioFrame],
        cursor: inout Int,
        into left: inout [Float],
        and right: inout [Float],
        frames: Int,
        chunkStartTime: CMTime,
        gain: Float
    ) {
        let chunkStartSeconds = CMTimeGetSeconds(chunkStartTime)
        let chunkEndSeconds = chunkStartSeconds + Double(frames) / sampleRate

        // Skip anything that ended before this chunk began. The cursor only
        // moves forward, so this stays linear across the whole clip.
        while cursor < source.count {
            let frame = source[cursor]
            let end = CMTimeGetSeconds(CMTimeAdd(frame.presentationTime, frame.duration))
            if end <= chunkStartSeconds { cursor += 1 } else { break }
        }

        var index = cursor
        while index < source.count {
            let frame = source[index]
            let frameStart = CMTimeGetSeconds(frame.presentationTime)
            if frameStart >= chunkEndSeconds { break }

            copy(frame, into: &left, and: &right, frames: frames,
                 chunkStartSeconds: chunkStartSeconds, gain: gain)
            index += 1
        }
    }

    private static func copy(
        _ frame: BufferedAudioFrame,
        into left: inout [Float],
        and right: inout [Float],
        frames: Int,
        chunkStartSeconds: Double,
        gain: Float
    ) {
        // Where this frame's audio begins relative to the chunk.
        let offset = Int((CMTimeGetSeconds(frame.presentationTime) - chunkStartSeconds) * sampleRate)

        var leftAccumulator = left
        var rightAccumulator = right

        withChannels(of: frame.sampleBuffer) { buffers, available in
            guard buffers.count > 0, available > 0 else { return }

            for channel in 0..<min(buffers.count, channelCount) {
                guard let data = buffers[channel].mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)

                for sampleIndex in 0..<available {
                    let destination = offset + sampleIndex
                    guard destination >= 0, destination < frames else { continue }

                    let value = samples[sampleIndex] * gain
                    if channel == 0 {
                        leftAccumulator[destination] += value
                    } else {
                        rightAccumulator[destination] += value
                    }
                }
            }

            // A mono source feeds both channels, or one side would be silent.
            if buffers.count == 1, let data = buffers[0].mData {
                let samples = data.assumingMemoryBound(to: Float.self)
                for sampleIndex in 0..<available {
                    let destination = offset + sampleIndex
                    guard destination >= 0, destination < frames else { continue }
                    rightAccumulator[destination] += samples[sampleIndex] * gain
                }
            }
        }

        left = leftAccumulator
        right = rightAccumulator
    }

    /// Compresses peaks above 0.8 into the remaining headroom, leaving quieter
    /// material untouched.
    private static func softLimit(_ samples: inout [Float], count: Int) {
        let threshold: Float = 0.8
        for index in 0..<count {
            let value = samples[index]
            let magnitude = abs(value)
            guard magnitude > threshold else { continue }

            let excess = magnitude - threshold
            let limited = threshold + excess / (1 + excess / (1 - threshold))
            samples[index] = value < 0 ? -limited : limited
        }
    }

    /// Builds a PCM sample buffer from separate channel arrays.
    ///
    /// Not private so `--self-test` can synthesise input and inspect output:
    /// this does raw pointer work on the save path, so exercising it directly
    /// is worth the wider visibility.
    static func makeSampleBuffer(
        left: [Float],
        right: [Float],
        frames: Int,
        presentationTime: CMTime,
        format: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        // Defence in depth: every current caller guards this, but the unsafe
        // pointer work below would read out of bounds (or force-unwrap a nil
        // base address) if a future caller passed empty or short arrays.
        guard frames > 0, left.count >= frames, right.count >= frames else { return nil }

        let bytesPerChannel = frames * MemoryLayout<Float>.size

        let leftData = UnsafeMutableRawPointer.allocate(
            byteCount: bytesPerChannel, alignment: MemoryLayout<Float>.alignment)
        let rightData = UnsafeMutableRawPointer.allocate(
            byteCount: bytesPerChannel, alignment: MemoryLayout<Float>.alignment)

        left.withUnsafeBufferPointer { leftData.copyMemory(from: $0.baseAddress!, byteCount: bytesPerChannel) }
        right.withUnsafeBufferPointer { rightData.copyMemory(from: $0.baseAddress!, byteCount: bytesPerChannel) }

        // Correctly sized for two channels. A stack-declared AudioBufferList
        // has inline room for one buffer only, so assigning a second channel
        // into it would write past the end of the structure.
        let audioBufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(audioBufferList.unsafeMutablePointer) }

        audioBufferList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(bytesPerChannel),
            mData: leftData
        )
        audioBufferList[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(bytesPerChannel),
            mData: rightData
        )

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard createStatus == noErr, let sampleBuffer else {
            leftData.deallocate()
            rightData.deallocate()
            return nil
        }

        // Copies the samples into the buffer's own storage, after which the
        // scratch allocations above are no longer referenced.
        let attachStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            bufferList: audioBufferList.unsafePointer
        )

        leftData.deallocate()
        rightData.deallocate()

        guard attachStatus == noErr else { return nil }

        // The buffer was created before its data existed, so it has to be
        // marked ready or every consumer will reject it as incomplete.
        CMSampleBufferSetDataReady(sampleBuffer)
        return sampleBuffer
    }
}
