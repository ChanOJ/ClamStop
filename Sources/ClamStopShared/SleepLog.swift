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
        /// The thermal level changed while the Mac stayed awake with the lid closed.
        case thermalChanged
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
    /// How warm the Mac was (a `ThermalLevel`). nil in entries recorded by earlier versions.
    public var thermal: String?

    public init(date: Date, kind: Kind, batteryPercent: Int? = nil, onPowerAdapter: Bool? = nil, detail: String? = nil,
                wakeReason: String? = nil, thermal: String? = nil) {
        self.date = date
        self.kind = kind
        self.batteryPercent = batteryPercent
        self.onPowerAdapter = onPowerAdapter
        self.detail = detail
        self.wakeReason = wakeReason
        self.thermal = thermal
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
}
