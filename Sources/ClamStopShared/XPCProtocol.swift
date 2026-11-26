import Foundation

/// XPC interface of the daemon (Mach service `ClamStopID.machServiceName`).
/// Every reply carries a JSON-encoded `DaemonStatus` (empty `Data` on error).
@objc public protocol ClamStopDaemonXPC {
    func getStatus(reply: @escaping (Data) -> Void)
    func setEnabled(_ enabled: Bool, reply: @escaping (Data) -> Void)
    /// Minutes before hibernating; 0 = never.
    func setHibernateDelay(minutes: Int, reply: @escaping (Data) -> Void)
    /// For uninstall: `hibernatemode 3`, cancel every wake the daemon scheduled.
    func restoreDefaults(reply: @escaping (Data) -> Void)
}

public extension NSXPCInterface {
    static func clamStopDaemon() -> NSXPCInterface {
        NSXPCInterface(with: ClamStopDaemonXPC.self)
    }
}
