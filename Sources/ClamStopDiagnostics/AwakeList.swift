// "What keeps my Mac awake?" (spec H2): macOS's power assertions, one line per app, and
// ClamStop's own reasons in words. Pure logic: the app reads the assertions and the processes.

import ClamStopShared
import Foundation

/// One power assertion, as `IOPMCopyAssertionsByProcess` gives it.
public struct PowerAssertion: Equatable, Sendable {
    /// The process it is for: the one on whose behalf it was taken, if any (sound played by
    /// `coreaudiod` for an app), otherwise the one that holds it.
    public var pid: Int32
    /// macOS's "true type", such as `PreventUserIdleSystemSleep`.
    public var type: String
    /// The technical name its owner gave it. It can hold a video title or a file name.
    public var name: String
    public var since: Date

    public init(pid: Int32, type: String, name: String, since: Date) {
        self.pid = pid
        self.type = type
        self.name = name
        self.since = since
    }
}

/// A process: its name as macOS reports it, and the path of its executable when readable.
public struct ProcessIdentity: Equatable, Sendable {
    public var name: String
    public var path: String?

    public init(name: String, path: String?) {
        self.name = name
        self.path = path
    }

    /// The outermost app bundle around the executable: helpers belong to their app.
    public var appBundlePath: String? {
        guard let path, let end = path.range(of: ".app/") else { return nil }
        return String(path[..<end.lowerBound]) + ".app"
    }

    /// Part of macOS rather than something the user runs.
    public var isSystem: Bool {
        guard let path, !path.isEmpty else { return true }
        // Command-line tools such as `caffeinate` (/usr/bin) are run by the user or their apps.
        return path.contains("/System/Library/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
            || path.hasPrefix("/sbin/") || path.hasPrefix("/Library/Apple/System/")
    }
}

public struct AwakeList: Equatable, Sendable {
    /// An app, a command or a macOS service that holds sleep off.
    public struct Holder: Equatable, Sendable, Identifiable {
        public var name: String
        public var appBundlePath: String?
        public var keepsMac: Bool
        public var keepsScreen: Bool
        /// The oldest of its requests.
        public var since: Date
        /// The assertions' technical names, without repeats.
        public var details: [String]

        public var id: String { appBundlePath ?? name }

        public init(name: String, appBundlePath: String?, keepsMac: Bool, keepsScreen: Bool, since: Date,
                    details: [String]) {
            self.name = name
            self.appBundlePath = appBundlePath
            self.keepsMac = keepsMac
            self.keepsScreen = keepsScreen
            self.since = since
            self.details = details
        }
    }

    /// Why ClamStop itself holds sleep off.
    public enum ClamStopReason: Equatable, Sendable {
        case session(since: Date, until: Date?)
        case agents(names: [String], since: Date)
        case apps(names: [String])
        case rule
    }

    public var clamStop: [ClamStopReason]
    public var apps: [Holder]
    public var system: [Holder]
    /// `pmset disablesleep 1` that the service does not report as ClamStop's own (unknown while it
    /// does not answer).
    public var sleepDisabledElsewhere: Bool

    public var isEmpty: Bool { clamStop.isEmpty && apps.isEmpty && system.isEmpty && !sleepDisabledElsewhere }

    public init(clamStop: [ClamStopReason] = [], apps: [Holder] = [], system: [Holder] = [],
                sleepDisabledElsewhere: Bool = false) {
        self.clamStop = clamStop
        self.apps = apps
        self.system = system
        self.sleepDisabledElsewhere = sleepDisabledElsewhere
    }

    /// Assertion types that keep the Mac, or the screen, from sleeping on its own. The others
    /// (key presses, background tasks, mounted disks) are left out.
    static let macTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]
    static let screenTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// ClamStop's processes: their assertions show as ClamStop's reasons instead.
    static let ownProcesses: Set<String> = ["ClamStop", "ClamStopDaemon"]

    /// Readable names for the macOS services met most often.
    static let systemNames: [String: String] = [
        "backupd": "Time Machine backup", "backupd-helper": "Time Machine backup",
        "sharingd": "Handoff and sharing", "powerd": "Power management",
        "coreaudiod": "Sound", "AddressBookSourceSync": "Contacts sync",
        "runningboardd": "Widgets and app extensions", "mds": "Spotlight", "mds_stores": "Spotlight",
        "mdworker": "Spotlight", "softwareupdated": "Software update", "cloudd": "iCloud",
        "bird": "iCloud Drive",
    ]

    /// `status`: the service's answer, nil when it does not answer.
    public init(assertions: [PowerAssertion], status: DaemonStatus?, sleepDisabled: Bool?,
                identity: (Int32) -> ProcessIdentity) {
        var apps: [String: Holder] = [:]
        var system: [String: Holder] = [:]
        for assertion in assertions {
            let mac = Self.macTypes.contains(assertion.type)
            let screen = Self.screenTypes.contains(assertion.type)
            guard mac || screen else { continue }
            let process = identity(assertion.pid)
            guard !Self.ownProcesses.contains(process.name) else { continue }
            let bundle = process.appBundlePath
            let isSystem = process.isSystem
            let name: String
            if isSystem {
                name = Self.systemNames[process.name] ?? process.name
            } else if let bundle {
                name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            } else {
                name = process.name
            }
            let key = isSystem ? name : bundle ?? name
            var holder = (isSystem ? system : apps)[key]
                ?? Holder(name: name, appBundlePath: isSystem ? nil : bundle, keepsMac: false, keepsScreen: false,
                          since: assertion.since, details: [])
            holder.keepsMac = holder.keepsMac || mac
            holder.keepsScreen = holder.keepsScreen || screen
            holder.since = min(holder.since, assertion.since)
            if !assertion.name.isEmpty, !holder.details.contains(assertion.name) {
                holder.details.append(assertion.name)
            }
            if isSystem { system[key] = holder } else { apps[key] = holder }
        }
        self.init(clamStop: status.map(Self.reasons) ?? [], apps: Self.sorted(apps.values),
                  system: Self.sorted(system.values),
                  sleepDisabledElsewhere: (status?.sleepDisabled ?? sleepDisabled) == true
                      && status?.sleepDisabledByClamStop != true)
    }

    /// Oldest first.
    private static func sorted(_ holders: some Sequence<Holder>) -> [Holder] {
        holders.sorted { ($0.since, $0.name) < ($1.since, $1.name) }
    }

    static func reasons(_ status: DaemonStatus) -> [ClamStopReason] {
        var reasons: [ClamStopReason] = []
        if let session = status.session {
            reasons.append(.session(since: session.started, until: session.until))
        }
        guard status.sleepDisabledByClamStop == true || status.keepingAwakeForAgents == true else { return reasons }
        let agents = status.settings.keepAwakeForAgents ? status.agents ?? [] : []
        if let since = agents.map(\.since).min() {
            var names: [String] = []
            for agent in agents where !names.contains(agent.agent.displayName) {
                names.append(agent.agent.displayName)
            }
            reasons.append(.agents(names: names, since: since))
        }
        let working = (status.apps ?? []).filter(\.holdsTheMac).map(\.name)
        if !working.isEmpty { reasons.append(.apps(names: working)) }
        if reasons.isEmpty { reasons.append(.rule) }
        return reasons
    }
}
