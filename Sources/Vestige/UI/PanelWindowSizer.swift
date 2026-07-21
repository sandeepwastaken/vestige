import AppKit
import SwiftUI

/// Forces the menu bar panel's window to match its content's height.
///
/// `MenuBarExtra(.window)` sizes its panel on first layout and never shrinks
/// it, so anything that makes the content shorter — pausing, deleting a clip, a
/// banner timing out — leaves it in a too-tall window. SwiftUI offers no fix.
///
/// This cannot oscillate: the panel applies `.fixedSize(vertical: true)`, so
/// its height is intrinsic rather than a function of the space offered, making
/// the measurement a fixed point rather than a feedback loop.
struct PanelWindowSizer: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard contentHeight > 1 else { return }

        // Deferred because `updateNSView` runs inside SwiftUI's layout pass;
        // resizing the window from within it fights the very layout that is
        // still in progress. It also gives the view time to be added to a
        // window, which has not happened yet on the first update.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }

            // Never let a bad measurement produce an unusable window. A height
            // of zero or one taller than the display would both be worse than
            // the bug being fixed.
            let maximum = window.screen?.visibleFrame.height ?? 1200
            let target = min(max(contentHeight, 80), maximum)

            let current = window.frame.height
            guard abs(current - target) > 0.5 else { return }

            var frame = window.frame
            // Menu bar panels hang from the top edge, so the top must stay put
            // while the bottom moves — otherwise the panel drifts away from the
            // menu bar as it resizes.
            frame.origin.y += frame.height - target
            frame.size.height = target

            window.setFrame(frame, display: true, animate: false)

            Log.app.debug("""
                Panel resized \(Int(current), privacy: .public)pt \
                -> \(Int(target), privacy: .public)pt
                """)
        }
    }
}

/// Carries the panel's measured height up to the sizer.
struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Keeps the enclosing menu bar window exactly as tall as this view.
    func sizesMenuBarWindow() -> some View {
        modifier(MenuBarWindowSizing())
    }
}

private struct MenuBarWindowSizing: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                }
            }
            // `onPreferenceChange` hands its value to a Sendable closure, which
            // cannot touch main-actor state directly.
            .onPreferenceChange(PanelHeightKey.self) { measured in
                Task { @MainActor in height = measured }
            }
            .background {
                PanelWindowSizer(contentHeight: height)
                    .frame(width: 0, height: 0)
            }
    }
}
