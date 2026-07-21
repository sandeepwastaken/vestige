import SwiftUI

/// Explains why Screen Recording is needed and walks the user through granting it.
///
/// The wording is deliberately concrete about what Vestige does and does not do
/// with the permission. Screen Recording is the most invasive grant on macOS,
/// and an app that asks for it without explanation deserves to be refused.
struct PermissionsPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Screen Recording permission needed")
                    .font(.headline)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
            }

            Text("Vestige records your screen into a buffer that lives only in memory, and writes a file only when you press the hotkey. Nothing is uploaded, and nothing leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.permissions.requiresRelaunch {
                // macOS only hands capture access to processes that started
                // after the grant, so a restart is genuinely required here.
                Label("Permission granted — Vestige needs to restart to use it.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Restart Vestige") {
                    model.permissions.relaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 6) {
                    if model.permissions.hasPromptedThisLaunch {
                        // macOS answers the prompt once per binary and then
                        // stays silent, so re-offering it would be a button
                        // that visibly does nothing.
                        Button("Open System Settings") {
                            model.permissions.openSystemSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    } else {
                        Button("Grant Permission…") {
                            Task { await model.permissions.request() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                        Button("Open System Settings") {
                            model.permissions.openSystemSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                // The single most confusing state on macOS: the list shows
                // Vestige switched on, yet access is still refused. macOS binds
                // the grant to a build's signature, so a rebuilt app is a
                // different app wearing the same name.
                if model.permissions.hasPromptedThisLaunch {
                    Text("Already see Vestige switched on in that list? That entry belongs to an older build. Select it, click **−** to remove it, then quit and reopen Vestige.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // The manual re-check. Vestige polls every two seconds anyway, but
            // after ticking a box in System Settings you want to confirm it
            // landed rather than wait and wonder.
            HStack(spacing: 6) {
                Button {
                    Task { await model.permissions.recheck() }
                } label: {
                    HStack(spacing: 5) {
                        if model.permissions.isChecking {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(model.permissions.isChecking ? "Checking…" : "Check Again")
                    }
                }
                .disabled(model.permissions.isChecking)

                Spacer()

                if let checkedAt = model.permissions.lastCheckedAt {
                    Text("Checked \(checkedAt, format: .dateTime.hour().minute().second())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                }
            }
            .animation(.snappy(duration: 0.2), value: model.permissions.isChecking)
        }
    }
}
