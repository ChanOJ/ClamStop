import Foundation

/// XPC interface of the daemon (Mach service `ClamStopID.machServiceName`).
/// Every reply carries a JSON-encoded `DaemonStatus` (empty `Data` on error).
@objc public protocol ClamStopDaemonXPC {
    func getStatus(reply: @escaping (Data) -> Void)
    func setEnabled(_ enabled: Bool, reply: @escaping (Data) -> Void)
    /// Minutes before hibernating: 0 = immediately, -1 (`ClamStopSettings.never`) = never.
    func setHibernateDelay(minutes: Int, reply: @escaping (Data) -> Void)
    /// For uninstall: `hibernatemode 3`, cancel every wake the daemon scheduled.
    func restoreDefaults(reply: @escaping (Data) -> Void)
    /// Replace every setting at once: JSON-encoded `ClamStopSettings`.
    func setSettings(_ settings: Data, reply: @escaping (Data) -> Void)
    /// From `ClamStop --agent-hook`: JSON-encoded `AgentHookMessage`. Replies with the status.
    func agentEvent(_ message: Data, reply: @escaping (Data) -> Void)
    /// JSON-encoded `[SleepEvent]` (empty `Data` on error).
    func getSleepLog(reply: @escaping (Data) -> Void)
    /// The app's license state (`Entitlement.isProUnlocked`): the daemon cannot read the keychain.
    func setProUnlocked(_ unlocked: Bool, reply: @escaping (Data) -> Void)
}

public extension NSXPCInterface {
    static func clamStopDaemon() -> NSXPCInterface {
        NSXPCInterface(with: ClamStopDaemonXPC.self)
    }
}
