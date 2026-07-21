import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                SettingsRow(title: "Save clips to") {
                    HStack(spacing: 6) {
                        Text(displayPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                            .help(settings.outputDirectory.path(percentEncoded: false))

                        Button("Choose…", action: chooseFolder)
                    }
                }

                if let error = model.clips.storageError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                LabeledContent("Library") {
                    Text("\(model.clips.clips.count) clips · \(Formatters.fileSize.string(fromByteCount: model.clips.totalSize))")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Buffering") {
                Picker("Run the buffer", selection: $settings.bufferPolicy) {
                    ForEach(BufferPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.bufferPolicy.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.bufferPolicy == .whilePlaying, let game = model.games.currentGame {
                    Label("Detected: \(game.name)", systemImage: "gamecontroller.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notifications") {
                Toggle("Show a notification when a clip is saved", isOn: $settings.showsNotifications)
                Toggle("Play a sound when a clip is saved", isOn: $settings.playsSoundOnSave)

                if settings.showsNotifications && !model.notifications.isAuthorized {
                    Label(
                        "Notifications are turned off for Vestige in System Settings.",
                        systemImage: "bell.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Startup") {
                Toggle("Launch Vestige at login", isOn: Binding(
                    get: { model.launchAtLogin.isEnabled },
                    set: { model.launchAtLogin.setEnabled($0) }
                ))

                if let error = model.launchAtLogin.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            model.launchAtLogin.refresh()
            await model.notifications.refreshAuthorization()
        }
    }

    /// Abbreviates the home directory so the path stays readable in a narrow row.
    private var displayPath: String {
        let path = model.settings.outputDirectory.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count - 1) : path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Vestige should save clips."
        panel.directoryURL = model.settings.outputDirectory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.outputDirectory = url
    }
}
