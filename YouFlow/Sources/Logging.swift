import OSLog

/// Centralized OSLog handles, one per subsystem category.
/// Never log dictated transcript content through these handles.
enum Log {
    private static let subsystem = "com.youflow.dictation"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let permissions = Logger(subsystem: subsystem, category: "Permissions")
    static let hotkey = Logger(subsystem: subsystem, category: "Hotkey")
    static let speech = Logger(subsystem: subsystem, category: "Speech")
    static let clipboard = Logger(subsystem: subsystem, category: "Clipboard")
    static let hud = Logger(subsystem: subsystem, category: "HUD")
}
