import Foundation

/// One event in the sleep log, recorded by the daemon.
public struct SleepEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case lidClosed
        case lidOpened
        case sleep
        case wake
        case hibernate
        case keptAwakeForAgents
        case agentsDone
    }

    public var date: Date
    public var kind: Kind
    public var batteryPercent: Int?
    public var onPowerAdapter: Bool?
    /// For a wake: whether the lid was open. For staying awake: a `KeepAwakeReason`, then a
    /// `KeepAwakeEnd`. Entries recorded by earlier versions may hold nothing or other text.
    public var detail: String?
    /// Why the Mac woke (a `WakeReason`).
    public var wakeReason: String?

    public init(date: Date, kind: Kind, batteryPercent: Int? = nil, onPowerAdapter: Bool? = nil, detail: String? = nil,
                wakeReason: String? = nil) {
        self.date = date
        self.kind = kind
        self.batteryPercent = batteryPercent
        self.onPowerAdapter = onPowerAdapter
        self.detail = detail
        self.wakeReason = wakeReason
    }
}

/// Why the Mac woke, from macOS's "Wake Reason" and "Wake Type" (seen on Apple silicon, such as
/// `lid IOPortFeatureLDCM.measurement` or `MTP.DOCK.CHANNELS.AP0.IRQ RTP.keyboard`).
public enum WakeReason: String, Sendable, CaseIterable {
    case lid
    case keyboard
    case trackpad
    case powerAdapter
    case network
    case scheduled
    case user
    case other

    public init(reason: String, type: String = "") {
        let words = Set(reason.split { $0 == " " || $0 == "/" }.map(String.init))
        if words.contains("lid") {
            self = .lid
        } else if reason.contains("keyboard") {
            self = .keyboard
        } else if reason.contains("multi-touch") || reason.contains("trackpad") {
            self = .trackpad
        } else if words.contains("acattach") || words.contains("acdetach") {
            self = .powerAdapter
        } else if words.contains("wifibt") || reason.contains("ARPT") {
            self = .network
        } else if words.contains("rtc") {
            self = .scheduled
        } else if [reason, type].contains(where: { $0.contains("UserActivity") || $0.contains("HID") }) {
            self = .user
        } else {
            self = .other
        }
    }
}

/// Why the Mac stays awake with the lid closed.
public enum KeepAwakeReason: String, Sendable, CaseIterable {
    case session
    case agents
    case apps
    case rule
}

/// Why it stopped. The guards carry the same names as in `Notice.Reason`.
public enum KeepAwakeEnd: String, Sendable, CaseIterable {
    /// The agents or apps finished.
    case finished
    case sessionEnded
    /// Settings, rules or conditions changed.
    case changed
    case maxDuration
    case heat
    case unplugged
    case batteryFloor
    case lowBattery
    case appQuit
    case appUnresponsive
}

/// One line of the journal.
public struct JournalEntry: Equatable, Sendable, Identifiable {
    /// Position in the log: two events can share a date.
    public var id: Int
    public var event: SleepEvent
    /// The sleep that this wake (or lid opening) ended.
    public var asleep: SleepSession?
}

public struct JournalDay: Equatable, Sendable, Identifiable {
    public var date: Date
    public var entries: [JournalEntry]

    public var id: Date { date }
}

/// A period asleep, from the first sleep to the next full wake, for the log view.
public struct SleepSession: Equatable, Sendable, Identifiable {
    public var start: Date
    public var end: Date?
    public var hibernated: Bool
    /// Battery percentage lost while asleep (nil if unknown or on power adapter at both ends).
    public var batteryUsed: Int?
    /// Wakes in between (dark wakes that were noticed, scheduled hibernation wake).
    public var wakes: Int

    public var id: Date { start }
}

public enum SleepLog {
    /// Events kept by the daemon: at most this many, and none older than `retention`.
    public static let capacity = 2000
    public static let retention: TimeInterval = 30 * 86_400
    /// `detail` of a wake event with the lid open: the end of a sleep session.
    public static let wakeLidOpen = "lid open"

    public static func appending(_ event: SleepEvent, to events: [SleepEvent]) -> [SleepEvent] {
        let oldest = event.date.addingTimeInterval(-retention)
        return Array((events.filter { $0.date >= oldest } + [event]).suffix(capacity))
    }

    /// A wake reported this soon after the lid opened is the same wake.
    static let sameWakeDelay: TimeInterval = 60

    /// The events by day, newest first, each sleep summed up on the line that ended it.
    public static func journal(from events: [SleepEvent], calendar: Calendar = .autoupdatingCurrent) -> [JournalDay] {
        var entries = events.enumerated().map { JournalEntry(id: $0.offset, event: $0.element, asleep: nil) }
        for session in sessions(from: events) {
            guard let end = session.end,
                  var index = events.firstIndex(where: { $0.date == end && ($0.kind == .wake || $0.kind == .lidOpened) })
            else { continue }
            // Prefer the wake that follows the lid opening: it says more.
            if events[index].kind == .lidOpened,
               let next = events[(index + 1)...].firstIndex(where: { $0.kind == .wake || $0.kind == .sleep }),
               events[next].kind == .wake, events[next].date.timeIntervalSince(end) < sameWakeDelay {
                index = next
            }
            entries[index].asleep = session
        }
        var days: [JournalDay] = []
        for entry in entries.reversed() {
            let day = calendar.startOfDay(for: entry.event.date)
            if days.last?.date == day {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(JournalDay(date: day, entries: [entry]))
            }
        }
        return days
    }

    /// Group events into sleep sessions, newest first. A session ends at a wake with the lid open
    /// (or the next lid opening); wakes before that count as intermediate wakes.
    public static func sessions(from events: [SleepEvent]) -> [SleepSession] {
        var result: [SleepSession] = []
        var current: SleepSession?
        var startBattery: Int?

        func close(at event: SleepEvent?) {
            guard var session = current else { return }
            session.end = event?.date
            if let start = startBattery, let end = event?.batteryPercent {
                session.batteryUsed = max(0, start - end)
            }
            // The closing wake is not an intermediate one.
            if event?.kind == .wake { session.wakes = max(0, session.wakes - 1) }
            result.append(session)
            current = nil
            startBattery = nil
        }

        for event in events {
            switch event.kind {
            case .sleep:
                if current == nil {
                    current = SleepSession(start: event.date, end: nil, hibernated: false, batteryUsed: nil, wakes: 0)
                    startBattery = event.batteryPercent
                }
            case .hibernate:
                current?.hibernated = true
            case .wake:
                current?.wakes += 1
                if event.detail == wakeLidOpen { close(at: event) }
            case .lidOpened:
                close(at: event)
            default:
                break
            }
        }
        if current != nil { result.append(current!) }
        return result.reversed()
    }
}
