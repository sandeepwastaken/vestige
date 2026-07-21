import AppKit
import SwiftUI

/// Lets the user nominate which apps count as games.
///
/// Automatic detection is a heuristic and will always miss things — indie
/// titles that declare no category, emulators, Wine wrappers. Rather than
/// endlessly extending the guesswork, this makes the guess correctable: an app
/// in this list is a game by definition.
struct GamesSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var selection: Set<SelectedGame.ID> = []
    @State private var isShowingRunningApps = false

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                Picker("Capture", selection: $settings.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.captureMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.captureMode == .gameWindow {
                    Label(
                        "When no game is running, Vestige records the whole display instead.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("What to record")
            }

            Section {
                if settings.selectedGames.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No games added")
                            .foregroundStyle(.secondary)
                        Text("Vestige still detects games automatically. Add apps here when it misses one, or to be certain about a title you care about.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                } else {
                    List(selection: $selection) {
                        ForEach(settings.selectedGames) { game in
                            GameListRow(game: game, isRunning: isRunning(game))
                                .tag(game.id)
                        }
                    }
                    .frame(height: 168)
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                }

                HStack(spacing: 8) {
                    Button {
                        addFromFilePicker()
                    } label: {
                        Label("Add App…", systemImage: "plus")
                    }

                    Button {
                        isShowingRunningApps = true
                    } label: {
                        Label("Add Running App", systemImage: "square.stack.3d.up")
                    }
                    .popover(isPresented: $isShowingRunningApps, arrowEdge: .bottom) {
                        RunningApplicationPicker { game in
                            add(game)
                            isShowingRunningApps = false
                        }
                    }

                    Spacer()

                    Button {
                        removeSelected()
                    } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .disabled(selection.isEmpty)
                }
            } header: {
                Text("My games")
            } footer: {
                Text("The buffer starts when any of these launch or come to the front, whichever happens first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func isRunning(_ game: SelectedGame) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == game.bundleIdentifier
        }
    }

    private func add(_ game: SelectedGame) {
        guard !model.settings.selectedGames.contains(where: { $0.bundleIdentifier == game.bundleIdentifier }) else {
            return
        }
        model.settings.selectedGames.append(game)
        model.settings.selectedGames.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func removeSelected() {
        model.settings.selectedGames.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    private func addFromFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose the games Vestige should watch for."

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let game = SelectedGame(applicationURL: url) {
                add(game)
            }
        }
    }
}

private struct GameListRow: View {
    let game: SelectedGame
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = game.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "questionmark.app.dashed")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 20, height: 20)

            Text(game.name)
                .foregroundStyle(game.isInstalled ? .primary : .secondary)

            Spacer()

            if isRunning {
                Text("Running")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if !game.isInstalled {
                // Kept rather than silently dropped: the app may live on an
                // external drive that is merely unplugged right now.
                Text("Not installed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Picks from what is running right now — usually faster than hunting through
/// Finder, and the only practical way to add a game that lives somewhere
/// unusual, like a Steam library on another volume.
private struct RunningApplicationPicker: View {
    let onSelect: (SelectedGame) -> Void

    private var applications: [SelectedGame] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap(SelectedGame.init(runningApplication:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(applications) { app in
                    Button {
                        onSelect(app)
                    } label: {
                        HStack(spacing: 8) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 18, height: 18)
                            }
                            Text(app.name)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .frame(width: 260, height: 300)
    }
}
