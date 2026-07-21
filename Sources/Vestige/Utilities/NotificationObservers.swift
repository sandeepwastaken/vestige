import Foundation

/// Holds `NotificationCenter` observer tokens and removes them on deallocation.
///
/// Two problems this solves. First, forgetting to unregister an observer leaves
/// a dangling closure that fires against a half-torn-down object. Second,
/// Swift 6 will not let a `deinit` touch main-actor state, so an actor-isolated
/// type cannot clean up its own tokens — but it can own one of these.
///
/// Callbacks are delivered on the main queue and take no payload, which keeps
/// the non-`Sendable` `Notification` type from crossing a concurrency boundary.
final class NotificationObservers: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    private let center: NotificationCenter

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    func observe(_ name: Notification.Name, object: Any? = nil, perform action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated(action)
        }
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
    }
}
