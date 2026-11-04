import OSLog

/// Single subsystem for every diagnostic:
/// `log stream --predicate 'subsystem == "app.meetingscribe"' --level debug`
enum Log {
    static let subsystem = "app.meetingscribe"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let notes = Logger(subsystem: subsystem, category: "notes")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
