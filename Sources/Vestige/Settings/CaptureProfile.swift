import Foundation

/// A named snapshot of every capture setting.
///
/// Different games want genuinely different setups — a shooter wants 60 seconds
/// at high frame rate, a strategy game wants ten minutes at 30fps, a recording
/// for editing wants no compression at all. Rather than making people
/// reconfigure five controls each time, a profile captures the lot and switches
/// them together from the menu bar.
struct CaptureProfile: Codable, Identifiable, Hashable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String

    var replayDurationSeconds: Int
    var resolution: VideoResolution
    var frameRate: FrameRate
    var codec: VideoCodec
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var captureMode: CaptureMode
    var compression: CompressionSettings

    /// Two profiles that ship by default, so the feature is discoverable
    /// without anyone having to build one first.
    static func builtIns() -> [CaptureProfile] {
        [
            CaptureProfile(
                name: "Competitive",
                replayDurationSeconds: 60,
                resolution: .p1080,
                frameRate: .fps60,
                codec: .hevc,
                capturesSystemAudio: true,
                capturesMicrophone: false,
                captureMode: .gameWindow,
                compression: CompressionPreset.all[0].settings
            ),
            CaptureProfile(
                name: "High Quality",
                replayDurationSeconds: 120,
                resolution: .native,
                frameRate: .fps60,
                codec: .hevc,
                capturesSystemAudio: true,
                capturesMicrophone: false,
                captureMode: .entireDisplay,
                compression: CompressionSettings(mode: .none)
            )
        ]
    }
}
