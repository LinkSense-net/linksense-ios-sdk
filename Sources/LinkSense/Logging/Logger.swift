import Foundation
import os.log

/// Internal logger. Off in production unless the integrator explicitly
/// turns on `.debug`/`.info`. Uses Apple's `os_log` so messages are
/// properly classified (public/private) in Console.app.
enum Logger {
    private static let osLog = OSLog(subsystem: "com.linksense.sdk", category: "LinkSense")
    private static var level: LogLevel = .off

    static func configure(level: LogLevel) {
        self.level = level
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard level.rawValue >= LogLevel.debug.rawValue else { return }
        os_log("%{public}@", log: osLog, type: .debug, message())
    }

    static func info(_ message: @autoclosure () -> String) {
        guard level.rawValue >= LogLevel.info.rawValue else { return }
        os_log("%{public}@", log: osLog, type: .info, message())
    }

    static func warn(_ message: @autoclosure () -> String) {
        guard level.rawValue >= LogLevel.error.rawValue else { return }
        os_log("%{public}@", log: osLog, type: .default, message())
    }

    static func error(_ message: @autoclosure () -> String) {
        guard level.rawValue >= LogLevel.error.rawValue else { return }
        os_log("%{public}@", log: osLog, type: .error, message())
    }
}
