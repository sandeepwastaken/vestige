import Foundation

/// How long clips are kept before Vestige tidies them away.
///
/// Defaults to `never`. Automatically deleting someone's gameplay is the kind
/// of thing that must be asked for explicitly, never assumed.
enum RetentionPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case never
    case days30
    case days90

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .days30: "After 30 days"
        case .days90: "After 90 days"
        }
    }

    var days: Int? {
        switch self {
        case .never: nil
        case .days30: 30
        case .days90: 90
        }
    }
}

/// Applies the retention policy to a clip library.
///
/// Deleted clips go to the Trash, never straight to oblivion — a policy the
/// user set weeks ago should not be able to destroy something irrecoverably
/// while they are not looking.
@MainActor
enum RetentionSweeper {
    struct Rules: Sendable {
        var policy: RetentionPolicy
        var keepsFavorites: Bool
        var keepsNamed: Bool
    }

    /// Returns the clips that the policy would remove.
    ///
    /// Separated from the deletion itself so the settings screen can say
    /// "3 clips would be removed" before anything happens.
    static func expiredClips(
        in clips: [Clip],
        rules: Rules,
        metadata: ClipMetadataStore,
        now: Date = .now
    ) -> [Clip] {
        guard let days = rules.policy.days else { return [] }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return [] }

        return clips.filter { clip in
            guard clip.createdAt < cutoff else { return false }
            if rules.keepsFavorites, metadata.isFavorite(clip.url) { return false }
            // A clip someone bothered to name is one they cared about. The
            // automatic timestamp name does not count as naming.
            if rules.keepsNamed, !clip.hasGeneratedName { return false }
            return true
        }
    }

    @discardableResult
    static func sweep(
        clips: [Clip],
        rules: Rules,
        metadata: ClipMetadataStore,
        store: ClipStore
    ) -> Int {
        let expired = expiredClips(in: clips, rules: rules, metadata: metadata)
        guard !expired.isEmpty else { return 0 }

        Log.storage.info("Retention: moving \(expired.count, privacy: .public) clip(s) to the Trash")
        for clip in expired {
            store.delete(clip)
        }
        return expired.count
    }
}
