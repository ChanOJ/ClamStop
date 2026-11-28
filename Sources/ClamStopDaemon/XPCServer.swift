import Foundation
import Security
import ClamStopShared

/// Mach service for the app. Only the ClamStop app may connect (see `clientRequirement`).
final class XPCServer: NSObject, NSXPCListenerDelegate, ClamStopDaemonXPC {
    private let listener = NSXPCListener(machServiceName: ClamStopID.machServiceName)
    private var requirement: String?
    private let service: DaemonService

    init(service: DaemonService) {
        self.service = service
        self.requirement = Self.clientRequirement()
        super.init()
        listener.delegate = self
    }

    func start() {
        if let requirement {
            Log.info("XPC client requirement: \(requirement)")
        } else {
            Log.error("no XPC client requirement could be built: every connection will be refused")
        }
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Read again for each connection: an ad-hoc app replaced while the daemon runs has a new
        // cdhash, and the daemon binary (pinned by launchd) may be unchanged so it keeps running.
        // No new trust: the daemon would read the same bundle on its next start (reboot).
        let current = Self.clientRequirement()
        if current != requirement {
            Log.info("XPC client requirement changed: \(current ?? "none")")
            requirement = current
        }
        guard let requirement else { return false }
        // The system checks the peer's code signature on each message; unsigned callers are dropped.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = .clamStopDaemon()
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: ClamStopDaemonXPC (called on XPC queues; the service hops to the main queue)

    func appStatus(externalDisplay: Bool, reply: @escaping (Data) -> Void) {
        let pid = NSXPCConnection.current()?.processIdentifier ?? 0
        DispatchQueue.main.async {
            // First, so that the app connecting sees the right screens.
            self.service.externalDisplayChanged(externalDisplay)
            if pid > 0 {
                self.service.appConnected(pid: pid)
                self.service.appHeartbeat(pid: pid)
            }
            reply(self.service.status().encoded())
        }
    }

    func appHeartbeat() {
        let pid = NSXPCConnection.current()?.processIdentifier ?? 0
        DispatchQueue.main.async { self.service.appHeartbeat(pid: pid) }
    }

    func getStatus(reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async { reply(self.service.status().encoded()) }
    }

    func setEnabled(_ enabled: Bool, reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            var settings = self.service.settings
            settings.enabled = enabled
            self.service.apply(settings)
            reply(self.service.status().encoded())
        }
    }

    func setHibernateDelay(minutes: Int, reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            var settings = self.service.settings
            settings.hibernateDelayMinutes = ClamStopSettings.clampDelay(minutes)
            self.service.apply(settings)
            reply(self.service.status().encoded())
        }
    }

    func setSettings(_ data: Data, reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            if let settings = try? JSONDecoder().decode(ClamStopSettings.self, from: data) {
                self.service.apply(settings)
            } else {
                Log.error("setSettings: cannot decode \(data.count) bytes")
            }
            reply(self.service.status().encoded())
        }
    }

    func agentEvent(_ data: Data, reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            if let message = try? JSONDecoder().decode(AgentHookMessage.self, from: data) {
                self.service.agents.handle(message)
            }
            reply(Data())
        }
    }

    func getSleepLog(reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            let encoder = JSONEncoder()
            reply((try? encoder.encode(self.service.sleepLog)) ?? Data())
        }
    }

    func sleepNow(reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            self.service.controller.sleepNow()
            reply(self.service.status().encoded())
        }
    }

    func hibernateNow(reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            self.service.controller.hibernateNow()
            reply(self.service.status().encoded())
        }
    }

    func startSession(seconds: Double, reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            let until = seconds > 0 ? Date().addingTimeInterval(min(seconds, 7 * 86_400)) : nil
            self.service.controller.startSession(until: until)
            reply(self.service.status().encoded())
        }
    }

    func stopSession(reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            self.service.controller.stopSession()
            reply(self.service.status().encoded())
        }
    }

    func restoreDefaults(reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            self.service.restoreDefaults()
            reply(self.service.status().encoded())
        }
    }

    // MARK: Code signing

    /// Requirement the connecting process must satisfy.
    ///
    /// - Developer ID builds (the daemon has a Team ID): Apple-anchored signature, the app's
    ///   bundle identifier and the same Team ID.
    /// - Ad-hoc builds (no Team ID: local builds and CI artifacts): an ad-hoc signature
    ///   proves nothing about its author, so the requirement pins the exact code: the app's
    ///   bundle identifier plus the cdhash of the `ClamStop.app` that contains this daemon.
    ///   Rebuilding the app changes the cdhash, and the daemon (started from the same bundle)
    ///   picks up the new one on its next launch.
    static func clientRequirement() -> String? {
        let appID = ClamStopID.appBundleID
        if let team = ownTeamID() {
            return "anchor apple generic and identifier \"\(appID)\" and certificate leaf[subject.OU] = \"\(team)\""
        }
        guard let appURL = containingAppURL(), let cdhash = cdhash(of: appURL) else { return nil }
        return "identifier \"\(appID)\" and cdhash H\"\(cdhash)\""
    }

    /// `ClamStop.app` when the daemon runs from `ClamStop.app/Contents/MacOS/ClamStopDaemon`.
    static func containingAppURL() -> URL? {
        // Not argv[0]: launchd (BundleProgram) does not pass the full path there.
        guard let path = Bundle.main.executablePath else { return nil }
        let exe = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    private static func signingInfo(_ code: SecStaticCode) -> [String: Any]? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }

    private static func ownTeamID() -> String? {
        var me: SecCode?
        var staticMe: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              let info = signingInfo(staticMe) else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func cdhash(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              let info = signingInfo(code),
              let hash = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
