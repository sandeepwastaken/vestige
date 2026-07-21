import SwiftUI

/// Compression, clipboard, and storage — everything about what happens to a
/// clip after it has been saved.
struct SharingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                // Presets first: most people want "Discord" and never to think
                // about bitrates at all.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], spacing: 6) {
                    ForEach(CompressionPreset.all) { preset in
                        presetButton(preset, settings: settings)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Presets")
            }

            Section {
                Picker("Compression", selection: $settings.compression.mode) {
                    ForEach(CompressionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                switch settings.compression.mode {
                case .none:
                    Text("Clips are saved exactly as captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .targetSize:
                    Stepper(
                        "Target size: \(settings.compression.targetMegabytes) MB",
                        value: $settings.compression.targetMegabytes,
                        in: 2...500,
                        step: 5
                    )
                    Text("Vestige works out the bitrate needed to land just under this, aiming slightly low so the finished file actually fits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .quality:
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent("Quality") {
                            Text("\(settings.compression.qualityPercent)%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.compression.qualityPercent) },
                                set: { settings.compression.qualityPercent = Int($0.rounded()) }
                            ),
                            in: 10...100,
                            step: 5
                        )
                    }
                    Text("100% keeps the captured bitrate. Lower values shrink the file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.compression.isEnabled {
                    Picker("Format", selection: $settings.compression.codec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.label).tag(codec)
                        }
                    }

                    // Not `VideoCodec.detail`: that is written for capture,
                    // where the codec decides file size. Here the size is
                    // already fixed by the target, so what actually differs is
                    // the picture quality bought with it.
                    Text(settings.compression.codec == .hevc
                         ? "Noticeably better picture at the same file size. Plays everywhere on Apple devices and in Discord's app."
                         : "Slightly softer at the same size, but plays in every browser, editor, and older client.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Keep the original as well", isOn: $settings.compression.keepsOriginal)

                    Text(settings.compression.keepsOriginal
                         ? "You get both: the untouched clip to edit from, and a compressed copy to share."
                         : "The compressed file replaces the original.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LabeledContent("Estimated size") {
                        Text(estimatedSize)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Compression")
            } footer: {
                Text("Compression runs in the background after the clip is saved, so saving stays instant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Toggle("Copy clips to the clipboard automatically", isOn: $settings.copiesToClipboard)

                Text(settings.compression.isEnabled
                     ? "The compressed copy is the one copied, so it can be pasted straight into Discord."
                     : "Paste into Discord, Messages, or Finder right after saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Delete clips", selection: $settings.retention) {
                    ForEach(RetentionPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .pickerStyle(.radioGroup)

                if settings.retention != .never {
                    Toggle("Always keep favorites", isOn: $settings.retentionKeepsFavorites)
                    Toggle("Always keep clips I've renamed", isOn: $settings.retentionKeepsNamed)

                    Label(
                        expiringDescription,
                        systemImage: expiringCount == 0 ? "checkmark.circle" : "trash"
                    )
                    .font(.caption)
                    .foregroundStyle(expiringCount == 0 ? Color.secondary : Color.orange)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Deleted clips go to the Trash, never straight to nowhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func presetButton(_ preset: CompressionPreset, settings: SettingsStore) -> some View {
        let isActive = settings.compression == preset.settings

        return Button {
            settings.compression = preset.settings
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(preset.name, systemImage: preset.symbol)
                    .font(.caption.weight(.medium))
                Text(preset.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .accentColor : nil)
    }

    private var estimatedSize: String {
        let bitrate = model.capture.activeConfiguration?.bitrate ?? 12_000_000
        let bytes = model.settings.compression.estimatedBytes(
            duration: model.settings.replayDuration.seconds,
            captureBitrate: bitrate
        )
        return Formatters.fileSize.string(fromByteCount: bytes)
    }

    private var expiringCount: Int {
        RetentionSweeper.expiredClips(
            in: model.clips.clips,
            rules: RetentionSweeper.Rules(
                policy: model.settings.retention,
                keepsFavorites: model.settings.retentionKeepsFavorites,
                keepsNamed: model.settings.retentionKeepsNamed
            ),
            metadata: model.metadata
        ).count
    }

    private var expiringDescription: String {
        let count = expiringCount
        return count == 0
            ? "Nothing in your library is old enough to be removed."
            : "\(count) clip\(count == 1 ? "" : "s") would be moved to the Trash."
    }
}
