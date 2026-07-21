import AppKit
import SwiftUI

struct AboutView: View {
    /// The build number is deliberately left out. It is meaningful to whoever
    /// cut the release and to nobody else, and "1.0.0 (1)" just reads like
    /// something that was meant to be filled in.
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        return "Version \(short)"
    }

    /// The real app icon, taken from the running bundle.
    ///
    /// Read from `NSApp` rather than loaded by name so it always matches what
    /// the user sees in Finder and the Dock, including any future revision of
    /// the artwork — there is no second copy here to fall out of date.
    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
        } else {
            // Only reachable when running the bare executable rather than the
            // assembled .app, which has no icon to report.
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            appIcon
                .padding(.top, 8)

            VStack(spacing: 3) {
                Text("Vestige")
                    .font(.largeTitle.weight(.semibold))
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("A free, open-source replay buffer for macOS.")
                .font(.callout)
                .multilineTextAlignment(.center)

            // The privacy claims are the point of the project, so they are
            // stated plainly rather than buried in a policy document.
            VStack(alignment: .leading, spacing: 6) {
                PrivacyPoint("No accounts, ever")
                PrivacyPoint("No network connections of any kind")
                PrivacyPoint("No telemetry, analytics, or ads")
                PrivacyPoint("Clips stay on your Mac, in a folder you choose")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))

            VStack(spacing: 2) {
                Text("Made for Mac gaming")
                Text("Released under the MIT License.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 340)
    }
}

private struct PrivacyPoint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }
}
