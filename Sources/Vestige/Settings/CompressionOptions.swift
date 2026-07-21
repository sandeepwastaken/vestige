import CoreGraphics
import Foundation

/// The resolution a bitrate can carry without starving the picture.
///
/// This exists for quality, not file size — the rate control decides the size.
/// Encoding at native resolution does not produce a bigger file, it spreads the
/// same bits over three times the pixels, which is what makes a tightly
/// compressed clip look blocky and smeared in motion.
///
/// The relationship was measured rather than guessed, by encoding one clip at
/// four resolutions per bitrate and scoring each against the source with SSIM.
/// Optimal pixel count tracks the square root of bits-per-frame closely: the
/// constant came out 9851 at 620 kbps and 9997 at 1470 kbps, so a single
/// coefficient covers the useful range. It is set slightly below both, because
/// SSIM rewards resolution a little more than the eye does at low bitrates.
///
/// Frame rate is deliberately never reduced. Halving it scored +0.003 SSIM —
/// within noise, and SSIM cannot see motion at all — so it is not worth halving
/// the smoothness of gameplay footage.
struct EncodePlan: Sendable, Equatable {
    var width: Int
    var height: Int

    private static let pixelCoefficient = 9_500.0

    /// The largest picture `bitrate` can carry at `frameRate`.
    ///
    /// Never upscales: this only ever spends less than the source.
    static func fitting(bitrate: Int, sourceSize: CGSize, frameRate: Double) -> EncodePlan {
        let sourceWidth = max(2.0, Double(abs(sourceSize.width)))
        let sourceHeight = max(2.0, Double(abs(sourceSize.height)))
        let sourcePixels = sourceWidth * sourceHeight
        let rate = (1.0...240.0).contains(frameRate) ? frameRate : 60

        let pixels = pixelCoefficient * (Double(bitrate) / rate).squareRoot()
        let scale = min(1.0, (pixels / sourcePixels).squareRoot())

        return EncodePlan(
            width: evenPixels(sourceWidth * scale),
            height: evenPixels(sourceHeight * scale)
        )
    }

    /// Encoders reject odd dimensions and zero-sized sessions.
    private static func evenPixels(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return max(2, rounded - (rounded % 2))
    }
}

/// How a saved clip should be compressed, if at all.
enum CompressionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Keep the clip exactly as captured. No re-encode, no quality loss.
    case none
    /// Re-encode aiming at a file size.
    case targetSize
    /// Re-encode at a fraction of the captured bitrate.
    case quality

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .targetSize: "Target file size"
        case .quality: "Quality"
        }
    }
}

/// A complete compression configuration.
struct CompressionSettings: Hashable, Codable, Sendable {
    var mode: CompressionMode = .none

    /// Target size in megabytes, used by `.targetSize`.
    var targetMegabytes: Int = 10

    /// 0–100. 100 means the captured bitrate untouched; lower values scale it
    /// down. Used by `.quality`.
    var qualityPercent: Int = 70

    /// Format of the compressed copy, independent of what was captured.
    ///
    /// HEVC scored 0.940 against H.264's 0.927 (SSIM, identical file size), so
    /// it is the default — at these bitrates that margin is worth more than the
    /// resolution tuning. H.264 is there because a clip that will not preview
    /// inline is worse than a slightly softer one: Discord's desktop app plays
    /// HEVC, but browser and older-client playback is patchy.
    var codec: VideoCodec = .hevc

    /// Keeps the original alongside the compressed copy.
    ///
    /// The compressed file is the one that gets copied to the clipboard, so
    /// "save both" gives you a Discord-ready clip to paste and the untouched
    /// footage to edit from later.
    var keepsOriginal: Bool = true

    var isEnabled: Bool { mode != .none }

    init(
        mode: CompressionMode = .none,
        targetMegabytes: Int = 10,
        qualityPercent: Int = 70,
        codec: VideoCodec = .hevc,
        keepsOriginal: Bool = true
    ) {
        self.mode = mode
        self.targetMegabytes = targetMegabytes
        self.qualityPercent = qualityPercent
        self.codec = codec
        self.keepsOriginal = keepsOriginal
    }

    /// Decodes tolerantly, filling in anything the stored copy predates.
    ///
    /// The synthesized decoder ignores property defaults and throws on a
    /// missing key, so simply adding a field here would make every previously
    /// saved settings blob fail to decode — silently resetting compression back
    /// to defaults on upgrade. Every field is optional on the way in so that
    /// adding another one later stays a non-event.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CompressionSettings()
        mode = try container.decodeIfPresent(CompressionMode.self, forKey: .mode) ?? defaults.mode
        targetMegabytes = try container.decodeIfPresent(Int.self, forKey: .targetMegabytes) ?? defaults.targetMegabytes
        qualityPercent = try container.decodeIfPresent(Int.self, forKey: .qualityPercent) ?? defaults.qualityPercent
        codec = try container.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? defaults.codec
        keepsOriginal = try container.decodeIfPresent(Bool.self, forKey: .keepsOriginal) ?? defaults.keepsOriginal
    }

    /// Assumed AAC bitrate for target-size budgeting.
    ///
    /// Kept in one place so the compressor, settings estimate, and bitrate
    /// calculation agree about the non-video part of the file.
    static let audioBitrate = 160_000

    /// Bytes reserved for MP4 boxes, metadata, and encoder rate-control wiggle.
    ///
    /// File-size targets are usually hard upload limits, so this deliberately
    /// gives video less than the theoretical maximum. A clip that lands a little
    /// under 10 MB is useful; one that lands at 10.4 MB is not.
    private func containerReserveBytes(targetBytes: Double) -> Double {
        max(256_000, targetBytes * 0.05)
    }

    /// Total bytes requested by `.targetSize`.
    var targetBytes: Int64 {
        Int64(targetMegabytes) * 1_000_000
    }

    /// Bytes available for encoded video after audio and container overhead.
    func targetVideoBytes(duration: Double, includesAudio: Bool = true) -> Int64 {
        guard mode == .targetSize, duration > 0 else { return 0 }

        let totalBytes = Double(targetBytes)
        let audioBytes = includesAudio
            ? Double(Self.audioBitrate) / 8.0 * duration
            : 0
        let videoBytes = totalBytes - audioBytes - containerReserveBytes(targetBytes: totalBytes)
        return max(1, Int64(videoBytes.rounded(.down)))
    }

    /// Video bytes to ask the encoder for.
    ///
    /// Constant bitrate tracks the request closely but lands slightly above it,
    /// by 5% at 400 kbps falling to under 2% at 1600 kbps. Asking for 93% of
    /// the budget keeps the worst measured overshoot inside it while still
    /// spending nearly all of the target — the previous data-rate-limited mode
    /// used only 73%, which was quality thrown away for no benefit.
    private func targetAverageVideoBytes(duration: Double, includesAudio: Bool = true) -> Int64 {
        let hardBudget = Double(targetVideoBytes(duration: duration, includesAudio: includesAudio))
        return max(1, Int64((hardBudget * 0.93).rounded(.down)))
    }

    /// Bits per second to aim for.
    ///
    /// For a size target the audio track's share is subtracted first, then a
    /// small safety margin — container overhead and rate-control overshoot both
    /// push the real file slightly above the arithmetic target, and landing at
    /// 10.4 MB when Discord's limit is 10 MB would defeat the point.
    func targetBitrate(duration: Double, captureBitrate: Int, includesAudio: Bool = true) -> Int {
        switch mode {
        case .none:
            return captureBitrate

        case .targetSize:
            guard duration > 0 else { return captureBitrate }
            let videoBits = Double(targetAverageVideoBytes(duration: duration, includesAudio: includesAudio)) * 8.0
            return max(200_000, Int(videoBits / duration))

        case .quality:
            let fraction = Double(max(1, min(100, qualityPercent))) / 100.0
            // Squared, so the slider's lower half produces meaningfully smaller
            // files instead of crowding every useful value into the last 20%.
            return max(200_000, Int(Double(captureBitrate) * fraction * fraction))
        }
    }

    /// Rough size estimate for the settings UI.
    func estimatedBytes(duration: Double, captureBitrate: Int) -> Int64 {
        switch mode {
        case .targetSize:
            return targetBytes
        case .none, .quality:
            let bitrate = targetBitrate(duration: duration, captureBitrate: captureBitrate)
            return Int64((Double(bitrate) / 8 + 20_000) * duration)
        }
    }
}

/// Named compression configurations, so the common cases are one click.
struct CompressionPreset: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var detail: String
    var symbol: String
    var settings: CompressionSettings

    static let all: [CompressionPreset] = [
        CompressionPreset(
            name: "Discord",
            detail: "10 MB, keeps the original",
            symbol: "paperplane",
            settings: CompressionSettings(
                mode: .targetSize, targetMegabytes: 10, qualityPercent: 70,
                codec: .hevc, keepsOriginal: true
            )
        ),
        CompressionPreset(
            name: "Discord Nitro",
            detail: "50 MB, keeps the original",
            symbol: "paperplane.fill",
            settings: CompressionSettings(
                mode: .targetSize, targetMegabytes: 50, qualityPercent: 80,
                codec: .hevc, keepsOriginal: true
            )
        ),
        CompressionPreset(
            name: "Shareable",
            detail: "100 MB, H.264 for wide compatibility",
            symbol: "square.and.arrow.up",
            settings: CompressionSettings(
                mode: .targetSize, targetMegabytes: 100, qualityPercent: 85,
                codec: .h264, keepsOriginal: true
            )
        ),
        CompressionPreset(
            name: "Balanced",
            detail: "70% quality, replaces the original",
            symbol: "slider.horizontal.3",
            settings: CompressionSettings(
                mode: .quality, targetMegabytes: 10, qualityPercent: 70,
                codec: .hevc, keepsOriginal: false
            )
        ),
        CompressionPreset(
            name: "Raw Footage",
            detail: "No compression at all",
            symbol: "film",
            settings: CompressionSettings(
                mode: .none, targetMegabytes: 10, qualityPercent: 100,
                codec: .hevc, keepsOriginal: true
            )
        )
    ]

    static func matching(_ settings: CompressionSettings) -> CompressionPreset? {
        all.first { $0.settings == settings }
    }
}
