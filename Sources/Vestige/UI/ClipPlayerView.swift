import AVFoundation
import CoreMedia
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

/// The video surface.
///
/// A plain `AVPlayerLayer` rather than AVKit's SwiftUI `VideoPlayer`. That view
/// is backed by an internal class whose superclass is the Objective-C
/// `AVPlayerView`, and a SwiftPM-built binary never links the AVKit framework
/// that vends it — so the Swift runtime cannot resolve the superclass metadata
/// and calls `abort()` the moment the view is materialised. In a menu bar app
/// that reads as "clicking a clip quits Vestige". `AVPlayerLayer` lives in
/// AVFoundation, which is already linked for capture and encoding, so this
/// draws frames with no AVKit involvement at all.
private final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Implicit animation would make the video lag a window resize by a frame.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
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

    @State private var player = AVPlayer()
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var isMuted = false
    @State private var loadFailed = false
    @State private var newBookmarkLabel = ""
    @State private var editingBookmark: Bookmark.ID?
    @State private var timeObserver: Any?
    @State private var endObservers = NotificationObservers()
    @FocusState private var isPlayerFocused: Bool

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
            timeObserver = nil
            player.pause()
        }
    }

    // MARK: - Player

    private var playerPane: some View {
        VStack(spacing: 0) {
            videoSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // A scrubber below the video, marked with the bookmarks. Being able
            // to see where the good moments are is the entire point.
            VStack(spacing: 10) {
                bookmarkTimeline
                transportControls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .focusable()
        .focused($isPlayerFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            togglePlayback()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            seek(to: currentTime - 5)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            seek(to: currentTime + 5)
            return .handled
        }
    }

    @ViewBuilder
    private var videoSurface: some View {
        if loadFailed {
            ContentUnavailableView(
                "Can't Play This Clip",
                systemImage: "exclamationmark.triangle",
                description: Text("The file may be damaged or still being written.")
            )
        } else {
            PlayerSurface(player: player)
                .background(.black)
                .overlay {
                    // The paused state needs to be readable at a glance, since
                    // there is no chrome on the video itself.
                    if !isPlaying {
                        Image(systemName: "play.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(24)
                            .background(.black.opacity(0.35), in: .circle)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isPlaying)
                .contentShape(.rect)
                .onTapGesture {
                    isPlayerFocused = true
                    togglePlayback()
                }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 14) {
            Button {
                seek(to: currentTime - 10)
            } label: {
                Image(systemName: "gobackward.10")
            }
            .help("Back 10 seconds")

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 24)
            }
            .help(isPlaying ? "Pause" : "Play")

            Button {
                seek(to: currentTime + 10)
            } label: {
                Image(systemName: "goforward.10")
            }
            .help("Forward 10 seconds")

            Spacer()

            Button {
                isMuted.toggle()
                player.isMuted = isMuted
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .help(isMuted ? "Unmute" : "Mute")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .disabled(loadFailed)
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

        // A clip still being muxed, or one truncated by a crash, would otherwise
        // show a black rectangle that never starts.
        guard let isPlayable = try? await asset.load(.isPlayable), isPlayable else {
            loadFailed = true
            return
        }

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted

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

        // Reaching the end leaves the player paused on the last frame; without
        // this the button would still read "pause".
        endObservers.observe(AVPlayerItem.didPlayToEndTimeNotification, object: item) {
            isPlaying = false
        }

        // The window was opened by someone who clicked a clip to watch it.
        play()
        isPlayerFocused = true
    }

    private func togglePlayback() {
        guard !loadFailed else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            play()
        }
    }

    private func play() {
        // Playing from the last frame would otherwise do nothing at all.
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    private func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }
}
