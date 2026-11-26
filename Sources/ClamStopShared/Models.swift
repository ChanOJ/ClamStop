import Foundation

/// Sleep behavior for one power source (Pro: separate settings on battery and on power adapter).
public struct PowerSourceProfile: Codable, Equatable, Sendable {
    /// Sleep when the lid closes on this power source.
    public var enabled: Bool
    /// Minutes of sleep before hibernating: 0 = immediately, `ClamStopSettings.never` = never.
    public var hibernateDelayMinutes: Int

    public init(enabled: Bool = true, hibernateDelayMinutes: Int = ClamStopSettings.defaultDelayMinutes) {
        self.enabled = enabled
        self.hibernateDelayMinutes = ClamStopSettings.clampDelay(hibernateDelayMinutes)
    }

    /// Seconds before hibernating, nil when hibernation is off.
    public var hibernateDelay: TimeInterval? {
        hibernateDelayMinutes < 0 ? nil : TimeInterval(hibernateDelayMinutes * 60)
    }
}

/// "Do not force sleep between these times" (Pro).
public struct TimeRangeException: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Minutes after midnight. A range that ends before it starts spans midnight.
    public var startMinutes: Int
    public var endMinutes: Int
    /// Monday to Friday only.
    public var weekdaysOnly: Bool
    /// Only while the power adapter is connected.
    public var onPowerAdapterOnly: Bool

    public init(enabled: Bool = false, startMinutes: Int = 9 * 60, endMinutes: Int = 18 * 60,
                weekdaysOnly: Bool = true, onPowerAdapterOnly: Bool = true) {
        self.enabled = enabled
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.weekdaysOnly = weekdaysOnly
        self.onPowerAdapterOnly = onPowerAdapterOnly
    }

    public func applies(at date: Date, onPowerAdapter: Bool, calendar: Calendar = .current) -> Bool {
        guard enabled, !onPowerAdapterOnly || onPowerAdapter else { return false }
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let inRange: Bool
        // For a range over midnight, the part after midnight belongs to the previous day.
        var day = parts.weekday ?? 2
        if startMinutes <= endMinutes {
            inRange = minutes >= startMinutes && minutes < endMinutes
        } else {
            inRange = minutes >= startMinutes || minutes < endMinutes
            if minutes < endMinutes { day = day == 1 ? 7 : day - 1 }
        }
        guard inRange else { return false }
        // Calendar weekday: 1 = Sunday, 7 = Saturday.
        return !weekdaysOnly || (2...6).contains(day)
    }
}

/// User settings, owned and persisted by the daemon. Fields added after 0.1 decode with their
/// default when missing, so older settings files keep working.
public struct ClamStopSettings: Codable, Equatable, Sendable {
    /// Sleep when the lid closes, even in clamshell mode (master switch).
    public var enabled: Bool
    /// Minutes of sleep before hibernating: 0 = immediately, `never` (-1) = never hibernate.
    /// With separate battery settings, this is the power adapter delay.
    public var hibernateDelayMinutes: Int

    // Pro
    /// Stay awake with the lid closed while an AI coding agent works.
    public var keepAwakeForAgents: Bool
    /// Safety limit for staying awake for agents with the lid closed, in hours (0 = no limit).
    public var agentMaxHours: Int
    /// Use `onPowerAdapterEnabled` / `battery` instead of the same behavior on both sources.
    public var separateBatterySettings: Bool
    /// With separate settings: sleep when the lid closes on power adapter.
    public var onPowerAdapterEnabled: Bool
    /// With separate settings: behavior on battery.
    public var battery: PowerSourceProfile
    /// Hibernate at once when the lid closes (or while awake for agents) below `lowBatteryPercent`.
    public var lowBatteryHibernation: Bool
    public var lowBatteryPercent: Int
    public var timeRange: TimeRangeException
    /// Names of external displays that, when connected, stop ClamStop from forcing sleep.
    public var displayExceptions: [String]

    public static let defaultDelayMinutes = 60
    /// Free edition: hibernate after 1 h or never.
    public static let freeDelayChoices = [60, never]
    public static let maxDelayMinutes = 24 * 60
    public static let never = -1
    public static let agentMaxHourChoices = [1, 2, 4, 8, 12, 0]

    /// Seconds before hibernating, nil when hibernation is off.
    public var hibernateDelay: TimeInterval? {
        hibernateDelayMinutes < 0 ? nil : TimeInterval(hibernateDelayMinutes * 60)
    }

    public init(enabled: Bool = true, hibernateDelayMinutes: Int = ClamStopSettings.defaultDelayMinutes,
                keepAwakeForAgents: Bool = true, agentMaxHours: Int = 8,
                separateBatterySettings: Bool = false, onPowerAdapterEnabled: Bool = true,
                battery: PowerSourceProfile = PowerSourceProfile(),
                lowBatteryHibernation: Bool = false, lowBatteryPercent: Int = 10,
                timeRange: TimeRangeException = TimeRangeException(), displayExceptions: [String] = []) {
        self.enabled = enabled
        self.hibernateDelayMinutes = ClamStopSettings.clampDelay(hibernateDelayMinutes)
        self.keepAwakeForAgents = keepAwakeForAgents
        self.agentMaxHours = max(0, agentMaxHours)
        self.separateBatterySettings = separateBatterySettings
        self.onPowerAdapterEnabled = onPowerAdapterEnabled
        self.battery = battery
        self.lowBatteryHibernation = lowBatteryHibernation
        self.lowBatteryPercent = ClamStopSettings.clampPercent(lowBatteryPercent)
        self.timeRange = timeRange
        self.displayExceptions = displayExceptions
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, hibernateDelayMinutes, keepAwakeForAgents, agentMaxHours, separateBatterySettings,
             onPowerAdapterEnabled, battery, lowBatteryHibernation, lowBatteryPercent, timeRange,
             displayExceptions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClamStopSettings()
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            hibernateDelayMinutes: try c.decodeIfPresent(Int.self, forKey: .hibernateDelayMinutes) ?? d.hibernateDelayMinutes,
            keepAwakeForAgents: try c.decodeIfPresent(Bool.self, forKey: .keepAwakeForAgents) ?? d.keepAwakeForAgents,
            agentMaxHours: try c.decodeIfPresent(Int.self, forKey: .agentMaxHours) ?? d.agentMaxHours,
            separateBatterySettings: try c.decodeIfPresent(Bool.self, forKey: .separateBatterySettings) ?? d.separateBatterySettings,
            onPowerAdapterEnabled: try c.decodeIfPresent(Bool.self, forKey: .onPowerAdapterEnabled) ?? d.onPowerAdapterEnabled,
            battery: try c.decodeIfPresent(PowerSourceProfile.self, forKey: .battery) ?? d.battery,
            lowBatteryHibernation: try c.decodeIfPresent(Bool.self, forKey: .lowBatteryHibernation) ?? d.lowBatteryHibernation,
            lowBatteryPercent: try c.decodeIfPresent(Int.self, forKey: .lowBatteryPercent) ?? d.lowBatteryPercent,
            timeRange: try c.decodeIfPresent(TimeRangeException.self, forKey: .timeRange) ?? d.timeRange,
            displayExceptions: try c.decodeIfPresent([String].self, forKey: .displayExceptions) ?? d.displayExceptions)
    }

    public static func clampDelay(_ minutes: Int) -> Int {
        min(max(minutes, never), maxDelayMinutes)
    }

    public static func clampPercent(_ percent: Int) -> Int {
        min(max(percent, 5), 50)
    }

    /// Behavior on the given power source.
    public func profile(onPowerAdapter: Bool) -> PowerSourceProfile {
        guard separateBatterySettings else {
            return PowerSourceProfile(enabled: true, hibernateDelayMinutes: hibernateDelayMinutes)
        }
        return onPowerAdapter
            ? PowerSourceProfile(enabled: onPowerAdapterEnabled, hibernateDelayMinutes: hibernateDelayMinutes)
            : battery
    }

    /// These settings with every locked Pro feature turned off (free: hibernate after 1 h or never).
    /// The daemon takes its decisions on this value only.
    public func effective(isUnlocked: (ProFeature) -> Bool = Entitlement.isUnlocked) -> ClamStopSettings {
        var s = self
        if !isUnlocked(.hibernationDelays) {
            let free = { (m: Int) in m == Self.never ? Self.never : Self.defaultDelayMinutes }
            s.hibernateDelayMinutes = free(s.hibernateDelayMinutes)
            s.battery.hibernateDelayMinutes = free(s.battery.hibernateDelayMinutes)
        }
        if !isUnlocked(.agentKeepAwake) { s.keepAwakeForAgents = false }
        if !isUnlocked(.powerSourceSettings) { s.separateBatterySettings = false }
        if !isUnlocked(.lowBatteryHibernation) { s.lowBatteryHibernation = false }
        if !isUnlocked(.schedules) {
            s.timeRange.enabled = false
            s.displayExceptions = []
        }
        return s
    }
}

/// Where the daemon stands in the sleep / delayed hibernation cycle.
public enum PowerPhase: String, Codable, Sendable {
    /// Awake, or asleep without a pending hibernation.
    case idle
    /// Asleep with the lid closed; a wake is scheduled to hibernate.
    case awaitingHibernation
    /// `hibernatemode 25` is set and the Mac is going (or went) into hibernation.
    case hibernating
}

/// State persisted by the daemon so that a restart can clean up after itself.
public struct PersistedState: Codable, Equatable, Sendable {
    public var phase: PowerPhase
    /// Wake scheduled by the daemon with `IOPMSchedulePowerEvent`, if any.
    public var pendingWake: Date?
    /// `hibernatemode` value before the daemon changed it; nil when unchanged.
    public var savedHibernateMode: Int?
    /// ClamStop set `pmset disablesleep 1` to stay awake for agents (nil in files from 0.1).
    public var sleepDisabledByClamStop: Bool?

    public init(phase: PowerPhase = .idle, pendingWake: Date? = nil, savedHibernateMode: Int? = nil,
                sleepDisabledByClamStop: Bool? = nil) {
        self.phase = phase
        self.pendingWake = pendingWake
        self.savedHibernateMode = savedHibernateMode
        self.sleepDisabledByClamStop = sleepDisabledByClamStop
    }
}

/// Snapshot sent to the app over XPC.
public struct DaemonStatus: Codable, Equatable, Sendable {
    public var version: String
    public var settings: ClamStopSettings
    public var phase: PowerPhase
    public var pendingWake: Date?
    public var lidClosed: Bool
    /// `pmset disablesleep 1` (or similar) prevents any sleep.
    public var sleepDisabled: Bool
    public var hibernateMode: Int?
    // Added with the Pro features; optional so that an older daemon's reply still decodes.
    /// `sleepDisabled` was set by ClamStop itself, to stay awake for agents.
    public var sleepDisabledByClamStop: Bool?
    /// The daemon's copy of `Entitlement.isProUnlocked` (sent by the app).
    public var proUnlocked: Bool?
    /// AI agent sessions currently counted as working.
    public var agents: [AgentSessionInfo]?
    /// The lid is closed and the Mac stays awake because agents are working.
    public var keepingAwakeForAgents: Bool?
    public var onPowerAdapter: Bool?
    public var batteryPercent: Int?
    /// External displays currently connected (names as macOS reports them).
    public var connectedDisplays: [String]?
    /// Why ClamStop did or did not force sleep the last time the lid closed.
    public var lastLidDecision: String?

    public init(version: String, settings: ClamStopSettings, phase: PowerPhase, pendingWake: Date?,
                lidClosed: Bool, sleepDisabled: Bool, hibernateMode: Int?,
                sleepDisabledByClamStop: Bool? = nil, proUnlocked: Bool? = nil, agents: [AgentSessionInfo]? = nil,
                keepingAwakeForAgents: Bool? = nil, onPowerAdapter: Bool? = nil, batteryPercent: Int? = nil,
                connectedDisplays: [String]? = nil, lastLidDecision: String? = nil) {
        self.version = version
        self.settings = settings
        self.phase = phase
        self.pendingWake = pendingWake
        self.lidClosed = lidClosed
        self.sleepDisabled = sleepDisabled
        self.hibernateMode = hibernateMode
        self.sleepDisabledByClamStop = sleepDisabledByClamStop
        self.proUnlocked = proUnlocked
        self.agents = agents
        self.keepingAwakeForAgents = keepingAwakeForAgents
        self.onPowerAdapter = onPowerAdapter
        self.batteryPercent = batteryPercent
        self.connectedDisplays = connectedDisplays
        self.lastLidDecision = lastLidDecision
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> DaemonStatus? {
        try? JSONDecoder().decode(DaemonStatus.self, from: data)
    }
}

public enum ClamStopVersion {
    public static let current = "0.1.0"
}

/// macOS `hibernatemode` values used by ClamStop.
public enum HibernateMode {
    /// Default on portables: sleep to RAM, write a hibernation image as a backup.
    public static let `default` = 3
    /// Write the image and power off memory: real hibernation.
    public static let hibernate = 25
}
