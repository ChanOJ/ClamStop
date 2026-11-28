// "Sleep report" (spec B5): after a long sleep, how long it lasted and what it cost the battery,
// from the sleep journal. Pure logic and words: the app posts the notification.

import ClamStopShared
import Foundation

public struct SleepReport: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var batteryBefore: Int?
    public var batteryAfter: Int?
    /// On power adapter when the Mac went to sleep and when it woke.
    public var onPowerAdapter: Bool
    public var hibernated: Bool

    /// Shorter sleeps are not reported.
    public static let minimumSleep: TimeInterval = 4 * 3600
    /// A wake older than this is not news any more.
    public static let maximumAge: TimeInterval = 3600

    public init(start: Date, end: Date, batteryBefore: Int?, batteryAfter: Int?, onPowerAdapter: Bool,
                hibernated: Bool) {
        self.start = start
        self.end = end
        self.batteryBefore = batteryBefore
        self.batteryAfter = batteryAfter
        self.onPowerAdapter = onPowerAdapter
        self.hibernated = hibernated
    }

    /// The newest long sleep that ended recently and after `lastReported` (the end of the sleep
    /// reported last).
    public static func latest(events: [SleepEvent], now: Date, lastReported: Date?,
                              minimumSleep: TimeInterval = Self.minimumSleep) -> SleepReport? {
        for session in SleepLog.sessions(from: events) {
            guard let end = session.end, end.timeIntervalSince(session.start) >= minimumSleep,
                  now.timeIntervalSince(end) < maximumAge else { continue }
            // The journal keeps whole seconds.
            if let lastReported, end.timeIntervalSince(lastReported) < 1 { return nil }
            let asleep = events.first { $0.date == session.start && $0.kind == .sleep }
            let awake = events.first { $0.date == end && ($0.kind == .wake || $0.kind == .lidOpened) }
            return SleepReport(start: session.start, end: end, batteryBefore: asleep?.batteryPercent,
                               batteryAfter: awake?.batteryPercent,
                               onPowerAdapter: asleep?.onPowerAdapter == true && awake?.onPowerAdapter == true,
                               hibernated: session.hibernated)
        }
        return nil
    }

    public static var title: String { String(localized: "While your Mac slept") }

    /// "8 h 19 min asleep · battery 80 % → 78 % (−2 %) · hibernated".
    public var body: String {
        let minutes = Int(end.timeIntervalSince(start) / 60)
        let duration = minutes < 60 ? String(localized: "\(minutes) min")
            : minutes % 60 == 0 ? String(localized: "\(minutes / 60) h")
            : String(localized: "\(minutes / 60) h \(minutes % 60) min")
        var parts = [String(localized: "\(duration) asleep")]
        if onPowerAdapter {
            parts.append(batteryAfter.map { String(localized: "on power adapter, battery \($0) %") }
                ?? String(localized: "on power adapter"))
        } else if let before = batteryBefore, let after = batteryAfter {
            // No difference to name when the battery charged meanwhile.
            parts.append(after < before ? String(localized: "battery \(before) % → \(after) % (−\(before - after) %)")
                : String(localized: "battery \(before) % → \(after) %"))
        }
        if hibernated { parts.append(String(localized: "hibernated")) }
        return parts.joined(separator: " · ")
    }
}
