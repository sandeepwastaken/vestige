import SwiftUI

struct RecordingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                ReplayDurationPicker(duration: $settings.replayDuration)

                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(VideoResolution.allCases) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }

                Picker("Frame rate", selection: $settings.frameRate) {
                    ForEach(FrameRate.allCases) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
            } footer: {
                Text("Higher settings use more memory and GPU. Vestige encodes in hardware, so the cost while gaming stays small.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Codec", selection: $settings.codec) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text(codec.label).tag(codec)
                    }
                }

                Text(settings.codec.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Capture system audio", isOn: $settings.capturesSystemAudio)

                Text("Game sound, music, and anything else playing through your speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                MicrophoneToggle()
            }

            Section("Impact") {
                LabeledContent("Memory used by the buffer") {
                    Text(estimatedMemory)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                LabeledContent("Approximate clip size") {
                    Text(estimatedClipSize)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let configuration = model.capture.activeConfiguration {
                    LabeledContent("Encoding") {
                        Text("\(configuration.width)×\(configuration.height) · \(model.capture.isHardwareAccelerated ? "hardware" : "software")")
                            .foregroundStyle(model.capture.isHardwareAccelerated ? Color.secondary : Color.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Both figures come from the same bitrate the encoder will actually use,
    /// so the numbers shown here are the numbers the user will observe.
    private var configuration: EncoderConfiguration {
        let settings = model.settings
        let size = settings.resolution.outputSize(for: referenceDisplaySize)
        return EncoderConfiguration(
            width: Int(size.width),
            height: Int(size.height),
            frameRate: settings.frameRate.rawValue,
            codec: settings.codec
        )
    }

    /// The main display, used to resolve a "Native" resolution into real pixels.
    private var referenceDisplaySize: CGSize {
        guard let screen = NSScreen.main else { return CGSize(width: 1920, height: 1080) }
        let scale = screen.backingScaleFactor
        return CGSize(
            width: screen.frame.width * scale,
            height: screen.frame.height * scale
        )
    }

    private var bufferBytes: Int64 {
        let video = Double(configuration.bitrate) / 8.0 * model.settings.replayDuration.seconds
        // Buffered audio is PCM: 48 kHz, stereo, 32-bit.
        let audio = model.settings.capturesSystemAudio
            ? 48_000.0 * 2 * 4 * model.settings.replayDuration.seconds
            : 0
        return Int64(video + audio)
    }

    private var estimatedMemory: String {
        Formatters.fileSize.string(fromByteCount: bufferBytes)
    }

    private var estimatedClipSize: String {
        let video = Double(configuration.bitrate) / 8.0 * model.settings.replayDuration.seconds
        return Formatters.fileSize.string(fromByteCount: Int64(video))
    }
}
