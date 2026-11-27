import Foundation

/// Day and time of day, in local time.
public struct LocalTime: Equatable, Sendable {
    /// `Calendar` numbering: 1 = Sunday ... 7 = Saturday.
    public var weekday: Int
    /// Minutes after midnight, 0..<1440.
    public var minute: Int

    public init(weekday: Int, minute: Int) {
        self.weekday = weekday
        self.minute = minute
    }

    public init(date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        self.init(weekday: parts.weekday ?? 1, minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}

/// A daily time range on chosen days. `end` earlier than `start` runs past midnight and belongs
/// to the day it starts on; `end` equal to `start` covers the whole day.
public struct TimeWindow: Codable, Equatable, Sendable {
    /// Minutes after midnight; the start is included, the end is not.
    public var start: Int
    public var end: Int
    /// Days the window starts on (1 = Sunday ... 7 = Saturday).
    public var days: Set<Int>

    public static let everyDay = Set(1...7)

    public init(start: Int, end: Int, days: Set<Int> = TimeWindow.everyDay) {
        self.start = start
        self.end = end
        self.days = days
    }

    public func contains(_ time: LocalTime) -> Bool {
        if start == end { return days.contains(time.weekday) }
        if start < end {
            return days.contains(time.weekday) && time.minute >= start && time.minute < end
        }
        if time.minute >= start { return days.contains(time.weekday) }
        let dayBefore = time.weekday == 1 ? 7 : time.weekday - 1
        return time.minute < end && days.contains(dayBefore)
    }
}

/// "When these conditions are true, do this when the lid closes" (spec D1). Every condition set
/// must be true; nil = does not matter. The first enabled rule that matches applies.
public struct Rule: Codable, Equatable, Sendable, Identifiable {
    public enum Power: String, Codable, Sendable, CaseIterable {
        case adapter
        case battery
    }

    public enum Display: String, Codable, Sendable, CaseIterable {
        case connected
        case notConnected
    }

    public enum Action: String, Codable, Sendable, CaseIterable {
        case sleep
        /// Stay awake with the lid closed, within the Safety guards.
        case stayAwake
        /// ClamStop does nothing.
        case macOS
    }

    public var id: UUID
    public var enabled: Bool
    public var power: Power?
    public var display: Display?
    public var time: TimeWindow?
    public var action: Action
    /// With `.sleep`: minutes asleep before hibernating (as in `ClamStopSettings`).
    public var hibernateDelayMinutes: Int

    public init(id: UUID = UUID(), enabled: Bool = true, power: Power? = nil, display: Display? = nil,
                time: TimeWindow? = nil, action: Action = .sleep,
                hibernateDelayMinutes: Int = ClamStopSettings.defaultDelayMinutes) {
        self.id = id
        self.enabled = enabled
        self.power = power
        self.display = display
        self.time = time
        self.action = action
        self.hibernateDelayMinutes = ClamStopSettings.clampDelay(hibernateDelayMinutes)
    }

    /// At least one condition, and at least one day when there is a time window.
    public var isValid: Bool {
        (power != nil || display != nil || time != nil) && time?.days.isEmpty != true
    }

    public func matches(_ context: PowerContext) -> Bool {
        guard enabled, isValid else { return false }
        if let power, (power == .adapter) != context.onPowerAdapter { return false }
        if let display, (display == .connected) != context.externalDisplay { return false }
        if let time {
            guard let now = context.time, time.contains(now) else { return false }
        }
        return true
    }
}

/// What the settings ask for when the lid closes, before the Safety guards and sessions.
public struct LidPlan: Codable, Equatable, Sendable {
    public var action: Rule.Action
    public var hibernateDelayMinutes: Int
    /// The rule that applies, nil for the General and battery settings.
    public var rule: Rule?

    /// Seconds before hibernating, nil when hibernation is off.
    public var hibernateDelay: TimeInterval? {
        hibernateDelayMinutes < 0 ? nil : TimeInterval(hibernateDelayMinutes * 60)
    }
}

public extension ClamStopSettings {
    /// The first matching rule, otherwise the behavior of the current power source. A rule that
    /// does not choose a hibernation delay (stay awake) keeps the power source's one.
    func lidPlan(for context: PowerContext) -> LidPlan {
        let profile = profile(onPowerAdapter: context.onPowerAdapter)
        guard let rule = rules.first(where: { $0.matches(context) }) else {
            return LidPlan(action: profile.enabled ? .sleep : .macOS,
                           hibernateDelayMinutes: profile.hibernateDelayMinutes)
        }
        return LidPlan(action: rule.action,
                       hibernateDelayMinutes: rule.action == .sleep ? rule.hibernateDelayMinutes
                           : profile.hibernateDelayMinutes,
                       rule: rule)
    }
}
