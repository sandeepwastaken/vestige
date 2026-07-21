import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Captures system audio on its own stream, independent of what is recorded
/// visually.
///
/// ScreenCaptureKit scopes audio to the content filter it is given, so the
/// `desktopIndependentWindow` filter used by window capture yields only audio
/// attributed to that window — unreliable, since games play sound from helper
/// processes and virtual devices. The symptom was a 58-second clip holding
/// 1.2 seconds of audio.
///
/// A separate display-scoped stream decouples them: the video filter decides
/// what you see, this decides what you hear. It costs one extra stream at 2×2
/// and 1 fps, the smallest ScreenCaptureKit accepts since a stream must carry
/// video. Those frames are discarded on arrival.
final class SystemAudioStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let onSample: @Sendable (CMSampleBuffer) -> Void
    private let onStop: @Sendable (Error?) -> Void
    private let queue = DispatchQueue(label: "app.vestige.capture.system-audio", qos: .userInitiated)

    init(
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
        onStop: @escaping @Sendable (Error?) -> Void
    ) {
        self.onSample = onSample
        self.onStop = onStop
        super.init()
    }

    func start(excludingCurrentProcess: Bool = true) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first
        else {
            throw CaptureError.noDisplaysAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = excludingCurrentProcess

        // A stream must produce video even when only audio is wanted, so it is
        // made as small and infrequent as ScreenCaptureKit permits.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        try await stream.startCapture()
        self.stream = stream

        Log.capture.info("System audio stream running (display-scoped)")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // The 2×2 video frames exist only because the API requires them.
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        onSample(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}
