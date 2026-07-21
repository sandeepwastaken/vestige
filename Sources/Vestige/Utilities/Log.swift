import OSLog

/// Centralised loggers, one per subsystem, so that `log stream --predicate
/// 'subsystem == "app.vestige.Vestige"'` gives a coherent trace of a session.
///
/// Vestige never sends diagnostics anywhere. These logs stay on the machine and
/// are only visible to the user through Console.app.
enum Log {
    private static let subsystem = "app.vestige.Vestige"

    static let capture = Logger(subsystem: subsystem, category: "Capture")
    static let encoder = Logger(subsystem: subsystem, category: "Encoder")
    static let buffer = Logger(subsystem: subsystem, category: "ReplayBuffer")
    static let storage = Logger(subsystem: subsystem, category: "Storage")
    static let hotkeys = Logger(subsystem: subsystem, category: "Hotkeys")
    static let permissions = Logger(subsystem: subsystem, category: "Permissions")
    static let games = Logger(subsystem: subsystem, category: "GameDetection")
    static let app = Logger(subsystem: subsystem, category: "App")
}
