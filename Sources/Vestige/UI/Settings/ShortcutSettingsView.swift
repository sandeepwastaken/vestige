import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Every shortcut Vestige responds to, all rebindable.
struct ShortcutSettingsView: View {
    @Environment(AppModel.self) private var model

    private var conflicts: Set<HotkeyAction> {
        model.hotkeys.conflicts(in: model.settings.hotkeys)
    }

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    SettingsRow(title: action.label, help: action.detail) {
                        HStack(spacing: 4) {
                            HotkeyRecorder(
                                binding: Binding(
                                    get: { model.settings.hotkeys[action] },
                                    set: { model.settings.hotkeys[action] = $0 }
                                )
                            )

                            if model.settings.hotkeys[action] != nil {
                                Button {
                                    model.settings.hotkeys[action] = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove this shortcut")
                            }
                        }
                    }

                    if conflicts.contains(action) {
                        Label("This combination is used by another action.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if model.hotkeys.failedActions.contains(action) {
                        Label("Another app already owns this combination.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Vestige registers these with the window server directly, so it does not need Accessibility access and never sees any other key you press. Leave one empty to disable it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button("Reset All to Defaults") {
                    model.settings.hotkeys = HotkeyAction.allCases.reduce(
                        into: [HotkeyAction: HotkeyBinding]()
                    ) { result, action in
                        if let binding = action.defaultBinding { result[action] = binding }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A click-to-record shortcut field.
///
/// Uses a local `NSEvent` monitor rather than a custom first-responder view:
/// while recording, the monitor swallows every key press before SwiftUI's focus
/// system can interpret it, which is what allows combinations like ⌘Q or ⌘W to
/// be captured instead of quitting or closing the window.
struct HotkeyRecorder: View {
    @Binding var binding: HotkeyBinding?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var isHovering = false

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(label)
                .font(.body.monospaced())
                .foregroundStyle(isRecording || binding == nil ? .secondary : .primary)
                .frame(minWidth: 96)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isRecording ? Color.accentColor : Color.secondary.opacity(isHovering ? 0.5 : 0.25),
                            lineWidth: isRecording ? 2 : 1
                        )
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isRecording)
        .help("Click, then press the key combination you want")
        // Recording must never outlive the view, or the monitor would keep
        // swallowing keystrokes across the whole app.
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return binding?.displayString ?? "Not set"
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape cancels, Delete clears.
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            if event.keyCode == UInt16(kVK_Delete) {
                binding = nil
                stopRecording()
                return nil
            }

            if let captured = HotkeyBinding(event: event) {
                binding = captured
                stopRecording()
            }

            // Swallow the event either way: a modifier-less key press is not a
            // valid shortcut, but it should not leak into the UI behind us.
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }
}
