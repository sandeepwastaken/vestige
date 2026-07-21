@preconcurrency import AVKit
import SwiftUI

/// Resolves a URL to a clip before showing the player.
///
/// `WindowGroup(for:)` can only carry a `Codable` value, so the window is opened
/// with a URL and the clip's metadata is looked up here. If the clip is gone —
/// deleted while the window was closed — this says so rather than showing an
/// empty player.
struct ClipPlayerLoader: View {
    let url: URL
    @Environment(AppModel.self) private var model

    var body: some View {
        if let clip = model.clips.clips.first(where: { $0.url == url }) {
            ClipPlayerView(clip: clip)
        } else {
            ContentUnavailableView(
                "Clip Unavailable",
                systemImage: "film.slash",
                description: Text("It may have been moved, renamed, or deleted.")
            )
            .task { await model.clips.refresh() }
        }
    }
}

/// Plays a clip and lets the user mark moments inside it.
///
/// Bookmarks are the reason this exists rather than just handing the file to
/// QuickTime. They are stored in Vestige's sidecar and never written into the
/// MP4, so a clip you share is unmarked — the notes are for finding your own
/// moments again later, not for the person you send it to.
struct ClipPlayerView: View {
    let clip: Clip

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var player = AVPlayer()
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var newBookmarkLabel = ""
    @State private var editingBookmark: Bookmark.ID?
    @State private var timeObserver: Any?
    @FocusState private var isLabelFocused: Bool

    private var bookmarks: [Bookmark] {
        model.metadata.bookmarks(for: clip.url)
    }

    var body: some View {
        HSplitView {
            playerPane
                .frame(minWidth: 480)

            bookmarkPane
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        }
        .frame(minWidth: 760, minHeight: 460)
        .navigationTitle(clip.name)
        .task {
            await load()
        }
        .onDisappear {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
            player.pause()
        }
    }

    // MARK: - Player

    private var playerPane: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // A second scrubber below the player, marked with the bookmarks.
            // AVKit's own bar cannot show them, and being able to see where the
            // good moments are is the entire point.
            bookmarkTimeline
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
        }
    }

    private var bookmarkTimeline: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 4)

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * progress, height: 4)

                    ForEach(bookmarks) { bookmark in
                        let x = duration > 0 ? proxy.size.width * (bookmark.time / duration) : 0
                        Circle()
                            .fill(.yellow)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                            .position(x: x, y: 2)
                            .help("\(Formatters.duration(bookmark.time)) · \(bookmark.label)")
                            .onTapGesture { seek(to: bookmark.time) }
                    }
                }
                .frame(height: 12)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        guard duration > 0, proxy.size.width > 0 else { return }
                        let fraction = min(max(value.location.x / proxy.size.width, 0), 1)
                        seek(to: fraction * duration)
                    }
                )
            }
            .frame(height: 12)

            HStack {
                Text(Formatters.duration(currentTime))
                Spacer()
                Text(Formatters.duration(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, currentTime / duration)
    }

    // MARK: - Bookmarks

    private var bookmarkPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Bookmarks", systemImage: "bookmark.fill")
                    .font(.headline)
                Spacer()
                Text("\(bookmarks.count)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(12)

            Divider()

            if bookmarks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bookmark")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("No bookmarks yet")
                        .foregroundStyle(.secondary)
                    Text("Pause at a moment worth remembering and give it a name.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(bookmarks) { bookmark in
                            bookmarkRow(bookmark)
                        }
                    }
                    .padding(8)
                }
            }

            Divider()
            addBookmarkBar
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 8) {
            Text(Formatters.duration(bookmark.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, alignment: .leading)

            if editingBookmark == bookmark.id {
                TextField("Label", text: Binding(
                    get: { bookmark.label },
                    set: { model.metadata.renameBookmark(bookmark.id, to: $0, in: clip.url) }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { editingBookmark = nil }
            } else {
                Text(bookmark.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Button {
                model.metadata.removeBookmark(bookmark.id, from: clip.url)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove bookmark")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 5))
        .onTapGesture { seek(to: bookmark.time) }
        .onTapGesture(count: 2) { editingBookmark = bookmark.id }
        .contextMenu {
            Button("Jump Here") { seek(to: bookmark.time) }
            Button("Rename") { editingBookmark = bookmark.id }
            Divider()
            Button("Remove", role: .destructive) {
                model.metadata.removeBookmark(bookmark.id, from: clip.url)
            }
        }
    }

    private var addBookmarkBar: some View {
        HStack(spacing: 6) {
            TextField("Mark this moment…", text: $newBookmarkLabel)
                .textFieldStyle(.roundedBorder)
                .focused($isLabelFocused)
                .onSubmit(addBookmark)

            Button {
                addBookmark()
            } label: {
                Label("\(Formatters.duration(currentTime))", systemImage: "bookmark.fill")
            }
            .help("Add a bookmark at the current time")
        }
        .padding(10)
    }

    private func addBookmark() {
        let label = newBookmarkLabel.trimmingCharacters(in: .whitespaces)
        let bookmark = Bookmark(
            time: currentTime,
            label: label.isEmpty ? "Bookmark" : label
        )
        model.metadata.addBookmark(bookmark, to: clip.url)
        newBookmarkLabel = ""
    }

    // MARK: - Playback

    private func load() async {
        let asset = AVURLAsset(url: clip.url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))

        if let loaded = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(loaded)
        }

        // Twice a second is enough to keep the playhead and bookmark markers
        // honest without waking the main thread on every frame.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { time in
            MainActor.assumeIsolated {
                currentTime = CMTimeGetSeconds(time)
            }
        }
    }

    private func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }
}
