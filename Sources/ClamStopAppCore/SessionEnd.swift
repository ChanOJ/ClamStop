// The end of a "Stay awake" session (spec C4): when to remind, and until when "+30 min" goes.
// App only, so that the daemon stays as it is.

import ClamStopShared
import Foundation

public enum SessionEnd {
    /// The reminder comes this long before the end.
    public static let reminderLead: TimeInterval = 5 * 60
    /// Sessions this long or shorter get no reminder: it would come soon after they start.
    public static let shortSession: TimeInterval = 10 * 60
    /// What "+30 min" adds.
    public static let extensionTime: TimeInterval = 30 * 60

    /// Whether to remind now. `reminded`: the end already reminded of.
    public static func reminderIsDue(_ session: StayAwakeSession, now: Date, reminded: Date?) -> Bool {
        guard let until = session.until, until.timeIntervalSince(session.started) > shortSession + 1,
              reminded.map({ abs($0.timeIntervalSince(until)) >= 1 }) ?? true else { return false }
        return now >= until - reminderLead && now < until
    }

    /// The end after "+30 min": from the session's end, or from now when it is over. nil for a
    /// session without an end.
    public static func extended(_ session: StayAwakeSession?, now: Date) -> Date? {
        guard let session else { return now + extensionTime }
        return session.until.map { max($0, now) + extensionTime }
    }
}
