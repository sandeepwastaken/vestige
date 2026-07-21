import CoreMedia
import Foundation
import VideoToolbox

/// How many seconds of gameplay the replay buffer keeps available.
///
/// Stored as a plain second count rather than a fixed enum so the slider can
/// express anything up to the ceiling, while the presets stay one tap away.
struct ReplayDuration: Hashable, Codable, Sendable, Identifiable {
    /// Ten minutes at 1080p60 is roughly 900 MB of resident buffer. Past that
    /// the memory cost stops being reasonable for a background app.
    static let minimumSeconds = 15
    static let maximumSeconds = 600

    var rawValue: Int

    var id: Int { rawValue }
    var seconds: Double { Double(rawValue) }

    init(_ seconds: Int) {
        self.rawValue = min(max(seconds, Self.minimumSeconds), Self.maximumSeconds)
    }

    static let presets: [ReplayDuration] = [
        ReplayDuration(30),
        ReplayDuration(60),
        ReplayDuration(90),
        ReplayDuration(120),
        ReplayDuration(300),
        ReplayDuration(600)
    ]

    var isPreset: Bool { Self.presets.contains(self) }

    /// "30 seconds", "2 minutes", "1 min 30 sec"
    var label: String {
        let minutes = rawValue / 60
        let seconds = rawValue % 60

        switch (minutes, seconds) {
        case (0, _):
            return "\(seconds) seconds"
        case (_, 0):
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        default:
            return "\(minutes) min \(seconds) sec"
        }
    }

    /// Compact form for buttons and status lines: "30s", "90s", "2m", "3m 20s".
    ///
    /// Anything under two minutes stays in seconds rather than becoming
    /// "1m 30s". The preset buttons sit six-across in a 320pt panel, and the
    /// longer spelling does not fit — it truncated to "1m…", which reads as
    /// broken rather than compact.
    var shortLabel: String {
        let minutes = rawValue / 60
        let seconds = rawValue % 60

        if rawValue < 120 { return "\(rawValue)s" }

        switch seconds {
        case 0: return "\(minutes)m"
        default: return "\(minutes)m \(seconds)s"
        }
    }
}

/// Output resolution. Capture is scaled on the GPU by ScreenCaptureKit, so a
/// lower setting reduces encoder load as well as file size.
enum VideoResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case native
    case p2160
    case p1440
    case p1080
    case p720

    var id: String { rawValue }

    /// Target height in points, or `nil` to keep the display's own resolution.
    var targetHeight: Int? {
        switch self {
        case .native: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        }
    }

    var label: String {
        switch self {
        case .native: "Native"
        case .p2160: "2160p (4K)"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }

    /// Scales `source` to this resolution, preserving aspect ratio.
    ///
    /// Dimensions are rounded to even numbers: H.264 and HEVC encode in 2x2
    /// chroma blocks and reject odd dimensions on some hardware encoders.
    func outputSize(for source: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: 1920, height: 1080) }
        guard let targetHeight, source.height > CGFloat(targetHeight) else {
            return CGSize(width: source.width.roundedToEven, height: source.height.roundedToEven)
        }
        let scale = CGFloat(targetHeight) / source.height
        return CGSize(
            width: (source.width * scale).roundedToEven,
            height: (source.height * scale).roundedToEven
        )
    }
}

enum FrameRate: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120

    var id: Int { rawValue }
    var label: String { "\(rawValue) FPS" }

    /// Minimum interval between frames, handed to ScreenCaptureKit.
    var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }
}

enum VideoCodec: String, CaseIterable, Identifiable, Codable, Sendable {
    case hevc
    case h264

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hevc: "HEVC (H.265)"
        case .h264: "H.264"
        }
    }

    var detail: String {
        switch self {
        case .hevc: "Smaller files, best for modern Macs and Apple devices."
        case .h264: "Maximum compatibility with editors, browsers, and Discord."
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .hevc: kCMVideoCodecType_HEVC
        case .h264: kCMVideoCodecType_H264
        }
    }

    /// Bits per pixel per frame, used to derive a bitrate. HEVC reaches
    /// comparable quality at roughly 65% of H.264's bitrate.
    var bitsPerPixel: Double {
        switch self {
        case .hevc: 0.065
        case .h264: 0.100
        }
    }
}

/// What Vestige points the camera at.
enum CaptureMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Capture only the game's window. Falls back to the display when no game
    /// window can be found, so the buffer is never silently empty.
    case gameWindow
    /// Capture the whole display, including anything in front of the game.
    case entireDisplay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gameWindow: "Game window only"
        case .entireDisplay: "Entire display"
        }
    }

    var detail: String {
        switch self {
        case .gameWindow:
            "Records just the game, cropped to its window. Overlays, chat windows, and your desktop stay out of the clip."
        case .entireDisplay:
            "Records everything on screen, exactly as you see it."
        }
    }
}

/// What a capture session is pointed at, resolved at the moment capture starts.
enum CaptureTarget: Equatable, Sendable {
    case display(CGDirectDisplayID?)
    /// A specific app's window, identified by process so the right window is
    /// found even when a game opens several.
    case applicationWindow(pid: pid_t, name: String)

    var isWindow: Bool {
        if case .applicationWindow = self { return true }
        return false
    }
}

/// When the replay buffer should be running.
enum BufferPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Buffer only while a game appears to be running (lowest idle cost).
    case whilePlaying
    /// Buffer whenever Vestige is open.
    case always
    /// Buffer only when the user explicitly arms it from the menu bar.
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .whilePlaying: "While a game is running"
        case .always: "Always"
        case .manual: "Only when I turn it on"
        }
    }

    var detail: String {
        switch self {
        case .whilePlaying: "Vestige watches for games and starts buffering on its own."
        case .always: "The buffer runs the whole time Vestige is open."
        case .manual: "Nothing is captured until you start the buffer yourself."
        }
    }
}

/// The fully-resolved encoder configuration for one capture session.
struct EncoderConfiguration: Equatable, Sendable {
    var width: Int
    var height: Int
    var frameRate: Int
    var codec: VideoCodec
    var bitrate: Int

    /// Derives a bitrate from pixel throughput rather than exposing yet another
    /// setting. Clamped at both ends so that 720p30 is not starved and 4K120
    /// does not produce a file the disk cannot keep up with.
    init(width: Int, height: Int, frameRate: Int, codec: VideoCodec) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec

        let raw = Double(width * height * frameRate) * codec.bitsPerPixel
        self.bitrate = Int(min(max(raw, 2_500_000), 80_000_000))
    }

    /// Forcing a keyframe every two seconds bounds how much footage is lost
    /// when the buffer is trimmed: a clip can only start on a keyframe, so this
    /// is the granularity of the buffer's leading edge.
    static let keyframeInterval: Double = 2.0
}

private extension CGFloat {
    /// Never returns zero: rounding a sub-pixel dimension down to 0 would be
    /// handed straight to `VTCompressionSessionCreate`, which fails on a
    /// zero-sized session.
    var roundedToEven: CGFloat {
        let value = Int(rounded())
        return CGFloat(Swift.max(2, value - (value % 2)))
    }
}
