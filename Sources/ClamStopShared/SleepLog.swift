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
    public var detail: String?

    public init(date: Date, kind: Kind, batteryPercent: Int? = nil, onPowerAdapter: Bool? = nil, detail: String? = nil) {
        self.date = date
        self.kind = kind
        self.batteryPercent = batteryPercent
        self.onPowerAdapter = onPowerAdapter
        self.detail = detail
    }
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
    /// Events kept by the daemon.
    public static let capacity = 500
    /// `detail` of a wake event with the lid open: the end of a sleep session.
    public static let wakeLidOpen = "lid open"

    public static func appending(_ event: SleepEvent, to events: [SleepEvent]) -> [SleepEvent] {
        Array((events + [event]).suffix(capacity))
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
