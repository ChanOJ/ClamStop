import Foundation

/// User settings, owned and persisted by the daemon.
public struct ClamStopSettings: Codable, Equatable, Sendable {
    /// Sleep when the lid closes, even in clamshell mode.
    public var enabled: Bool
    /// Minutes of sleep before hibernating; 0 = never hibernate.
    public var hibernateDelayMinutes: Int

    public static let defaultDelayMinutes = 10
    public static let maxDelayMinutes = 24 * 60

    public init(enabled: Bool = true, hibernateDelayMinutes: Int = ClamStopSettings.defaultDelayMinutes) {
        self.enabled = enabled
        self.hibernateDelayMinutes = ClamStopSettings.clampDelay(hibernateDelayMinutes)
    }

    public static func clampDelay(_ minutes: Int) -> Int {
        min(max(minutes, 0), maxDelayMinutes)
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

    public init(phase: PowerPhase = .idle, pendingWake: Date? = nil, savedHibernateMode: Int? = nil) {
        self.phase = phase
        self.pendingWake = pendingWake
        self.savedHibernateMode = savedHibernateMode
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

    public init(version: String, settings: ClamStopSettings, phase: PowerPhase, pendingWake: Date?,
                lidClosed: Bool, sleepDisabled: Bool, hibernateMode: Int?) {
        self.version = version
        self.settings = settings
        self.phase = phase
        self.pendingWake = pendingWake
        self.lidClosed = lidClosed
        self.sleepDisabled = sleepDisabled
        self.hibernateMode = hibernateMode
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
