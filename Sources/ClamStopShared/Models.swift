import Foundation

/// Sleep behavior for one power source (separate settings on battery and on power adapter).
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

/// User settings, owned and persisted by the daemon. Fields added after 0.1 decode with their
/// default when missing, so older settings files keep working.
public struct ClamStopSettings: Codable, Equatable, Sendable {
    /// Sleep when the lid closes, even in clamshell mode (master switch).
    public var enabled: Bool
    /// Minutes of sleep before hibernating: 0 = immediately, `never` (-1) = never hibernate.
    /// With separate battery settings, this is the power adapter delay.
    public var hibernateDelayMinutes: Int

    /// Stay awake with the lid closed while an AI coding agent works.
    public var keepAwakeForAgents: Bool
    /// Use `onPowerAdapterEnabled` / `battery` instead of the same behavior on both sources.
    public var separateBatterySettings: Bool
    /// With separate settings: sleep when the lid closes on power adapter.
    public var onPowerAdapterEnabled: Bool
    /// With separate settings: behavior on battery.
    public var battery: PowerSourceProfile
    /// Hibernate at once when the lid closes (or while awake for agents) below `lowBatteryPercent`.
    public var lowBatteryHibernation: Bool
    public var lowBatteryPercent: Int

    // Safety guards (spec E1, E2, E3, E5): they end staying awake with the lid closed.
    /// On battery, sleep below this level (spec E1, default 20 %, minimum 5 %).
    public var batteryFloorPercent: Int
    /// Sleep when the Mac gets hot (spec E2).
    public var heatGuard: Bool
    /// Stay awake with the lid closed only on power adapter (spec E3).
    public var onlyWhileCharging: Bool
    /// Longest time to stay awake with the lid closed, in hours (0 = no limit, spec E5).
    public var maxAwakeHours: Int
    /// "When conditions are true, do this" (spec D1), in order of priority.
    public var rules: [Rule]

    public static let defaultDelayMinutes = 60
    public static let delayChoices = [0, 5, 15, 30, 60, 120, 240, never]
    public static let maxDelayMinutes = 24 * 60
    public static let never = -1
    public static let maxAwakeHourChoices = [0, 1, 2, 4, 8, 12]
    public static let batteryFloorChoices = [5, 10, 20, 30, 50]

    /// Seconds before hibernating, nil when hibernation is off.
    public var hibernateDelay: TimeInterval? {
        hibernateDelayMinutes < 0 ? nil : TimeInterval(hibernateDelayMinutes * 60)
    }

    public init(enabled: Bool = true, hibernateDelayMinutes: Int = ClamStopSettings.defaultDelayMinutes,
                keepAwakeForAgents: Bool = true,
                separateBatterySettings: Bool = false, onPowerAdapterEnabled: Bool = true,
                battery: PowerSourceProfile = PowerSourceProfile(),
                lowBatteryHibernation: Bool = false, lowBatteryPercent: Int = 10,
                batteryFloorPercent: Int = 20, heatGuard: Bool = true, onlyWhileCharging: Bool = true,
                maxAwakeHours: Int = 0, rules: [Rule] = []) {
        self.enabled = enabled
        self.hibernateDelayMinutes = ClamStopSettings.clampDelay(hibernateDelayMinutes)
        self.keepAwakeForAgents = keepAwakeForAgents
        self.separateBatterySettings = separateBatterySettings
        self.onPowerAdapterEnabled = onPowerAdapterEnabled
        self.battery = battery
        self.lowBatteryHibernation = lowBatteryHibernation
        self.lowBatteryPercent = ClamStopSettings.clampPercent(lowBatteryPercent)
        self.batteryFloorPercent = ClamStopSettings.clampPercent(batteryFloorPercent)
        self.heatGuard = heatGuard
        self.onlyWhileCharging = onlyWhileCharging
        self.maxAwakeHours = max(0, maxAwakeHours)
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, hibernateDelayMinutes, keepAwakeForAgents, separateBatterySettings,
             onPowerAdapterEnabled, battery, lowBatteryHibernation, lowBatteryPercent,
             batteryFloorPercent, heatGuard, onlyWhileCharging, maxAwakeHours, rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClamStopSettings()
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            hibernateDelayMinutes: try c.decodeIfPresent(Int.self, forKey: .hibernateDelayMinutes) ?? d.hibernateDelayMinutes,
            keepAwakeForAgents: try c.decodeIfPresent(Bool.self, forKey: .keepAwakeForAgents) ?? d.keepAwakeForAgents,
            separateBatterySettings: try c.decodeIfPresent(Bool.self, forKey: .separateBatterySettings) ?? d.separateBatterySettings,
            onPowerAdapterEnabled: try c.decodeIfPresent(Bool.self, forKey: .onPowerAdapterEnabled) ?? d.onPowerAdapterEnabled,
            battery: try c.decodeIfPresent(PowerSourceProfile.self, forKey: .battery) ?? d.battery,
            lowBatteryHibernation: try c.decodeIfPresent(Bool.self, forKey: .lowBatteryHibernation) ?? d.lowBatteryHibernation,
            lowBatteryPercent: try c.decodeIfPresent(Int.self, forKey: .lowBatteryPercent) ?? d.lowBatteryPercent,
            batteryFloorPercent: try c.decodeIfPresent(Int.self, forKey: .batteryFloorPercent) ?? d.batteryFloorPercent,
            heatGuard: try c.decodeIfPresent(Bool.self, forKey: .heatGuard) ?? d.heatGuard,
            onlyWhileCharging: try c.decodeIfPresent(Bool.self, forKey: .onlyWhileCharging) ?? d.onlyWhileCharging,
            maxAwakeHours: try c.decodeIfPresent(Int.self, forKey: .maxAwakeHours) ?? d.maxAwakeHours,
            rules: try c.decodeIfPresent([Rule].self, forKey: .rules) ?? d.rules)
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

/// A "Stay awake" session started from the menu (spec C1).
public struct StayAwakeSession: Codable, Equatable, Sendable {
    public var started: Date
    /// nil = until turned off.
    public var until: Date?

    public init(started: Date, until: Date?) {
        self.started = started
        self.until = until
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
    // Added after 0.1; optional so that an older daemon's reply still decodes.
    /// `sleepDisabled` was set by ClamStop itself, to stay awake for agents.
    public var sleepDisabledByClamStop: Bool?
    /// AI agent sessions currently counted as working.
    public var agents: [AgentSessionInfo]?
    /// The lid is closed and the Mac stays awake (agents, session or rule).
    public var keepingAwakeForAgents: Bool?
    public var onPowerAdapter: Bool?
    public var batteryPercent: Int?
    /// Why ClamStop did or did not force sleep the last time the lid closed.
    public var lastLidDecision: String?
    /// The "Stay awake" session, if one runs.
    public var session: StayAwakeSession?
    /// Recent notices, oldest first (spec H5).
    public var notices: [Notice]?
    /// The daemon sees the app running (it is inactive otherwise).
    public var appRunning: Bool?
    /// What closing the lid does now, sessions and agents aside, with the rule that applies
    /// (spec D1). nil while ClamStop is off or inactive.
    public var lidPlan: LidPlan?

    public init(version: String, settings: ClamStopSettings, phase: PowerPhase, pendingWake: Date?,
                lidClosed: Bool, sleepDisabled: Bool, hibernateMode: Int?,
                sleepDisabledByClamStop: Bool? = nil, agents: [AgentSessionInfo]? = nil,
                keepingAwakeForAgents: Bool? = nil, onPowerAdapter: Bool? = nil, batteryPercent: Int? = nil,
                lastLidDecision: String? = nil, appRunning: Bool? = nil, session: StayAwakeSession? = nil,
                notices: [Notice]? = nil, lidPlan: LidPlan? = nil) {
        self.version = version
        self.settings = settings
        self.phase = phase
        self.pendingWake = pendingWake
        self.lidClosed = lidClosed
        self.sleepDisabled = sleepDisabled
        self.hibernateMode = hibernateMode
        self.sleepDisabledByClamStop = sleepDisabledByClamStop
        self.agents = agents
        self.keepingAwakeForAgents = keepingAwakeForAgents
        self.onPowerAdapter = onPowerAdapter
        self.batteryPercent = batteryPercent
        self.lastLidDecision = lastLidDecision
        self.session = session
        self.notices = notices
        self.appRunning = appRunning
        self.lidPlan = lidPlan
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
