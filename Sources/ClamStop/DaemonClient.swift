import Foundation
import ClamStopShared

enum DaemonClientError: Error {
    case unreachable(String)
    case badReply
}

/// XPC client of the privileged daemon.
final class DaemonClient {
    private var connection: NSXPCConnection?

    private func proxy(onError: @escaping (Error) -> Void) -> ClamStopDaemonXPC? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: ClamStopID.machServiceName, options: .privileged)
            c.remoteObjectInterface = .clamStopDaemon()
            c.invalidationHandler = { [weak self] in
                DispatchQueue.main.async { self?.connection = nil }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? ClamStopDaemonXPC
    }

    private func call(_ body: @escaping (ClamStopDaemonXPC, @escaping (Data) -> Void) -> Void) async throws -> DaemonStatus {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let fail: (Error) -> Void = { error in
                once.run { continuation.resume(throwing: DaemonClientError.unreachable(error.localizedDescription)) }
            }
            guard let proxy = proxy(onError: fail) else {
                fail(DaemonClientError.badReply)
                return
            }
            body(proxy) { data in
                once.run {
                    if let status = DaemonStatus.decode(data) {
                        continuation.resume(returning: status)
                    } else {
                        continuation.resume(throwing: DaemonClientError.badReply)
                    }
                }
            }
        }
    }

    func status() async throws -> DaemonStatus {
        try await call { $0.getStatus(reply: $1) }
    }

    func setEnabled(_ enabled: Bool) async throws -> DaemonStatus {
        try await call { $0.setEnabled(enabled, reply: $1) }
    }

    func setHibernateDelay(minutes: Int) async throws -> DaemonStatus {
        try await call { $0.setHibernateDelay(minutes: minutes, reply: $1) }
    }

    func setSettings(_ settings: ClamStopSettings) async throws -> DaemonStatus {
        let data = try JSONEncoder().encode(settings)
        return try await call { $0.setSettings(data, reply: $1) }
    }

    func setProUnlocked(_ unlocked: Bool) async throws -> DaemonStatus {
        try await call { $0.setProUnlocked(unlocked, reply: $1) }
    }

    func sleepLog() async throws -> [SleepEvent] {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let proxy = proxy { error in
                once.run { continuation.resume(throwing: DaemonClientError.unreachable(error.localizedDescription)) }
            }
            guard let proxy else {
                once.run { continuation.resume(throwing: DaemonClientError.badReply) }
                return
            }
            proxy.getSleepLog { data in
                once.run {
                    if let events = try? JSONDecoder().decode([SleepEvent].self, from: data) {
                        continuation.resume(returning: events)
                    } else {
                        continuation.resume(throwing: DaemonClientError.badReply)
                    }
                }
            }
        }
    }

    func restoreDefaults() async throws -> DaemonStatus {
        try await call { $0.restoreDefaults(reply: $1) }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }
}

/// Runs its block only once (XPC may call both the reply and the error handler).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}
