import AVFoundation
import SwiftUI

/// Picks a replay length: preset buttons for the common cases, a slider for
/// anything else.
///
/// The presets cover what most people want without thinking. The slider exists
/// because "how much do I want to keep" is genuinely continuous — someone
/// playing a game with three-minute rounds wants three minutes, not two or five.
struct ReplayDurationPicker: View {
    @Binding var duration: ReplayDuration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Replay length") {
                Text(duration.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 4) {
                ForEach(ReplayDuration.presets) { preset in
                    Button {
                        duration = preset
                    } label: {
                        Text(preset.shortLabel)
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.bordered)
                    .tint(duration == preset ? .accentColor : nil)
                }
            }

            Slider(
                value: Binding(
                    get: { Double(duration.rawValue) },
                    set: { duration = ReplayDuration(Int($0.rounded())) }
                ),
                in: Double(ReplayDuration.minimumSeconds)...Double(ReplayDuration.maximumSeconds),
                step: 5
            )

            HStack {
                Text(ReplayDuration(ReplayDuration.minimumSeconds).shortLabel)
                Spacer()
                Text(ReplayDuration(ReplayDuration.maximumSeconds).shortLabel)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// The microphone toggle, which has to negotiate a permission the rest of the
/// audio settings do not.
///
/// Switching it on requests access immediately rather than silently failing at
/// the next capture — the moment the user asks for the microphone is the moment
/// the prompt makes sense. If access is refused the toggle returns to off, so
/// it never claims to be recording something it cannot.
struct MicrophoneToggle: View {
    @Environment(AppModel.self) private var model
    @State private var isDenied = false

    var body: some View {
        @Bindable var settings = model.settings

        VStack(alignment: .leading, spacing: 3) {
            Toggle("Capture microphone", isOn: Binding(
                get: { settings.capturesMicrophone },
                set: { wantsMicrophone in
                    guard wantsMicrophone else {
                        settings.capturesMicrophone = false
                        isDenied = false
                        return
                    }
                    Task {
                        let granted = await MicrophoneCapture.requestAccess()
                        settings.capturesMicrophone = granted
                        isDenied = !granted
                    }
                }
            ))

            if isDenied {
                Label(
                    "Microphone access was refused. Enable Vestige under Privacy & Security › Microphone.",
                    systemImage: "mic.slash"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Mixed into the clip alongside game audio, slightly below it so the game stays dominant. Off unless you turn it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
