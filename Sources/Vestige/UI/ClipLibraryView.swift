import SwiftUI

/// The full clip library: search, sort, favourite, rename, and play.
struct ClipLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var searchText = ""
    @State private var sort: ClipSort = .newest
    @State private var selection: Clip.ID?
    @State private var renamingClip: Clip.ID?
    @State private var draftName = ""

    private var sections: [ClipSection] {
        ClipOrganizer.sections(
            for: model.clips.clips,
            sort: sort,
            metadata: model.metadata,
            searchText: searchText
        )
    }

    var body: some View {
        Group {
            if model.clips.clips.isEmpty {
                emptyState
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                clipList
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .searchable(text: $searchText, prompt: "Search names, games, and bookmarks")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Sort", selection: $sort) {
                    ForEach(ClipSort.allCases) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .help("Change how clips are ordered")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.clips.openFolder()
                } label: {
                    Label("Open Clips Folder", systemImage: "folder")
                }
                .labelStyle(.titleAndIcon)
                .help("Reveal the clips folder in Finder")
            }
        }
        .navigationTitle("Clips")
        .task {
            await model.clips.refresh()
        }
    }

    private var clipList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        LazyVStack(spacing: 1) {
                            ForEach(section.clips) { clip in
                                row(for: clip)
                            }
                        }
                    } header: {
                        if !section.title.isEmpty {
                            sectionHeader(section)
                        }
                    }
                }
            }
            .padding(10)
        }
        .safeAreaInset(edge: .bottom) { summaryBar }
    }

    private func sectionHeader(_ section: ClipSection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: section.symbol)
                .foregroundStyle(section.title == "Favorites" ? Color.yellow : .secondary)
            Text(section.title)
                .font(.headline)
            Text("\(section.clips.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(.background.opacity(0.94))
    }

    private func row(for clip: Clip) -> some View {
        ClipRow(
            clip: clip,
            style: .full,
            isRenaming: renamingClip == clip.id,
            draftName: $draftName,
            onBeginRename: {
                renamingClip = clip.id
                draftName = clip.name
            },
            onCommitRename: {
                if let renamed = model.clips.rename(clip, to: draftName) {
                    selection = renamed.id
                }
                renamingClip = nil
            },
            onCancelRename: { renamingClip = nil },
            onPlay: { openWindow(id: WindowID.player, value: clip.url) }
        )
        .background(
            selection == clip.id ? Color.accentColor.opacity(0.15) : .clear,
            in: .rect(cornerRadius: 6)
        )
        .onTapGesture { selection = clip.id }
    }

    private var summaryBar: some View {
        let shown = sections.reduce(0) { $0 + $1.clips.count }
        return HStack {
            Text("\(shown) clip\(shown == 1 ? "" : "s")")
            if shown != model.clips.clips.count {
                Text("of \(model.clips.clips.count)")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(Formatters.fileSize.string(fromByteCount: model.clips.totalSize))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Clips Yet", systemImage: "film.stack")
        } description: {
            if let binding = model.settings.hotkeys[.saveReplay] {
                Text("Press \(binding.displayString) while the buffer is running to save the last \(model.settings.replayDuration.label).")
            } else {
                Text("Set a save shortcut in Settings, then press it while the buffer is running.")
            }
        } actions: {
            Button("Open Clips Folder") { model.clips.openFolder() }
        }
    }
}
