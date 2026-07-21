import Foundation

/// How the clip library is ordered.
enum ClipSort: String, CaseIterable, Identifiable, Sendable {
    case newest
    case oldest
    case largest
    case smallest
    case game
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .largest: "Largest first"
        case .smallest: "Smallest first"
        case .game: "Game"
        case .name: "Name"
        }
    }

    var symbol: String {
        switch self {
        case .newest, .oldest: "clock"
        case .largest, .smallest: "internaldrive"
        case .game: "gamecontroller"
        case .name: "textformat"
        }
    }

    /// Whether this ordering groups clips under headings.
    var isGrouped: Bool { self == .game }
}

/// One rendered section of the library.
struct ClipSection: Identifiable, Sendable {
    var id: String { title }
    var title: String
    var symbol: String
    var clips: [Clip]
}

/// Turns a flat clip list into the sections the library displays.
@MainActor
enum ClipOrganizer {
    /// Builds sections for `clips`.
    ///
    /// Favourites are always lifted into their own section at the top,
    /// regardless of the sort — the point of marking something a favourite is
    /// that you should never have to hunt for it again. They keep the chosen
    /// ordering within that section, and are not repeated below.
    static func sections(
        for clips: [Clip],
        sort: ClipSort,
        metadata: ClipMetadataStore,
        searchText: String
    ) -> [ClipSection] {
        let filtered = filter(clips, searchText: searchText, metadata: metadata)

        let favorites = filtered.filter { metadata.isFavorite($0.url) }
        let rest = filtered.filter { !metadata.isFavorite($0.url) }

        var sections: [ClipSection] = []

        if !favorites.isEmpty {
            sections.append(
                ClipSection(
                    title: "Favorites",
                    symbol: "star.fill",
                    clips: order(favorites, by: sort)
                )
            )
        }

        if sort.isGrouped {
            sections.append(contentsOf: gameSections(for: rest, metadata: metadata))
        } else if !rest.isEmpty {
            sections.append(
                ClipSection(
                    title: favorites.isEmpty ? "" : "All Clips",
                    symbol: "film",
                    clips: order(rest, by: sort)
                )
            )
        }

        return sections
    }

    private static func gameSections(
        for clips: [Clip],
        metadata: ClipMetadataStore
    ) -> [ClipSection] {
        var groups: [String: [Clip]] = [:]

        for clip in clips {
            // The game is recorded at save time. Older clips predate that, so
            // they fall back to the filename's prefix, which is the game name
            // for anything Vestige detected.
            let game = metadata.gameName(for: clip.url)
                ?? inferredGameName(from: clip)
                ?? "Other"
            groups[game, default: []].append(clip)
        }

        return groups
            .map { game, clips in
                ClipSection(
                    title: game,
                    symbol: game == "Other" ? "film" : "gamecontroller.fill",
                    clips: clips.sorted { $0.createdAt > $1.createdAt }
                )
            }
            // Biggest collections first, alphabetical within equal sizes, and
            // "Other" always last so the miscellany never leads.
            .sorted { left, right in
                if (left.title == "Other") != (right.title == "Other") {
                    return right.title == "Other"
                }
                if left.clips.count != right.clips.count {
                    return left.clips.count > right.clips.count
                }
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
    }

    /// Recovers the game name from a generated filename like
    /// "Roblox 2026-07-19 at 18.42.13".
    private static func inferredGameName(from clip: Clip) -> String? {
        guard clip.hasGeneratedName else { return nil }
        let pattern = #"\s\d{4}-\d{2}-\d{2} at .*$"#
        guard let range = clip.name.range(of: pattern, options: .regularExpression) else { return nil }

        let prefix = String(clip.name[..<range.lowerBound])
        return prefix == "Vestige" ? nil : prefix
    }

    private static func order(_ clips: [Clip], by sort: ClipSort) -> [Clip] {
        switch sort {
        case .newest: clips.sorted { $0.createdAt > $1.createdAt }
        case .oldest: clips.sorted { $0.createdAt < $1.createdAt }
        case .largest: clips.sorted { $0.fileSize > $1.fileSize }
        case .smallest: clips.sorted { $0.fileSize < $1.fileSize }
        case .name: clips.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .game: clips.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Matches against the clip's name, its game, and its bookmark labels — so
    /// searching "trickshot" finds the clip you tagged, not just ones you
    /// happened to rename.
    private static func filter(
        _ clips: [Clip],
        searchText: String,
        metadata: ClipMetadataStore
    ) -> [Clip] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return clips }

        return clips.filter { clip in
            if clip.name.localizedCaseInsensitiveContains(query) { return true }
            if let game = metadata.gameName(for: clip.url),
               game.localizedCaseInsensitiveContains(query) { return true }
            return metadata.bookmarks(for: clip.url).contains {
                $0.label.localizedCaseInsensitiveContains(query)
            }
        }
    }
}
