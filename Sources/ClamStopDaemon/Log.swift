import Foundation
import os
import ClamStopShared

/// Unified logging (`log stream --predicate 'subsystem == "io.github.chanoj.clamstop"'`),
/// mirrored to stdout when running in the foreground.
enum Log {
    static let logger = Logger(subsystem: ClamStopID.appBundleID, category: "daemon")
    static var mirrorToStdout = false

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        mirror(message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        mirror("ERROR " + message)
    }

    private static func mirror(_ message: String) {
        guard mirrorToStdout else { return }
        print("\(formatter.string(from: Date())) \(message)")
        fflush(stdout)
    }
}
