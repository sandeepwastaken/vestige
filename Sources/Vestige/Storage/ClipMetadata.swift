import AppKit
import Foundation
import Observation

/// A marked moment inside a clip.
///
/// Bookmarks live only in Vestige's own records — they are never muxed into the
/// MP4. A clip you send to a friend is just a clip; the "0:33 trickshot" note
/// stays yours.
struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var time: Double
    var label: String
}

/// Everything Vestige knows about a clip that the file itself cannot express.
struct ClipMetadata: Codable, Hashable, Sendable {
    var isFavorite: Bool = false
    var gameName: String?
    var bookmarks: [Bookmark] = []

    var isEmpty: Bool {
        !isFavorite && gameName == nil && bookmarks.isEmpty
    }
}

/// Sidecar storage for clip metadata.
///
/// Keyed by filename rather than full path, so moving the clips folder — or
/// pointing Vestige at a different one and back — keeps favourites and
/// bookmarks attached to their clips.
///
/// Renaming is deliberately *not* stored here: a rename moves the file on disk,
/// so the filename stays the single source of truth for what a clip is called
/// and survives uninstalling Vestige. This store holds only what a filename
/// cannot carry.
@MainActor
@Observable
final class ClipMetadataStore {
    private var entries: [String: ClipMetadata] = [:]
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private let observers = NotificationObservers()

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appending(path: "clips.json")
        load()

        // Writes are debounced, so quitting inside that window would have
        // discarded the edit that triggered them — favouriting a clip and
        // immediately quitting lost the favourite. Termination flushes
        // synchronously; there is no later opportunity.
        observers.observe(NSApplication.willTerminateNotification) { [weak self] in
            self?.flush()
        }
    }

    /// Writes any pending changes immediately.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "Vestige", directoryHint: .isDirectory)
    }

    // MARK: - Access

    func metadata(for url: URL) -> ClipMetadata {
        entries[url.lastPathComponent] ?? ClipMetadata()
    }

    func isFavorite(_ url: URL) -> Bool {
        entries[url.lastPathComponent]?.isFavorite ?? false
    }

    func bookmarks(for url: URL) -> [Bookmark] {
        (entries[url.lastPathComponent]?.bookmarks ?? []).sorted { $0.time < $1.time }
    }

    func gameName(for url: URL) -> String? {
        entries[url.lastPathComponent]?.gameName
    }

    // MARK: - Mutation

    func toggleFavorite(_ url: URL) {
        update(url) { $0.isFavorite.toggle() }
    }

    func setGameName(_ name: String?, for url: URL) {
        update(url) { $0.gameName = name }
    }

    func addBookmark(_ bookmark: Bookmark, to url: URL) {
        update(url) { $0.bookmarks.append(bookmark) }
    }

    func removeBookmark(_ id: Bookmark.ID, from url: URL) {
        update(url) { $0.bookmarks.removeAll { $0.id == id } }
    }

    func renameBookmark(_ id: Bookmark.ID, to label: String, in url: URL) {
        update(url) { metadata in
            guard let index = metadata.bookmarks.firstIndex(where: { $0.id == id }) else { return }
            metadata.bookmarks[index].label = label
        }
    }

    /// Moves an entry when its file is renamed, so nothing is orphaned.
    func transfer(from oldURL: URL, to newURL: URL) {
        guard let existing = entries.removeValue(forKey: oldURL.lastPathComponent) else { return }
        entries[newURL.lastPathComponent] = existing
        scheduleSave()
    }

    func forget(_ url: URL) {
        entries.removeValue(forKey: url.lastPathComponent)
        scheduleSave()
    }

    /// Drops entries whose clips no longer exist.
    func prune(keeping urls: [URL]) {
        let live = Set(urls.map(\.lastPathComponent))
        let before = entries.count
        entries = entries.filter { live.contains($0.key) }
        if entries.count != before { scheduleSave() }
    }

    private func update(_ url: URL, _ body: (inout ClipMetadata) -> Void) {
        var metadata = entries[url.lastPathComponent] ?? ClipMetadata()
        body(&metadata)

        if metadata.isEmpty {
            entries.removeValue(forKey: url.lastPathComponent)
        } else {
            entries[url.lastPathComponent] = metadata
        }
        scheduleSave()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: ClipMetadata].self, from: data)
        else { return }
        entries = decoded
    }

    /// Coalesces bursts of edits — dragging a bookmark, toggling several
    /// favourites — into one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.save()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.storage.error("Could not save clip metadata: \(error.localizedDescription, privacy: .public)")
        }
    }
}
