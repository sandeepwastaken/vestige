import SwiftUI

/// Live resource usage, shown at the bottom of the menu bar panel.
///
/// A tool that runs all session should be willing to show what it costs. The
/// figures are for Vestige's own process, sampled only while the panel is open.
///
/// There is no GPU percentage because macOS publishes no per-process GPU
/// utilisation API. Rather than print a plausible-looking guess, the encoder
/// row states whether the hardware encoder is doing the work — which is the
/// question a GPU number would have been standing in for.
struct ResourceReadout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            metric(
                "CPU",
                value: String(format: "%.1f%%", model.resources.sample.cpuPercent),
                symbol: "cpu",
                isWarning: model.resources.sample.cpuPercent > 25
            )

            divider

            metric(
                "RAM",
                value: Formatters.fileSize.string(fromByteCount: Int64(model.resources.sample.memoryBytes)),
                symbol: "memorychip",
                isWarning: model.resources.sample.memoryBytes > 1_500_000_000
            )

            divider

            metric(
                "Disk",
                value: diskText,
                symbol: "internaldrive",
                isWarning: false
            )

            divider

            metric(
                "Encoder",
                value: encoderText,
                symbol: "bolt",
                isWarning: model.capture.state == .running && !model.capture.isHardwareAccelerated
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .task {
            model.resources.start()
        }
        .onDisappear {
            model.resources.stop()
        }
    }

    private var divider: some View {
        Divider().frame(height: 20)
    }

    private var diskText: String {
        let bytes = model.resources.sample.diskBytesPerSecond
        guard bytes > 1024 else { return "—" }
        return "\(Formatters.fileSize.string(fromByteCount: Int64(bytes)))/s"
    }

    private var encoderText: String {
        guard model.capture.state == .running else { return "Idle" }
        return model.capture.isHardwareAccelerated ? "Hardware" : "Software"
    }

    private func metric(_ label: String, value: String, symbol: String, isWarning: Bool) -> some View {
        VStack(spacing: 1) {
            Label(label, systemImage: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .labelStyle(.titleOnly)

            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isWarning ? Color.orange : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
