// How the app behaves while it waits for the background service (approval in System Settings):
// it looks often at first, so that the switch turned on shows at once, reminds the user once if
// the switch stays off, then looks less often to spare the processor. It also says when a service
// that is switched on but silent must be registered again.

import Foundation

public struct ServiceWait: Sendable {
    /// Switch still off after this long: remind with the approval notification. Still off after
    /// as long again: look less often.
    public static let reminderDelay: TimeInterval = 5 * 60
    /// Seconds between two looks while the service is expected soon.
    public static let eagerInterval: TimeInterval = 1
    /// Seconds between two looks otherwise (service running, or a long wait).
    public static let relaxedInterval: TimeInterval = 5

    /// A switch off at least this long, then on: the user just approved the service. Shorter:
    /// macOS says "on" for a moment while a registration settles.
    public static let approvalTime: TimeInterval = 10
    /// Silence after an approval before registering again (a healthy service answers at once).
    public static let patienceAfterApproval: TimeInterval = 5
    /// Silence otherwise, and how many times to register again then.
    public static let patience: TimeInterval = 20
    public static let unattendedRepairs = 2
    /// After a registration, macOS moves the switch by itself for a while: not an approval.
    public static let settlingTime: TimeInterval = 30

    private var offSince: Date?
    private var onSince: Date?
    private var approved = false
    private var lastRepair = Date.distantPast
    private var repairs = 0

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

    /// macOS says the switch is off (approval needed).
    public mutating func switchIsOff(now: Date) {
        if offSince == nil { offSince = now }
        onSince = nil
        approved = false
    }

    /// macOS says the switch is on; the service may not answer yet.
    public mutating func switchIsOn(now: Date) {
        if let offSince {
            approved = now.timeIntervalSince(offSince) >= Self.approvalTime
                && now.timeIntervalSince(lastRepair) >= Self.settlingTime
            self.offSince = nil
        }
        if onSince == nil { onSince = now }
    }

    /// The switch is on and the service did not answer. With ad-hoc builds launchd sometimes
    /// refuses a new service until it is registered again (seen on macOS 27.2): true when that
    /// should be done now. Once per approval, a few times otherwise.
    public mutating func repairIsDue(now: Date) -> Bool {
        guard let onSince else { return false }
        let silent = now.timeIntervalSince(onSince)
        if approved, silent >= Self.patienceAfterApproval {
            approved = false
        } else if !approved, repairs < Self.unattendedRepairs, silent >= Self.patience {
            repairs += 1
        } else {
            return false
        }
        lastRepair = now
        self.onSince = nil
        return true
    }

    /// True once per wait, when the switch has been off for `reminderDelay`.
    public mutating func reminderIsDue(switchOff: Bool, now: Date) -> Bool {
        guard switchOff, !reminded, let since, now.timeIntervalSince(since) >= Self.reminderDelay else { return false }
        reminded = true
        return true
    }
}
