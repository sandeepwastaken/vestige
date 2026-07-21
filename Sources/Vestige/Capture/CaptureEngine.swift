import AppKit
import CoreMedia
import CoreVideo
import Observation
@preconcurrency import ScreenCaptureKit

/// Logs the first audio buffer of a session and tracks that audio keeps coming.
///
/// Exists because "the clip is silent" has several causes that look identical
/// from outside — never captured, captured but discarded, captured but not
/// encoded. This settles the first of them.
private final class AudioArrivalProbe: @unchecked Sendable {
    private var hasReported = false
    private let lock = NSLock()

    /// Called on the main actor the first time audio arrives.
    var onFirstBuffer: (@Sendable () -> Void)?

    /// Re-arms the report so a restarted stream logs its own arrival instead of
    /// appearing never to have delivered anything.
    func reset() {
        lock.lock()
        hasReported = false
        lock.unlock()
    }

    func reportFirst(_ frame: BufferedAudioFrame) {
        lock.lock()
        let shouldReport = !hasReported
        hasReported = true
        lock.unlock()

        guard shouldReport else { return }
        onFirstBuffer?()

        let description = CMSampleBufferGetFormatDescription(frame.sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }

        // The raw duration, before recovery: logging only the corrected value
        // hid whether the system had reported an invalid one at all.
        let raw = CMSampleBufferGetDuration(frame.sampleBuffer)

        Log.capture.info("""
            System audio flowing: \(description?.mSampleRate ?? 0, privacy: .public)Hz \
            \(description?.mChannelsPerFrame ?? 0, privacy: .public)ch \
            samples=\(CMSampleBufferGetNumSamples(frame.sampleBuffer), privacy: .public) \
            rawDuration=\(raw.isValid ? "\(raw.seconds)s" : "INVALID", privacy: .public) \
            pts=\(frame.presentationTime.seconds, privacy: .public)
            """)
    }
}

/// Owns the live capture pipeline: ScreenCaptureKit stream → encoder → buffer.
///
/// The control plane (start, stop, recover, report state) lives on the main
/// actor because the UI drives it and it drives the UI back. The data plane —
/// 60 to 120 frames a second — never touches it: ScreenCaptureKit's queue hands
/// frames straight to `VideoEncoder` and `ReplayBuffer`, both internally
/// thread-safe, so an arriving frame never wakes the main thread.
///
/// Audio comes from a separate `SystemAudioStream`, so capturing one window
/// does not restrict what can be heard.
@MainActor
@Observable
final class CaptureEngine {
    enum State: Equatable, Sendable {
        case idle
        case starting
        case running
        /// Capture dropped out and a restart is scheduled.
        case recovering(reason: String)
        /// Capture cannot continue without user intervention.
        case failed(reason: String)

        var isActive: Bool {
            switch self {
            case .running, .starting, .recovering: true
            case .idle, .failed: false
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var isHardwareAccelerated = false
    private(set) var activeConfiguration: EncoderConfiguration?

    /// Whether system audio has actually arrived this session.
    ///
    /// Surfaced in the UI because a silent clip is otherwise discovered long
    /// after the moment has passed and the file is written.
    private(set) var isReceivingAudio = false

    /// Live buffer occupancy, for the menu bar readout.
    var statistics: ReplayBuffer.Statistics { buffer?.statistics ?? .init() }

    // MARK: - Pipeline

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var encoder: VideoEncoder?
    private var buffer: ReplayBuffer?
    private var microphone: MicrophoneCapture?
    private var systemAudio: SystemAudioStream?
    private var audioProbe: AudioArrivalProbe?

    private var settings: CaptureSettings?
    private(set) var target: CaptureTarget = .display(nil)

    /// Bumped by every teardown and every new start attempt.
    ///
    /// `startInternal()` suspends several times and is reachable from four
    /// directions: an explicit start, the restart backoff, waking from sleep,
    /// and a display change. Two of those overlapping used to install a second
    /// pipeline over the first, leaving the original stream capturing with
    /// nothing holding it. Each attempt carries a token and abandons itself
    /// once a newer one begins.
    private var generation = 0

    private let videoQueue = DispatchQueue(label: "app.vestige.capture.video", qos: .userInitiated)

    // MARK: - Recovery

    private var restartTask: Task<Void, Never>?
    private var restartAttempt = 0
    private var audioRestartAttempt = 0
    private var isSystemAsleep = false

    /// Whether waking from sleep should bring capture back.
    ///
    /// Recorded at sleep time rather than inferred from `state` on wake. The
    /// old inference was true in almost every case, so a waking Mac started
    /// recording the display even when the buffer policy said nothing should
    /// run — for a screen recorder, a privacy bug rather than a glitch.
    private var shouldResumeOnWake = false

    private let workspaceObservers = NotificationObservers(center: NSWorkspace.shared.notificationCenter)
    private let appObservers = NotificationObservers()

    init() {
        observeSystemEvents()
    }

    // MARK: - Lifecycle

    /// Starts capturing, replacing any session already running.
    func start(settings: CaptureSettings, target: CaptureTarget) async {
        self.settings = settings
        self.target = target

        await stop()
        guard !isSystemAsleep else {
            // Starting a stream against a sleeping display fails; the wake
            // handler honours this deferred request instead.
            shouldResumeOnWake = true
            state = .idle
            return
        }
        await startInternal()
    }

    /// Applies changed settings or a changed target.
    ///
    /// Capture must be torn down and rebuilt for either: resolution, frame
    /// rate, and codec are fixed when the encoder session is created, and the
    /// content filter is fixed when the stream is created.
    func reconfigure(settings: CaptureSettings, target: CaptureTarget) async {
        guard state.isActive else {
            self.settings = settings
            self.target = target
            return
        }
        guard settings != self.settings || target != self.target else { return }
        await start(settings: settings, target: target)
    }

    func stop() async {
        restartTask?.cancel()
        restartTask = nil

        // Abandons any start still in flight, so it cannot install its pipeline
        // after this teardown has finished.
        generation += 1

        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                // Already stopped, or the stream died on its own. Either way the
                // teardown below is what matters.
                Log.capture.debug("stopCapture: \(error.localizedDescription, privacy: .public)")
            }
        }
        stream = nil
        streamOutput = nil

        microphone?.stop()
        microphone = nil

        if let systemAudio {
            self.systemAudio = nil
            await systemAudio.stop()
        }

        invalidateEncoderOffMain()
        buffer = nil
        audioProbe = nil
        activeConfiguration = nil
        isReceivingAudio = false

        // A failure the user needs to see must survive teardown; anything else
        // settles to idle.
        if case .failed = state {} else { state = .idle }
    }

    // MARK: - Reading the buffer

    /// The current buffer contents, or `nil` if capture is not running.
    func snapshot() -> ReplaySnapshot? {
        buffer?.snapshot()
    }

    // MARK: - Start

    private func startInternal() async {
        guard let settings else { return }

        generation += 1
        let token = generation

        isReceivingAudio = false

        // Querying ScreenCaptureKit without a recorded grant raises the system
        // dialog, and the restart backoff re-enters here on a timer — so
        // without this prompt-free gate a revoked permission would produce a
        // dialog every few seconds. `AppModel` checks too; this guards the
        // path it does not own.
        guard CGPreflightScreenCaptureAccess() else {
            Log.capture.notice("Not starting capture: no screen recording permission")
            state = .failed(reason: "Screen Recording permission is needed")
            restartTask?.cancel()
            restartTask = nil
            return
        }

        state = .starting

        do {
            let (filter, sourceSize) = try await ShareableContentProvider.makeFilter(for: target)
            guard token == generation else { return }

            let outputSize = settings.resolution.outputSize(for: sourceSize)

            let configuration = EncoderConfiguration(
                width: Int(outputSize.width),
                height: Int(outputSize.height),
                frameRate: settings.frameRate.rawValue,
                codec: settings.codec
            )

            let buffer = ReplayBuffer(duration: settings.duration.seconds, bitrate: configuration.bitrate)

            // The encoder's failure handler hops to the main actor to trigger
            // recovery; the frame handler deliberately does not.
            let encoder = try VideoEncoder.make(
                configuration: configuration,
                onFrame: { frame in
                    buffer.append(frame)
                },
                onFailure: { error in
                    Task { @MainActor [weak self] in
                        self?.scheduleRestart(reason: error.localizedDescription)
                    }
                }
            )

            let audioProbe = AudioArrivalProbe()
            audioProbe.onFirstBuffer = { [weak self] in
                Task { @MainActor in self?.isReceivingAudio = true }
            }
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate.rawValue))
            let output = StreamOutput(
                onVideo: { sampleBuffer in
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                    encoder.encode(
                        imageBuffer,
                        presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                        duration: frameDuration
                    )
                },
                onStop: { error in
                    Task { @MainActor [weak self] in
                        self?.scheduleRestart(reason: error?.localizedDescription ?? "the capture stream ended")
                    }
                }
            )

            let streamConfiguration = makeStreamConfiguration(settings: settings, output: outputSize)

            let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoQueue)

            try await stream.startCapture()
            guard token == generation else {
                // Superseded while the stream was starting. It is live but
                // unreachable from here, so it has to be stopped explicitly —
                // dropping the reference would leave it capturing forever.
                try? await stream.stopCapture()
                return
            }

            // Audio runs on its own stream so it is not scoped to the captured
            // window, and starts after video so its failure cannot cost footage.
            if settings.capturesSystemAudio {
                await startSystemAudio(into: buffer, probe: audioProbe)
                guard token == generation else {
                    try? await stream.stopCapture()
                    return
                }
            }

            // Likewise for the microphone: a missing device or withdrawn
            // permission costs the user their voice track, never their footage.
            if settings.capturesMicrophone, MicrophoneCapture.isAuthorized {
                let microphone = MicrophoneCapture { sampleBuffer in
                    guard let frame = BufferedAudioFrame(sampleBuffer: sampleBuffer) else { return }
                    buffer.appendMicrophone(frame)
                }
                do {
                    try await microphone.start()
                    self.microphone = microphone
                } catch {
                    Log.capture.error("Microphone unavailable: \(error.localizedDescription, privacy: .public)")
                }
                guard token == generation else {
                    try? await stream.stopCapture()
                    return
                }
            }

            self.audioProbe = audioProbe
            self.stream = stream
            self.streamOutput = output
            self.encoder = encoder
            self.buffer = buffer
            self.activeConfiguration = encoder.configuration
            self.isHardwareAccelerated = encoder.isHardwareAccelerated
            self.restartAttempt = 0
            self.state = .running

            // Persisted, not debug: a capture that quietly restarts discards
            // the whole buffer, which looks identical to data being dropped
            // further down the pipeline.
            Log.capture.log("""
                Capture started: \(configuration.width, privacy: .public)x\(configuration.height, privacy: .public) \
                audio=\(settings.capturesSystemAudio, privacy: .public) \
                target=\(self.target.isWindow ? "window" : "display", privacy: .public)
                """)
        } catch {
            Log.capture.error("Failed to start capture: \(error.localizedDescription, privacy: .public)")
            scheduleRestart(reason: error.localizedDescription)
        }
    }

    // MARK: - System audio

    /// Brings up the system audio stream against `buffer`.
    ///
    /// Failure here is logged and otherwise ignored: audio is worth recovering,
    /// but never at the cost of the video already being buffered.
    private func startSystemAudio(into buffer: ReplayBuffer, probe: AudioArrivalProbe) async {
        let audioStream = SystemAudioStream(
            onSample: { sampleBuffer in
                guard let frame = BufferedAudioFrame(sampleBuffer: sampleBuffer) else { return }
                probe.reportFirst(frame)
                buffer.append(frame)
            },
            onStop: { [weak self] error in
                Task { @MainActor in
                    self?.systemAudioStopped(error, buffer: buffer, probe: probe)
                }
            }
        )

        do {
            try await audioStream.start()
            systemAudio = audioStream
            audioRestartAttempt = 0
        } catch {
            Log.capture.error("Could not start system audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rebuilds the audio stream after it drops out mid-session.
    ///
    /// Audio dying used to be logged and left alone, so the rest of the session
    /// recorded silently with nothing to show for it. Restarted independently
    /// of video: an audio fault must not discard a buffer of footage the user
    /// may be about to save.
    private func systemAudioStopped(_ error: Error?, buffer: ReplayBuffer, probe: AudioArrivalProbe) {
        // A stream stopping because we tore it down is not a fault.
        guard state == .running, self.buffer === buffer else { return }

        Log.capture.error("""
            System audio stream stopped: \(error?.localizedDescription ?? "no error given", privacy: .public)
            """)

        systemAudio = nil
        isReceivingAudio = false
        probe.reset()

        guard audioRestartAttempt < 3 else {
            Log.capture.error("System audio did not recover after 3 attempts; clips will be silent")
            return
        }

        let attempt = audioRestartAttempt
        audioRestartAttempt += 1
        let delay = pow(2.0, Double(attempt))

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.state == .running, self.buffer === buffer else { return }
            await self.startSystemAudio(into: buffer, probe: probe)
        }
    }

    private func makeStreamConfiguration(
        settings: CaptureSettings,
        output: CGSize
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()

        configuration.width = Int(output.width)
        configuration.height = Int(output.height)
        configuration.minimumFrameInterval = settings.frameRate.minimumFrameInterval

        // Delivering the encoder's native format avoids a full-frame BGRA→YUV
        // conversion per frame — the biggest CPU saving in this pipeline.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB

        // Absorbs scheduling jitter while the GPU is busy with a game, costing
        // a few frames of latency that a replay buffer does not care about.
        configuration.queueDepth = 6

        configuration.showsCursor = true

        // Fixed frame size, so a window resized mid-session is letterboxed
        // rather than stretched.
        configuration.scalesToFit = true

        if target.isWindow {
            // Otherwise the clip picks up the window's drop shadow and rounded
            // corner mask, leaving translucent edges instead of clean gameplay.
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.shouldBeOpaque = true
        }

        // Audio comes from a separate display-scoped stream. A window filter
        // would scope audio to that window and miss most of what the game
        // plays. See SystemAudioStream.
        configuration.capturesAudio = false

        return configuration
    }

    // MARK: - Recovery

    /// Restarts capture after a failure, backing off so a persistent problem
    /// (no permission, no display) does not spin.
    private func scheduleRestart(reason: String) {
        // One pending restart at a time. A failing stream reports through both
        // the encoder and the stream delegate, so without this the backoff
        // would be reset by the second report and the retries would stack.
        guard settings != nil, restartTask == nil else { return }

        state = .recovering(reason: reason)

        let attempt = restartAttempt
        restartAttempt = min(restartAttempt + 1, 6)
        let delay = min(pow(2.0, Double(attempt)), 30.0)

        Log.capture.notice("Capture interrupted (\(reason, privacy: .public)); retrying in \(delay, privacy: .public)s")

        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }

            self.restartTask = nil
            await self.teardownPipeline()
            guard !self.isSystemAsleep else { return }
            await self.startInternal()
        }
    }

    /// Releases pipeline objects without disturbing `state` or the restart task.
    private func teardownPipeline() async {
        generation += 1

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        microphone?.stop()
        microphone = nil

        if let systemAudio {
            self.systemAudio = nil
            await systemAudio.stop()
        }
        invalidateEncoderOffMain()
        buffer = nil
        audioProbe = nil
        isReceivingAudio = false
    }

    /// Tears the encoder down away from the main actor.
    ///
    /// `invalidate()` flushes in-flight frames synchronously — a handful at
    /// most, but VideoToolbox promises no latency, and this runs on every stop,
    /// reconfigure, and sleep. Safe to detach: the encoder's output closure
    /// holds its own reference to the ring buffer, so late frames drain into an
    /// object that outlives the flush.
    private func invalidateEncoderOffMain() {
        guard let encoder else { return }
        self.encoder = nil
        Task.detached(priority: .utility) {
            encoder.invalidate()
        }
    }

    private func observeSystemEvents() {
        // Sleep tears down the capture server's session anyway; stopping first
        // means we wake into a clean start instead of a broken stream.
        workspaceObservers.observe(NSWorkspace.willSleepNotification) { [weak self] in
            guard let self else { return }
            self.isSystemAsleep = true
            // Captured before teardown: only a session that was actually
            // running (or trying to) has earned a restart on wake.
            self.shouldResumeOnWake = self.state.isActive
            Task { await self.teardownPipeline() }
        }

        workspaceObservers.observe(NSWorkspace.didWakeNotification) { [weak self] in
            guard let self else { return }
            self.isSystemAsleep = false
            guard self.shouldResumeOnWake, self.settings != nil else { return }
            self.shouldResumeOnWake = false
            Task { await self.startInternal() }
        }

        // A resolution change, an unplugged display, or the app moving monitor
        // all invalidate the encoder's fixed dimensions. Tear down first:
        // starting straight into a second pipeline left the original stream
        // encoding into an orphaned buffer for the rest of the session, and
        // this notification fires several times when a monitor is plugged in.
        appObservers.observe(NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self, self.state == .running else { return }
            Log.capture.info("Display configuration changed; restarting capture")
            Task {
                await self.teardownPipeline()
                guard !self.isSystemAsleep else { return }
                await self.startInternal()
            }
        }
    }
}
