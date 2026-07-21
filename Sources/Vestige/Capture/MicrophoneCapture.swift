@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Captures the default input device alongside the screen.
///
/// The output format is pinned to exactly what ScreenCaptureKit delivers for
/// system audio — 48 kHz, stereo, 32-bit float, non-interleaved. Letting
/// `AVCaptureAudioDataOutput` do that conversion means the two streams arrive
/// already commensurate, so combining them later is sample addition rather than
/// a resampling problem.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum MicrophoneError: LocalizedError {
        case noInputDevice
        case cannotAddInput

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone is available."
            case .cannotAddInput: "The microphone could not be opened."
            }
        }
    }

    /// The format both audio sources are normalised to.
    static let sampleRate: Double = 48_000
    static let channelCount = 2

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "app.vestige.capture.microphone", qos: .userInitiated)

    /// Owns every touch of `session` and `isRunning`.
    ///
    /// `AVCaptureSession.startRunning()` and `stopRunning()` are documented to
    /// block until the session changes state — routinely 100 ms and more while
    /// the audio hardware spins up. This class is driven from the main actor,
    /// so that blocking has to happen somewhere else; a dedicated serial queue
    /// is Apple's own pattern for it, and confining all session state to one
    /// queue also removes any question of races on `isRunning`.
    private let sessionQueue = DispatchQueue(label: "app.vestige.capture.microphone.session", qos: .userInitiated)

    private let onSample: @Sendable (CMSampleBuffer) -> Void

    /// Confined to `sessionQueue`.
    private var isRunning = false

    init(onSample: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.onSample = onSample
        super.init()
    }

    /// Whether the user has allowed microphone access.
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Prompts for microphone access. Unlike screen recording this is safe to
    /// call directly — it only ever prompts once and returns the stored answer
    /// afterwards, and it is always reached from a user toggling the setting.
    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Starts capturing. Suspends rather than blocks: the caller is the main
    /// actor, and the session start it waits for is a hardware operation.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.startOnSessionQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startOnSessionQueue() throws {
        guard !isRunning else { return }

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw MicrophoneError.noInputDevice
        }

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MicrophoneError.cannotAddInput
        }
        session.addInput(input)

        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneError.cannotAddInput
        }
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()
        isRunning = true
        Log.capture.info("Microphone capture started: \(device.localizedName, privacy: .public)")
    }

    /// Stops capturing. Fire-and-forget by design: teardown has nothing to
    /// report, and the blocking `stopRunning()` runs on the session queue
    /// rather than wherever the caller happens to be.
    func stop() {
        sessionQueue.async { self.stopOnSessionQueue() }
    }

    private func stopOnSessionQueue() {
        guard isRunning else { return }
        isRunning = false

        session.stopRunning()
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        onSample(sampleBuffer)
    }

    deinit {
        // Belt and braces — the engine always calls stop() first. The session
        // is captured by value so the block outlives self safely.
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }
}
