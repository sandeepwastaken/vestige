import Foundation

/// Shared, pre-configured formatters. Formatter construction is expensive
/// enough that rebuilding one per table row shows up in list scrolling.
/// Confined to the main actor: `Formatter` subclasses are not thread-safe, and
/// every use of these is in the UI layer anyway.
@MainActor
enum Formatters {
    /// "1.2 GB", "340 MB"
    static let fileSize: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    /// "Today at 3:41 PM", "Yesterday at 9:02 AM", "Mar 3 at 1:15 PM"
    static let clipTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// "1:04", "0:30" — clip durations are always well under an hour.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
