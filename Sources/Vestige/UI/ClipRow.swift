import SwiftUI

/// A thumbnail that loads lazily and fades in.
///
/// Generating a poster frame means decoding video, so it happens off the main
/// actor and only for clips actually on screen.
struct ClipThumbnail: View {
    let clip: Clip
    var width: CGFloat
    var height: CGFloat

    @Environment(AppModel.self) private var model
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: min(width, height) * 0.3))
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: 4))
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: clip.url) {
            image = await model.clips.thumbnail(for: clip)
        }
    }
}

/// One clip in a list. Shared between the menu bar panel and the library window
/// so both offer exactly the same actions.
struct ClipRow: View {
    enum Style {
        case compact
        case full
    }

    let clip: Clip
    var style: Style = .full

    var isRenaming = false
    var draftName: Binding<String> = .constant("")
    var onBeginRename: (() -> Void)?
    var onCommitRename: (() -> Void)?
    var onCancelRename: (() -> Void)?
    var onPlay: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var isHovering = false
    @FocusState private var isNameFocused: Bool

    private var thumbnailSize: CGSize {
        style == .compact ? CGSize(width: 56, height: 32) : CGSize(width: 96, height: 54)
    }

    private var isFavorite: Bool {
        model.metadata.isFavorite(clip.url)
    }

    private var bookmarkCount: Int {
        model.metadata.bookmarks(for: clip.url).count
    }

    var body: some View {
        HStack(spacing: 10) {
            ClipThumbnail(clip: clip, width: thumbnailSize.width, height: thumbnailSize.height)
                .overlay(alignment: .bottomTrailing) {
                    if bookmarkCount > 0, style == .full {
                        Label("\(bookmarkCount)", systemImage: "bookmark.fill")
                            .font(.system(size: 8))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.6), in: .capsule)
                            .foregroundStyle(.white)
                            .padding(3)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: draftName)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFocused)
                        .onSubmit { onCommitRename?() }
                        .onExitCommand { onCancelRename?() }
                        .onAppear { isNameFocused = true }
                } else {
                    HStack(spacing: 4) {
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                        Text(clip.name)
                            .font(style == .compact ? .caption : .body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if style == .full, !isRenaming {
                HStack(spacing: 2) {
                    // Favourite stays visible when set, so the row reads as
                    // marked even when the pointer is elsewhere.
                    IconButton(
                        symbol: isFavorite ? "star.fill" : "star",
                        help: isFavorite ? "Remove from favorites" : "Add to favorites",
                        tint: isFavorite ? .yellow : nil
                    ) {
                        model.metadata.toggleFavorite(clip.url)
                    }
                    .opacity(isFavorite || isHovering ? 1 : 0)

                    Group {
                        IconButton(symbol: "play.fill", help: "Play") { onPlay?() }
                        IconButton(symbol: "pencil", help: "Rename") { onBeginRename?() }
                        IconButton(symbol: "folder", help: "Show in Finder") { model.clips.reveal(clip) }
                        IconButton(symbol: "trash", help: "Move to Trash") { model.clips.delete(clip) }
                    }
                    .opacity(isHovering ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.12), value: isHovering)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .background(
            isHovering ? Color.primary.opacity(0.06) : .clear,
            in: .rect(cornerRadius: 6)
        )
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            if style == .full { onPlay?() } else { model.clips.open(clip) }
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clip.name), \(subtitle)\(isFavorite ? ", favorite" : "")")
    }

    private var subtitle: String {
        var parts = [
            Formatters.duration(clip.duration),
            Formatters.fileSize.string(fromByteCount: clip.fileSize),
            Formatters.clipTimestamp.string(from: clip.createdAt)
        ]
        if let game = model.metadata.gameName(for: clip.url) {
            parts.insert(game, at: 0)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var contextMenu: some View {
        if style == .full {
            Button("Play") { onPlay?() }
            Button("Rename…") { onBeginRename?() }
        }
        Button("Open in Default Player") { model.clips.open(clip) }
        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            model.metadata.toggleFavorite(clip.url)
        }
        Divider()
        Button("Show in Finder") { model.clips.reveal(clip) }
        Button("Copy Path") { model.clips.copyPath(clip) }
        Button("Copy Clip") { model.clips.copyFile(clip) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.clips.delete(clip) }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint ?? .primary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
