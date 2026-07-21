import Foundation

/// One saved clip on disk.
///
/// Identified by its URL rather than a generated ID: the file *is* the record.
/// Vestige keeps no database, so a clip the user moves or deletes in Finder
/// simply stops existing, with no index left to fall out of sync.
struct Clip: Identifiable, Hashable, Sendable {
    var url: URL
    var createdAt: Date
    var fileSize: Int64
    var duration: Double

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// True when the filename still looks like one Vestige generated, rather
    /// than something a person chose.
    ///
    /// Used by the retention sweeper: a clip someone took the trouble to name
    /// is one they meant to keep, whereas "Roblox 2026-07-19 at 18.42.13" is
    /// just when it happened.
    var hasGeneratedName: Bool {
        // Matches a trailing " <date> at <time>" stamp, optionally followed by
        // a " (2)" disambiguator.
        let pattern = #"\d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}( \(\d+\))?$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    init(url: URL, createdAt: Date, fileSize: Int64, duration: Double) {
        self.url = url
        self.createdAt = createdAt
        self.fileSize = fileSize
        self.duration = duration
    }

    /// Builds a filename for a new clip.
    ///
    /// The shape mirrors macOS screenshots ("Screenshot 2026-07-19 at 18.42.13")
    /// so clips sort chronologically by name and look at home in Finder. Colons
    /// and slashes are avoided because they are path separators at the POSIX and
    /// Finder layers respectively.
    static func filename(for date: Date = .now, gameName: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let prefix = gameName.map(sanitize) ?? "Vestige"
        return "\(prefix) \(formatter.string(from: date)).mp4"
    }

    static func sanitizeName(_ name: String) -> String {
        sanitize(name)
    }

    private static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)

        // A leading dot would make the clip invisible in Finder.
        guard !cleaned.isEmpty, !cleaned.hasPrefix(".") else { return "Vestige" }
        return cleaned
    }
}
