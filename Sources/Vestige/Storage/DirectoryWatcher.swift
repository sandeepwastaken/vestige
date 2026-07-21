import Foundation

/// Watches a directory and reports when its contents change.
///
/// This keeps the clip list correct when files are added, renamed, or deleted
/// outside Vestige — dragging a clip to the Trash in Finder should not leave a
/// ghost entry in the app.
///
/// Uses a kqueue-backed `DispatchSource` rather than FSEvents: a single
/// non-recursive directory is exactly what kqueue is good at, and it needs no
/// event-stream bookkeeping across launches.
final class DirectoryWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let queue = DispatchQueue(label: "app.vestige.directory-watcher", qos: .utility)

    /// Starts watching `url`, replacing any previous target.
    ///
    /// `onChange` may fire several times for one logical change (a write, then a
    /// rename, then an attribute update), so callers should debounce or make
    /// their handler cheap and idempotent.
    func watch(_ url: URL, onChange: @escaping @Sendable () -> Void) {
        stop()

        descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else {
            Log.storage.error("Could not watch \(url.lastPathComponent, privacy: .public)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler(handler: onChange)

        // The cancel handler owns closing the descriptor. Closing it anywhere
        // else risks the kernel handing the number to another open() while the
        // source still references it.
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }

        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit {
        stop()
    }
}
