import AppKit
@preconcurrency import AVFoundation
import Observation

/// The clip library: everything Vestige knows about saved clips.
///
/// There is no database. The folder on disk is the single source of truth, so
/// clips remain fully usable if Vestige is uninstalled, and files moved or
/// deleted in Finder never leave a stale index behind.
@MainActor
@Observable
final class ClipStore {
    private(set) var clips: [Clip] = []
    private(set) var isLoading = false
    private(set) var directory: URL

    /// Set when the clips folder cannot be created or read.
    private(set) var storageError: String?

    /// Sidecar metadata, so renames and deletions can keep favourites and
    /// bookmarks in step with the files they describe.
    weak var metadata: ClipMetadataStore?

    /// The pasteboard change count from Vestige's last copy, so a compressed
    /// version only replaces a clip the user has not since copied over.
    private var lastCopyChangeCount = -1

    private let watcher = DirectoryWatcher()
    private let thumbnailCache = NSCache<NSURL, NSImage>()
    private var refreshTask: Task<Void, Never>?

    var totalSize: Int64 {
        clips.reduce(0) { $0 + $1.fileSize }
    }

    init(directory: URL) {
        self.directory = directory

        // Bounded by bytes, not count: 120 full-size poster frames would have
        // been ~100 MB of ceiling. 32 MB holds roughly 35 thumbnails — plenty
        // for every visible row — and NSCache still evicts earlier under
        // system memory pressure.
        thumbnailCache.totalCostLimit = 32 * 1024 * 1024
    }

    // MARK: - Location

    /// Points the store at a new folder and reloads.
    func setDirectory(_ url: URL) {
        guard url != directory else { return }
        directory = url
        beginWatching()
        Task { await refresh() }
    }

    /// Creates the clips folder if needed. Called before every save so that a
    /// folder deleted mid-session is silently recreated rather than failing.
    @discardableResult
    func ensureDirectoryExists() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            storageError = nil
            return true
        } catch {
            Log.storage.error("Cannot create clips folder: \(error.localizedDescription, privacy: .public)")
            storageError = "Vestige can't write to \(directory.lastPathComponent). Choose a different folder in Settings."
            return false
        }
    }

    /// A unique destination for a new clip.
    ///
    /// Two clips saved within the same second would otherwise collide, so a
    /// counter is appended rather than overwriting the earlier one.
    func destinationURL(gameName: String? = nil, date: Date = .now) -> URL {
        let base = Clip.filename(for: date, gameName: gameName)
        var candidate = directory.appending(path: base)

        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let stem = (base as NSString).deletingPathExtension
            candidate = directory.appending(path: "\(stem) (\(suffix)).mp4")
            suffix += 1
        }
        return candidate
    }

    /// Free space on the clips volume, used to warn before the disk fills.
    var availableCapacity: Int64? {
        try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Loading

    func beginWatching() {
        ensureDirectoryExists()
        watcher.watch(directory) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    /// Coalesces the burst of filesystem events a single write produces.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let directory = self.directory
        let urls = Self.clipURLs(in: directory)

        // Clips are write-once, so URL + size + creation date identify one
        // exactly. Matching entries keep their duration, turning the common
        // refresh into stat() calls rather than reopening every clip's moov
        // atom through AVFoundation.
        let known = Dictionary(clips.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })

        // Unknown durations still load concurrently; the cap stops a folder of
        // hundreds of clips from spawning hundreds of simultaneous reads.
        let loaded = await withTaskGroup(of: Clip?.self) { group in
            var started = 0
            var results: [Clip] = []
            let limit = 8

            var iterator = urls.makeIterator()
            while started < limit, let url = iterator.next() {
                group.addTask { await Self.loadClip(at: url, reusing: known[url]) }
                started += 1
            }

            while let finished = await group.next() {
                if let finished { results.append(finished) }
                if let url = iterator.next() {
                    group.addTask { await Self.loadClip(at: url, reusing: known[url]) }
                }
            }
            return results
        }

        // A clip saved while this refresh was loading is absent from `urls`,
        // listed before the file existed, and would vanish from the library
        // until the next refresh. Existence is rechecked so a clip deleted
        // meanwhile is not resurrected.
        let loadedURLs = Set(loaded.map(\.url))
        let addedDuringLoad = clips.filter {
            !loadedURLs.contains($0.url)
                && FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false))
        }

        let sorted = (loaded + addedDuringLoad).sorted { $0.createdAt > $1.createdAt }
        Log.storage.debug("Clip list refreshed: \(sorted.count, privacy: .public) clips")

        // Drop thumbnails for clips that no longer exist. Without this, deleting
        // a clip leaves its poster frame resident until the cache evicts it, and
        // a URL reused by a later clip would show the wrong image.
        let liveURLs = Set(sorted.map(\.url))
        for stale in clips where !liveURLs.contains(stale.url) {
            thumbnailCache.removeObject(forKey: stale.url as NSURL)
        }

        clips = sorted
    }

    private nonisolated static func clipURLs(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return contents.filter { $0.pathExtension.lowercased() == "mp4" }
    }

    private nonisolated static func loadClip(at url: URL, reusing existing: Clip?) async -> Clip? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }

        let createdAt = values?.creationDate ?? .distantPast
        let fileSize = Int64(values?.fileSize ?? 0)

        // Same file we already know: keep its duration without touching
        // AVFoundation. A zero duration is retried, in case the earlier load
        // raced a file still being written.
        if let existing, existing.fileSize == fileSize, existing.createdAt == createdAt,
           existing.duration > 0 {
            return existing
        }

        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0

        return Clip(
            url: url,
            createdAt: createdAt,
            fileSize: fileSize,
            duration: duration.isFinite ? duration : 0
        )
    }

    /// Inserts a clip immediately after saving, so it appears without waiting
    /// for the filesystem watcher to fire.
    func insert(_ clip: Clip) {
        clips.removeAll { $0.url == clip.url }
        clips.insert(clip, at: 0)
    }

    // MARK: - Thumbnails

    /// A poster frame for `clip`, taken one second in — far enough past any
    /// fade-in to show actual gameplay.
    func thumbnail(for clip: Clip) async -> NSImage? {
        if let cached = thumbnailCache.object(forKey: clip.url as NSURL) {
            return cached
        }
        // The generator returns a CGImage rather than an NSImage: CGImage is
        // Sendable and so can cross back from the background task, whereas
        // NSImage cannot. The wrapping happens here, on the main actor.
        guard let cgImage = await Self.generateThumbnail(for: clip.url, duration: clip.duration) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnailCache.setObject(
            image,
            forKey: clip.url as NSURL,
            cost: cgImage.width * cgImage.height * 4
        )
        return image
    }

    private nonisolated static func generateThumbnail(for url: URL, duration: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        // Screen content is static for long stretches; exact frame accuracy is
        // not worth the extra decoding.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let target = CMTime(seconds: min(1.0, max(0, duration / 2)), preferredTimescale: 600)

        return try? await generator.image(at: target).image
    }

    // MARK: - Actions

    /// Moves a clip to the Trash.
    ///
    /// Never `unlink`: gameplay clips are often irreplaceable, and a mis-click
    /// in a list should always be recoverable from the Trash.
    func delete(_ clip: Clip) {
        do {
            try FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
            clips.removeAll { $0.id == clip.id }
            thumbnailCache.removeObject(forKey: clip.url as NSURL)
            metadata?.forget(clip.url)
        } catch {
            Log.storage.error("Could not trash clip: \(error.localizedDescription, privacy: .public)")
            storageError = "Couldn't move \(clip.name) to the Trash."
        }
    }

    /// Renames a clip's file on disk.
    ///
    /// The filename is the name — there is no separate title stored anywhere —
    /// so a clip renamed here is renamed in Finder too, and stays renamed if
    /// Vestige is uninstalled. Sidecar metadata follows the file.
    @discardableResult
    func rename(_ clip: Clip, to newName: String) -> Clip? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != clip.name else { return nil }

        let safe = Clip.sanitizeName(trimmed)
        var destination = directory.appending(path: "\(safe).mp4")

        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = directory.appending(path: "\(safe) (\(suffix)).mp4")
            suffix += 1
        }

        do {
            try FileManager.default.moveItem(at: clip.url, to: destination)
        } catch {
            Log.storage.error("Rename failed: \(error.localizedDescription, privacy: .public)")
            storageError = "Couldn't rename \(clip.name)."
            return nil
        }

        metadata?.transfer(from: clip.url, to: destination)
        thumbnailCache.removeObject(forKey: clip.url as NSURL)

        var renamed = clip
        renamed.url = destination

        if let index = clips.firstIndex(where: { $0.id == clip.id }) {
            clips[index] = renamed
        }
        return renamed
    }

    func reveal(_ clip: Clip) {
        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    }

    func open(_ clip: Clip) {
        NSWorkspace.shared.open(clip.url)
    }

    /// Copies the POSIX path, and the file itself.
    ///
    /// Pasting into a terminal or text field yields the path; pasting into
    /// Finder, Mail, or Discord yields the actual clip.
    func copyPath(_ clip: Clip) {
        copy(clip.url)
    }

    /// Puts the clip itself on the clipboard, ready to paste into Discord,
    /// Messages, or a Finder window.
    func copyFile(_ clip: Clip) {
        copy(clip.url)
    }

    /// Swaps in a compressed version of a clip already on the clipboard.
    ///
    /// Compression finishes long after the save, so the original goes on the
    /// clipboard immediately and the smaller file replaces it when it is ready.
    /// If the user copied something else in the meantime, theirs stands.
    func replaceCopy(of original: URL, with compressed: URL) {
        guard NSPasteboard.general.changeCount == lastCopyChangeCount else { return }
        guard compressed != original else { return }
        copy(compressed)
    }

    /// Writes the file and its path as one pasteboard item.
    ///
    /// Both representations have to live on a single item: apps pick the
    /// richest type an item offers, so a file URL alone pastes as nothing at
    /// all in a plain text field.
    private func copy(_ url: URL) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path(percentEncoded: false), forType: .string)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            Log.storage.error("Could not put the clip on the clipboard")
            return
        }
        lastCopyChangeCount = pasteboard.changeCount
    }

    func openFolder() {
        ensureDirectoryExists()
        NSWorkspace.shared.open(directory)
    }
}
