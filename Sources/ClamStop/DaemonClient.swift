import CoreGraphics
import Foundation
import ClamStopShared

enum DaemonClientError: Error {
    case unreachable(String)
    case timeout
    case badReply
}

/// XPC client of the privileged daemon.
final class DaemonClient {
    static let timeout: TimeInterval = 8
    /// For the status of a service that is starting or not answering.
    static let startingTimeout: TimeInterval = 2
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

    private func call(timeout: TimeInterval = DaemonClient.timeout,
                      _ body: @escaping (ClamStopDaemonXPC, @escaping (Data) -> Void) -> Void) async throws -> DaemonStatus {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let fail: (Error) -> Void = { error in
                once.run { continuation.resume(throwing: DaemonClientError.unreachable(error.localizedDescription)) }
            }
            guard let proxy = proxy(onError: fail) else {
                fail(DaemonClientError.badReply)
                return
            }
            // A daemon launchd cannot start ("spawn scheduled", EX_CONFIG after an ad-hoc update)
            // never answers and no error comes back (seen on macOS 27.2): give up after a while.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(throwing: DaemonClientError.timeout) }
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

    /// The app's poll: also tells the daemon that the app runs (see `appStatus`).
    func status(timeout: TimeInterval = DaemonClient.timeout) async throws -> DaemonStatus {
        let externalDisplay = Self.externalDisplayConnected
        return try await call(timeout: timeout) { $0.appStatus(externalDisplay: externalDisplay, reply: $1) }
    }

    /// The watchdog's heartbeat, sent at once from the main thread: no answer expected.
    func heartbeat() {
        proxy { _ in }?.appHeartbeat()
    }

    /// A screen other than the built-in one is connected (including one that sleeps).
    static var externalDisplayConnected: Bool {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
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

    func sleepNow() async throws -> DaemonStatus {
        try await call { $0.sleepNow(reply: $1) }
    }

    func hibernateNow() async throws -> DaemonStatus {
        try await call { $0.hibernateNow(reply: $1) }
    }

    func startSession(seconds: Double) async throws -> DaemonStatus {
        try await call { $0.startSession(seconds: seconds, reply: $1) }
    }

    func stopSession() async throws -> DaemonStatus {
        try await call { $0.stopSession(reply: $1) }
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
