// How the app behaves while it waits for the background service (approval in System Settings):
// it looks often at first, so that the switch turned on shows at once, reminds the user once if
// the switch stays off, then looks less often to spare the processor.

import Foundation

public struct ServiceWait: Sendable {
    /// Switch still off after this long: remind with the approval notification. Still off after
    /// as long again: look less often.
    public static let reminderDelay: TimeInterval = 5 * 60
    /// Seconds between two looks while the service is expected soon.
    public static let eagerInterval: TimeInterval = 1
    /// Seconds between two looks otherwise (service running, or a long wait).
    public static let relaxedInterval: TimeInterval = 5

    private var since: Date?
    private var eagerUntil = Date.distantPast
    private var reminded = false

    public init() {}

    /// The service is not answering (true) or answers, or is not expected (false: starts over).
    public mutating func update(waiting: Bool, now: Date) {
        guard waiting else {
            self = ServiceWait()
            return
        }
        guard since == nil else { return }
        since = now
        eagerUntil = max(eagerUntil, now.addingTimeInterval(2 * Self.reminderDelay))
    }

    /// The user went to turn the switch on: look often again for a while.
    public mutating func userIsActing(now: Date) {
        eagerUntil = max(eagerUntil, now.addingTimeInterval(Self.reminderDelay))
    }

    public func interval(now: Date) -> TimeInterval {
        since != nil && now < eagerUntil ? Self.eagerInterval : Self.relaxedInterval
    }

    /// True once per wait, when the switch has been off for `reminderDelay`.
    public mutating func reminderIsDue(switchOff: Bool, now: Date) -> Bool {
        guard switchOff, !reminded, let since, now.timeIntervalSince(since) >= Self.reminderDelay else { return false }
        reminded = true
        return true
    }
}
