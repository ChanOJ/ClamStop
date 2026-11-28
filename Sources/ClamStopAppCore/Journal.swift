import ClamStopShared
import Foundation

// The sleep journal window's view of the daemon's events (spec H3).

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

extension SleepLog {
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
