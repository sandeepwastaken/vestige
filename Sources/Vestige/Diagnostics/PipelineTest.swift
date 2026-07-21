import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// Runs the app's real capture pipeline and reports what the ring buffer holds.
///
/// Run with `Vestige --pipeline-test`.
///
/// Assembles exactly the components the app does, so the buffer's contents can
/// be read directly rather than inferred from a finished clip. Written while
/// tracking down clips that held 1.3 seconds of audio despite capture
/// delivering it continuously — the gap between "audio arrived" and "audio
/// reached the file" is invisible from outside, and this is where it shows.
enum PipelineTest {
    private static let seconds = 25

    static func runAndExit() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var healthy = false

        Task {
            healthy = await run()
            semaphore.signal()
        }
        semaphore.wait()

        exit(healthy ? 0 : 1)
    }

    private static func run() async -> Bool {
        print("Vestige pipeline test\n")
        print("Play some audio. Watching the replay buffer for \(seconds) seconds.\n")

        // A 60-second retention window, so nothing should be trimmed during
        // this run and every captured buffer should still be present at the end.
        let buffer = ReplayBuffer(duration: 60, bitrate: 12_000_000)

        // Counted before the buffer sees them, to separate "the stream stopped
        // delivering" from "the buffer refused them".
        let delivered = Counter()
        let rejected = Counter()

        // Two arrangements to compare: separate audio and video streams (what
        // the app does now), or a single stream carrying both.
        let singleStream = CommandLine.arguments.contains("--single-stream")
        print(singleStream ? "Mode: ONE stream carrying video and audio\n"
                           : "Mode: TWO streams, audio separate from video\n")

        var audioStream: SystemAudioStream?
        var videoStream: SCStream?
        var encoder: VideoEncoder?

        let onAudio: @Sendable (CMSampleBuffer) -> Void = { sampleBuffer in
            delivered.increment()
            guard let frame = BufferedAudioFrame(sampleBuffer: sampleBuffer) else {
                rejected.increment()
                return
            }
            buffer.append(frame)
        }

        if !singleStream {
            let stream = SystemAudioStream(
                onSample: onAudio,
                onStop: { error in
                    print("  !! audio stream stopped: \(error?.localizedDescription ?? "no error")")
                }
            )
            do {
                try await stream.start()
                audioStream = stream
            } catch {
                print("Could not start audio: \(error.localizedDescription)")
                return false
            }
        }

        do {
            let (stream, videoEncoder) = try await startVideo(
                into: buffer,
                capturingAudio: singleStream ? onAudio : nil
            )
            videoStream = stream
            encoder = videoEncoder
        } catch {
            print("Could not start video: \(error.localizedDescription)")
        }

        print("second  video  delivered  inBuffer  dropped  rejected")
        for second in 1...seconds {
            try? await Task.sleep(for: .seconds(1))
            let stats = buffer.statistics
            print(String(
                format: "%5d  %6d  %9d  %8d  %7d  %8d",
                second, stats.frameCount, delivered.value, stats.audioFrameCount,
                stats.audioDroppedCount, rejected.value
            ))
        }

        if let audioStream { await audioStream.stop() }
        if let videoStream { try? await videoStream.stopCapture() }
        encoder?.invalidate()

        let final = buffer.statistics
        print("")
        print("Video frames  : \(final.frameCount) over \(String(format: "%.1f", final.bufferedSeconds))s")
        print("Audio buffers : \(final.audioFrameCount) covering \(String(format: "%.2f", final.audioSeconds))s")
        print("Audio dropped : \(final.audioDroppedCount)")

        // Roughly 50 buffers a second should have survived, since the retention
        // window is longer than the run.
        let expected = Double(seconds) * 40
        let healthy = Double(final.audioFrameCount) >= expected

        print("")
        if healthy {
            print("The buffer is retaining audio correctly.")
        } else if final.audioDroppedCount > 0 {
            print("""
            The buffer is discarding audio.

            \(final.audioDroppedCount) buffers were trimmed away despite a 60-second
            retention window and a \(seconds)-second run. The trim is comparing audio
            against the video timeline incorrectly.
            """)
        } else {
            print("""
            Audio stopped arriving.

            Nothing was trimmed, so the buffers were simply never delivered —
            the audio stream stalls when run alongside the rest of the pipeline.
            """)
        }

        return healthy
    }

    private static func startVideo(
        into buffer: ReplayBuffer,
        capturingAudio onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    ) async throws -> (SCStream, VideoEncoder) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplaysAvailable }

        let configuration = SCStreamConfiguration()
        configuration.width = 1280
        configuration.height = 720
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 6
        configuration.capturesAudio = onAudio != nil
        if onAudio != nil {
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true
        }

        let encoder = try VideoEncoder.make(
            configuration: EncoderConfiguration(width: 1280, height: 720, frameRate: 60, codec: .hevc),
            onFrame: { buffer.append($0) },
            onFailure: { print("  !! encoder error: \($0.localizedDescription)") }
        )

        let sink = VideoSink(
            onVideo: { sampleBuffer in
                guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                encoder.encode(
                    image,
                    presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                    duration: CMTime(value: 1, timescale: 60)
                )
            },
            onAudio: onAudio
        )

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "pipeline-test.video"))
        if onAudio != nil {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "pipeline-test.audio"))
        }
        try await stream.startCapture()

        retainedSink = sink
        return (stream, encoder)
    }

    private nonisolated(unsafe) static var retainedSink: AnyObject?

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private final class VideoSink: NSObject, SCStreamOutput, @unchecked Sendable {
        private let onVideo: @Sendable (CMSampleBuffer) -> Void
        private let onAudio: (@Sendable (CMSampleBuffer) -> Void)?

        init(
            onVideo: @escaping @Sendable (CMSampleBuffer) -> Void,
            onAudio: (@Sendable (CMSampleBuffer) -> Void)?
        ) {
            self.onVideo = onVideo
            self.onAudio = onAudio
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            switch type {
            case .screen: onVideo(sampleBuffer)
            case .audio: onAudio?(sampleBuffer)
            default: break
            }
        }
    }
}
