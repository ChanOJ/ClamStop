import Foundation
import Security
import ClamStopShared

/// Mach service for the app. Only the ClamStop app may connect (see `clientRequirement`).
final class XPCServer: NSObject, NSXPCListenerDelegate, ClamStopDaemonXPC {
    private let listener = NSXPCListener(machServiceName: ClamStopID.machServiceName)
    /// The daemon's own Team ID, read once at start: whether callers are matched by team or by
    /// exact build does not depend on later changes to the files on disk.
    private let teamID: String?
    private var requirement: String?
    private let service: DaemonService
    /// Largest settings and hook messages accepted, in bytes.
    private static let maxSettingsSize = 256 * 1024
    private static let maxAgentEventSize = 16 * 1024

    init(service: DaemonService) {
        self.service = service
        let teamID = Self.ownTeamID()
        self.teamID = teamID
        self.requirement = Self.clientRequirement(teamID: teamID)
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
        // Ad-hoc builds only: read the cdhash again for each connection. An ad-hoc app replaced
        // while the daemon runs has a new one, and the daemon binary (pinned by launchd) may be
        // unchanged so it keeps running.
        let current = Self.clientRequirement(teamID: teamID)
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

    /// The user the calling process runs as; a value no account has when there is no caller.
    private static func callerUID() -> UInt32 {
        NSXPCConnection.current()?.effectiveUserIdentifier ?? UInt32.max
    }

    /// Run `body` for a caller allowed to control the daemon (`CallerPolicy`), then reply with
    /// the status.
    private func control(_ name: String = #function, reply: @escaping (Data) -> Void,
                         _ body: @escaping () -> Void) {
        let caller = Self.callerUID()
        DispatchQueue.main.async {
            if self.service.mayControl(caller) {
                body()
            } else {
                Log.error("\(name): refused for user \(caller)")
            }
            reply(self.service.status().encoded())
        }
    }

    func appStatus(externalDisplay: Bool, reply: @escaping (Data) -> Void) {
        let pid = NSXPCConnection.current()?.processIdentifier ?? 0
        let caller = Self.callerUID()
        DispatchQueue.main.async {
            // The app of another account only reads the status (polled: nothing logged).
            if self.service.mayControl(caller) {
                // First, so that the app connecting sees the right screens.
                self.service.externalDisplayChanged(externalDisplay)
                if pid > 0 {
                    self.service.appConnected(pid: pid, user: caller)
                    self.service.appHeartbeat(pid: pid)
                }
            }
            reply(self.service.status().encoded())
        }
    }

    func appHeartbeat() {
        // Only the followed process counts (`DaemonService.appHeartbeat`).
        let pid = NSXPCConnection.current()?.processIdentifier ?? 0
        DispatchQueue.main.async { self.service.appHeartbeat(pid: pid) }
    }

    func getStatus(reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async { reply(self.service.status().encoded()) }
    }

    func setEnabled(_ enabled: Bool, reply: @escaping (Data) -> Void) {
        control(reply: reply) {
            var settings = self.service.settings
            settings.enabled = enabled
            self.service.apply(settings)
        }
    }

    func setHibernateDelay(minutes: Int, reply: @escaping (Data) -> Void) {
        control(reply: reply) {
            var settings = self.service.settings
            settings.hibernateDelayMinutes = ClamStopSettings.clampDelay(minutes)
            self.service.apply(settings)
        }
    }

    func setSettings(_ data: Data, reply: @escaping (Data) -> Void) {
        control(reply: reply) {
            if data.count <= Self.maxSettingsSize,
               let settings = try? JSONDecoder().decode(ClamStopSettings.self, from: data) {
                self.service.apply(settings)
            } else {
                Log.error("setSettings: cannot decode \(data.count) bytes")
            }
        }
    }

    func agentEvent(_ data: Data, reply: @escaping (Data) -> Void) {
        let caller = Self.callerUID()
        DispatchQueue.main.async {
            if self.service.mayControl(caller), data.count <= Self.maxAgentEventSize,
               let message = try? JSONDecoder().decode(AgentHookMessage.self, from: data) {
                self.service.agents.handle(message, owner: caller)
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
        control(reply: reply) { self.service.controller.sleepNow() }
    }

    func hibernateNow(reply: @escaping (Data) -> Void) {
        control(reply: reply) { self.service.controller.hibernateNow() }
    }

    func startSession(seconds: Double, reply: @escaping (Data) -> Void) {
        control(reply: reply) {
            let until = seconds > 0 ? Date().addingTimeInterval(min(seconds, 7 * 86_400)) : nil
            self.service.controller.startSession(until: until)
        }
    }

    func stopSession(reply: @escaping (Data) -> Void) {
        control(reply: reply) { self.service.controller.stopSession() }
    }

    func restoreDefaults(reply: @escaping (Data) -> Void) {
        control(reply: reply) { self.service.restoreDefaults() }
    }

    // MARK: Code signing

    /// Requirement the connecting process must satisfy.
    ///
    /// - Developer ID builds (the daemon has a Team ID): Developer ID signature, the app's
    ///   bundle identifier and the same Team ID.
    /// - Ad-hoc builds (no Team ID: local builds and CI artifacts): an ad-hoc signature
    ///   proves nothing about its author, so the requirement pins the exact code: the app's
    ///   bundle identifier plus the cdhash of the `ClamStop.app` that contains this daemon.
    ///   Rebuilding the app changes the cdhash, and the daemon (started from the same bundle)
    ///   picks up the new one on its next launch.
    static func clientRequirement(teamID: String?) -> String? {
        let appID = ClamStopID.appBundleID
        if let teamID {
            return ClientRequirement.developerID(appID: appID, team: teamID)
        }
        guard let appURL = containingAppURL(), let cdhash = cdhash(of: appURL) else { return nil }
        return ClientRequirement.exactBuild(appID: appID, cdhash: cdhash)
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
