/// Features unlocked by ClamStop Pro. The free edition keeps sleep on lid close and
/// hibernation after 1 h or never.
public enum ProFeature: String, CaseIterable, Codable, Sendable {
    /// Stay awake with the lid closed while an AI coding agent (Claude Code, Codex) works.
    case agentKeepAwake
    /// Hibernation delays other than "after 1 h" and "never".
    case hibernationDelays
    /// Separate settings on battery and on power adapter.
    case powerSourceSettings
    /// Hibernate at once when the battery is low.
    case lowBatteryHibernation
    /// Time range and external display exceptions.
    case schedulesAndExceptions
    /// History of sleeps, wakes and battery used.
    case sleepLog
}

/// The single check every Pro feature goes through, in the app and in the daemon.
public enum Entitlement {
    public static func isUnlocked(_ feature: ProFeature) -> Bool {
        // TODO(licensing): replace with the license check (Polar key, later StoreKit).
        true
    }
}
