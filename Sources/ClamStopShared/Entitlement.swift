/// Features unlocked by ClamStop Pro. The free edition keeps sleep on lid close and
/// hibernation after 1 h or never. Same names as the licensing branch's `Entitlement.swift`.
public enum ProFeature: String, CaseIterable, Sendable {
    /// Hibernation delays other than "after 1 h" and "never".
    case hibernationDelays
    /// Stay awake with the lid closed while an AI coding agent (Claude Code, Codex) works.
    case agentKeepAwake
    /// Separate settings on battery and on power adapter.
    case powerSourceSettings
    /// Hibernate at once when the battery is low.
    case lowBatteryHibernation
    /// Time range and external display exceptions.
    case schedules
    /// History of sleeps, wakes and battery used.
    case sleepLog
    /// Other menu bar icons.
    case alternateIcons
}

/// The single check every Pro feature goes through. In the app, the license sets
/// `isProUnlocked`; the app sends it to the daemon (`ClamStopDaemonXPC.setProUnlocked`), which
/// sets it in its own process, because the root daemon cannot read the user's keychain.
public enum Entitlement {
    // TODO(licensing): default to false once the license check sets it.
    nonisolated(unsafe) public static var isProUnlocked = true

    public static func isUnlocked(_ feature: ProFeature) -> Bool {
        // TODO(licensing): replace with the licensing branch's body.
        isProUnlocked
    }
}
