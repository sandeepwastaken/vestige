import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Measures ScreenCaptureKit's system-audio delivery in isolation.
///
/// Run with `Vestige --audio-test` while sound is playing.
///
/// The capture stream is the only moving part here, so if delivery stalls it
/// stalls with nothing else to blame. Written to settle whether a clip holding
/// 1.3 seconds of audio out of 30 was ScreenCaptureKit's fault or Vestige's.
enum AudioTest {
    private static let duration = 15

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
        // Reproduces the app's actual arrangement when asked to. Audio capture
        // succeeded in isolation while failing inside Vestige, and the only
        // structural difference was a second ScreenCaptureKit stream running
        // alongside it for video. This makes that difference testable.
        let withVideo = CommandLine.arguments.contains("--with-video")

        print("Vestige system audio test\n")
        print("Play some audio now — music, a video, or the game.")
        if withVideo {
            print("Running a concurrent video stream, as the app does.")
        }
        print("Sampling for \(duration) seconds.\n")

        var videoStream: SCStream?
        if withVideo {
            do {
                videoStream = try await startVideoStream()
                print("Video stream started.\n")
            } catch {
                print("Could not start the video stream: \(error.localizedDescription)\n")
            }
        }
        let counter = BufferCounter()

        let stream = SystemAudioStream(
            onSample: { sampleBuffer in
                counter.record(
                    samples: Int(CMSampleBufferGetNumSamples(sampleBuffer)),
                    presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                )
            },
            onStop: { error in
                counter.recordStop(error)
            }
        )

        do {
            try await stream.start()
        } catch {
            print("Could not start the audio stream: \(error.localizedDescription)")
            return false
        }

        print("second  buffers  samples")
        for second in 1...duration {
            try? await Task.sleep(for: .seconds(1))
            let slice = counter.takeSlice()
            let bar = String(repeating: "#", count: min(slice.buffers / 2, 40))
            print(String(format: "%5d   %6d   %6d  %@", second, slice.buffers, slice.samples, bar))
        }

        await stream.stop()
        if let videoStream {
            try? await videoStream.stopCapture()
        }

        let total = counter.total()
        print("")
        print("Total buffers : \(total.buffers)")
        print("Total samples : \(total.samples)")
        print(String(format: "Audio captured: %.2fs of %ds", Double(total.samples) / 48_000, duration))

        if let stopError = counter.stopError {
            print("\nStream stopped early: \(stopError)")
        }

        // Continuous 48 kHz delivery is roughly 50 buffers a second. Anything
        // near that is healthy; a burst that dies is the failure being hunted.
        let expected = Double(duration) * 40
        let healthy = Double(total.buffers) >= expected

        print("")
        if healthy {
            print("Audio delivery looks continuous.")
        } else if total.buffers == 0 {
            print("""
            No audio at all.

            ScreenCaptureKit never delivered a single buffer. Either nothing was
            playing, or the system output is routed somewhere it cannot observe —
            a virtual device such as VB-Cable or Audio Routing Kit set as the
            default output would do exactly this.
            """)
        } else {
            print("""
            Audio delivery stalled.

            Buffers arrived and then stopped, which is the same pattern that
            produced a 1.3-second audio track in a 30-second clip. This is
            ScreenCaptureKit's own behaviour: nothing else is running here.
            """)
        }

        return healthy
    }

    /// A plain video-only stream, standing in for the app's capture stream.
    private static func startVideoStream() async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplaysAvailable }

        let configuration = SCStreamConfiguration()
        configuration.width = 1280
        configuration.height = 720
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 6
        configuration.capturesAudio = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        let sink = VideoSink()
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "audio-test.video"))
        try await stream.startCapture()

        // The sink must outlive this function; SCStream holds outputs weakly.
        retainedSink = sink
        return stream
    }

    private nonisolated(unsafe) static var retainedSink: AnyObject?

    /// Discards video frames; only its existence matters for the test.
    private final class VideoSink: NSObject, SCStreamOutput, @unchecked Sendable {
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
    }

    /// Tallies buffers, split into one-second slices.
    private final class BufferCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var sliceBuffers = 0
        private var sliceSamples = 0
        private var totalBuffers = 0
        private var totalSamples = 0
        private(set) var stopError: String?

        func record(samples: Int, presentationTime: CMTime) {
            lock.lock()
            sliceBuffers += 1
            sliceSamples += samples
            totalBuffers += 1
            totalSamples += samples
            lock.unlock()
        }

        func recordStop(_ error: Error?) {
            lock.lock()
            stopError = error?.localizedDescription ?? "no error given"
            lock.unlock()
        }

        func takeSlice() -> (buffers: Int, samples: Int) {
            lock.lock()
            defer {
                sliceBuffers = 0
                sliceSamples = 0
                lock.unlock()
            }
            return (sliceBuffers, sliceSamples)
        }

        func total() -> (buffers: Int, samples: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (totalBuffers, totalSamples)
        }
    }
}
