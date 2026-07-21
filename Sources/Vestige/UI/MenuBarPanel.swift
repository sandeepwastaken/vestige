import SwiftUI

/// The panel shown when the menu bar icon is clicked.
///
/// Ordered by how often each element is needed: status first so a glance
/// answers "is it running?", then the save action, then recent clips, then
/// everything else. Nothing here requires scrolling at the default size.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var isNamingProfile = false
    @State private var profileName = ""

    private static let recentClipCount = 3

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if model.permissions.isAuthorized {
                mainContent
            } else {
                PermissionsPrompt()
                    .padding(14)
            }

            Divider()

            ResourceReadout()

            Divider()

            footer
        }
        .frame(width: 320)
        .alert("Save Profile", isPresented: $isNamingProfile) {
            TextField("Name", text: $profileName)
            Button("Cancel", role: .cancel) { profileName = "" }
            Button("Save") {
                let name = profileName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let profile = model.settings.makeProfile(named: name)
                model.settings.profiles.append(profile)
                model.settings.activeProfileID = profile.id
                profileName = ""
            }
        } message: {
            Text("Stores the current resolution, frame rate, codec, audio, replay length, and compression settings together.")
        }
        // These work together; neither is sufficient alone. `fixedSize` makes
        // the panel report its true intrinsic height instead of stretching to
        // fill the window, which also makes the measurement a stable fixed
        // point. `sizesMenuBarWindow` then resizes the window to match, since
        // MenuBarExtra never shrinks its panel on its own.
        .fixedSize(horizontal: false, vertical: true)
        .sizesMenuBarWindow()
        .task {
            model.beginStatisticsUpdates()

            // Recount the clips folder every time the panel opens rather than
            // trusting the list from last time. The directory watcher keeps it
            // current on its own, but this makes opening the panel the moment
            // of truth — so a clip deleted in Finder can never leave a row (and
            // the space it occupies) behind.
            await model.clips.refresh()
        }
        .onDisappear {
            model.endStatisticsUpdates()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            StatusIndicator(isActive: model.isBuffering)

            VStack(alignment: .leading, spacing: 1) {
                Text("Vestige")
                    .font(.headline)

                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                profilePicker

                if let game = model.games.currentGame {
                    Text(game.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 110, alignment: .trailing)
                        .help("Detected game: \(game.name)")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Main

    private var mainContent: some View {
        VStack(spacing: 12) {
            if model.isBuffering {
                BufferGauge(
                    progress: model.bufferProgress,
                    seconds: model.bufferStatistics.bufferedSeconds,
                    target: model.settings.replayDuration.rawValue
                )

                Label(model.captureTargetText, systemImage: model.capture.target.isWindow ? "macwindow" : "display")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Warns before the clip is saved rather than after it is found
                // to be silent.
                if model.isMissingAudio {
                    Label("No system audio yet — clips will be silent", systemImage: "speaker.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("Play some sound in the game. If this stays, check that system audio is enabled in Settings > Recording.")
                }
            }

            // Replay length changes with the game — a 30-second clip for a
            // shooter, five minutes for a raid. Burying that in Settings would
            // make it a chore, so the presets live one click from the icon.
            durationPicker

            saveButton

            // Shorter alternatives to the full buffer. With a ten-minute buffer
            // most moments are worth fifteen seconds, and trimming here means
            // never having to edit afterwards.
            if model.isBuffering {
                quickSaveRow
            }

            HStack(spacing: 6) {
                Button {
                    Task { await model.togglePause() }
                } label: {
                    Label(
                        model.isPaused ? "Resume" : "Pause",
                        systemImage: model.isPaused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.permissions.isAuthorized)
                .help(model.isPaused ? "Start buffering again" : "Stop buffering without quitting")

                // Under the manual policy nothing else will start the buffer, so
                // the control has to live here.
                if model.settings.bufferPolicy == .manual, !model.isPaused {
                    Button {
                        Task { await model.toggleBuffer() }
                    } label: {
                        Label(
                            model.isManuallyArmed ? "Stop" : "Start",
                            systemImage: model.isManuallyArmed ? "stop.fill" : "record.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.permissions.isAuthorized)
                }
            }

            if let message = model.lastMessage {
                StatusBanner(message: message)
            }

            if !model.clips.clips.isEmpty {
                recentClips
            }
        }
        .padding(14)
        // No implicit animation here, deliberately. Everything inside can change
        // the panel's height, and a menu bar window measuring its content
        // mid-animation settles on the tallest value it saw rather than the
        // final one, leaving dead space that never reclaims itself.
        //
        // Animations that do not affect layout (the pulsing dot, the progress
        // bar) are scoped to their own views and still run.
    }

    private var saveButton: some View {
        Button {
            Task { await model.saveReplay() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.fill")
                Text(model.isSavingClip ? "Saving…" : "Save Replay")
                Spacer()
                if let binding = model.settings.hotkeys[.saveReplay] {
                    Text(binding.displayString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(!model.isBuffering || model.isSavingClip)
        .help(model.isBuffering
              ? "Save the last \(model.settings.replayDuration.rawValue) seconds"
              : "The replay buffer isn't running")
    }

    /// Save buttons for shorter spans than the full buffer.
    private var quickSaveRow: some View {
        HStack(spacing: 3) {
            Text("Save last")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach([15.0, 30.0, 60.0], id: \.self) { seconds in
                Button {
                    Task { await model.saveReplay(seconds: seconds) }
                } label: {
                    Text(Formatters.duration(seconds))
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 1)
                }
                .buttonStyle(.bordered)
                .disabled(model.isSavingClip || model.bufferedSeconds < seconds)
                .help("Save only the last \(Int(seconds)) seconds")
            }
        }
    }

    /// Switches between saved capture profiles.
    private var profilePicker: some View {
        @Bindable var settings = model.settings

        return Menu {
            ForEach(settings.profiles) { profile in
                Button {
                    settings.apply(profile)
                } label: {
                    if settings.activeProfileID == profile.id, settings.matchesActiveProfile {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }

            Divider()

            Button("Save Current Settings as Profile…") {
                isNamingProfile = true
            }

            Button("Manage Profiles…") {
                open(WindowID.settings)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text(activeProfileName)
                    .lineLimit(1)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch capture profile")
    }

    private var activeProfileName: String {
        guard let id = model.settings.activeProfileID,
              let profile = model.settings.profiles.first(where: { $0.id == id })
        else { return "Custom" }
        return model.settings.matchesActiveProfile ? profile.name : "\(profile.name) (edited)"
    }

    private var durationPicker: some View {
        @Bindable var settings = model.settings

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Replay length")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !settings.replayDuration.isPreset {
                    Text(settings.replayDuration.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 3) {
                ForEach(ReplayDuration.presets) { preset in
                    Button {
                        settings.replayDuration = preset
                    } label: {
                        Text(preset.shortLabel)
                            .font(.caption2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.bordered)
                    .tint(settings.replayDuration == preset ? .accentColor : nil)
                    .help("Keep the last \(preset.label)")
                }
            }
        }
    }

    private var recentClips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Show All") {
                    open(WindowID.clips)
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            VStack(spacing: 2) {
                ForEach(model.clips.clips.prefix(Self.recentClipCount)) { clip in
                    ClipRow(clip: clip, style: .compact)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            // Opens Vestige's own library rather than Finder. The library is the
            // richer surface — search, sorting, favourites — so it gets the
            // prominent slot; Finder is one click further in, from there.
            PanelMenuItem(title: "Open Clips", symbol: "film.stack") {
                open(WindowID.clips)
            }
            PanelMenuItem(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") {
                open(WindowID.settings)
            }
            PanelMenuItem(title: "About Vestige", symbol: "info.circle") {
                open(WindowID.about)
            }

            Divider()
                .padding(.vertical, 4)

            PanelMenuItem(title: "Quit Vestige", symbol: "power", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    /// Opens an auxiliary window and brings it to the front.
    ///
    /// An accessory-policy app does not activate on its own, so without the
    /// explicit `activate` the window appears behind whatever the user was
    /// doing — behind the game, in this app's case.
    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Components

/// A pulsing dot that reads as "live" without being distracting.
///
/// Driven by `TimelineView` rather than a `repeatForever` animation. The panel
/// re-renders twice a second to update the buffer readout, and every one of
/// those re-renders would restart a state-driven repeating animation mid-cycle —
/// which is exactly the stutter this replaces. Deriving the phase from the
/// timeline's own clock makes the ring's position a pure function of the time,
/// so it cannot be knocked off course by anything happening around it.
private struct StatusIndicator: View {
    let isActive: Bool

    private let period: Double = 1.8

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)

            if isActive {
                // Capped at 30fps: the default animation schedule runs at the
                // display's full refresh rate, and a soft pulse cannot use 120
                // frames a second — it only costs main-thread wakeups while the
                // panel is open.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    // Continuous 0→1 ramp that restarts cleanly every period.
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let phase = (elapsed.truncatingRemainder(dividingBy: period)) / period

                    Circle()
                        .stroke(Color.red, lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                        .scaleEffect(1 + phase * 1.3)
                        // Eased fade, so the ring dissolves rather than
                        // vanishing at the loop point.
                        .opacity((1 - phase) * (1 - phase) * 0.55)
                }
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// Shows how much footage is currently held.
private struct BufferGauge: View {
    let progress: Double
    let seconds: Double
    let target: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Replay buffer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(seconds.rounded()))s / \(target)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)

                    Capsule()
                        .fill(Color.accentColor.gradient)
                        .frame(width: max(4, proxy.size.width * progress))
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.4), value: progress)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replay buffer \(Int(seconds.rounded())) of \(target) seconds")
    }
}

private struct StatusBanner: View {
    let message: AppModel.StatusMessage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: message.kind == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(message.kind == .success ? Color.green : Color.orange)
            Text(message.text)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}

/// A row styled to match a native menu item, including hover highlighting.
private struct PanelMenuItem: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background(
                isHovering ? Color.accentColor.opacity(0.15) : .clear,
                in: .rect(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
