// Health check (spec H4): what could stop ClamStop from working, from facts the app gathers.
// A library of its own, so that the daemon stays byte-identical when it changes.

import ClamStopShared
import Foundation

/// State of the background service, as the app sees it.
public enum ServiceHealth: String, Sendable {
    case checking, running, requiresApproval, notRegistered, notFound, notResponding
}

/// Whether macOS lets ClamStop post notifications.
public enum NotificationAccess: String, Sendable {
    case allowed, denied, notAsked, unknown
}

/// What macOS says about sleep, read by the app itself: known even when the service is silent.
public struct SystemSleepState: Equatable, Sendable {
    /// `pmset disablesleep 1`: the Mac cannot sleep.
    public var sleepDisabled: Bool?
    public var hibernateMode: Int?
    /// Wakes scheduled by ClamStop's daemon.
    public var scheduledWakes: [Date]

    public init(sleepDisabled: Bool? = nil, hibernateMode: Int? = nil, scheduledWakes: [Date] = []) {
        self.sleepDisabled = sleepDisabled
        self.hibernateMode = hibernateMode
        self.scheduledWakes = scheduledWakes
    }

    /// From the output of `pmset -g`.
    public init(pmsetOutput: String, scheduledWakes: [Date] = []) {
        var values: [String: String] = [:]
        for line in pmsetOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2 { values[String(fields[0])] = String(fields[1]) }
        }
        // `SleepDisabled` only shows once it has been set; absent means sleep works.
        self.init(sleepDisabled: values.isEmpty ? nil : values["SleepDisabled"] == "1",
                  hibernateMode: values["hibernatemode"].flatMap(Int.init),
                  scheduledWakes: scheduledWakes)
    }
}

public struct HealthFacts: Sendable {
    public var service: ServiceHealth
    /// The service's last answer, only while it runs.
    public var status: DaemonStatus?
    /// nil until read.
    public var system: SystemSleepState?
    public var inApplicationsFolder: Bool
    public var notifications: NotificationAccess
    public var openAtLogin: Bool
    public var menuBarIconShown: Bool
    /// Names of the AI agents found on this Mac without ClamStop's hook.
    public var agentsMissingHooks: [String]

    public init(service: ServiceHealth, status: DaemonStatus?, system: SystemSleepState?,
                inApplicationsFolder: Bool, notifications: NotificationAccess, openAtLogin: Bool,
                menuBarIconShown: Bool, agentsMissingHooks: [String]) {
        self.service = service
        self.status = status
        self.system = system
        self.inApplicationsFolder = inApplicationsFolder
        self.notifications = notifications
        self.openAtLogin = openAtLogin
        self.menuBarIconShown = menuBarIconShown
        self.agentsMissingHooks = agentsMissingHooks
    }
}

public struct HealthCheck: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case appLocation, service, appSeen, sleepDisabled, hibernateMode, scheduledWake, notifications,
             agentHooks, openAtLogin, menuBarIcon
    }

    public enum Level: String, Sendable {
        case ok, info, warning, problem
    }

    public var kind: Kind
    public var level: Level
    public var id: Kind { kind }

    public init(_ kind: Kind, _ level: Level) {
        self.kind = kind
        self.level = level
    }

    public var failed: Bool { level == .warning || level == .problem }

    /// The checks that can be made with these facts, in the order shown.
    public static func evaluate(_ facts: HealthFacts) -> [HealthCheck] {
        var checks: [HealthCheck] = []
        let running = facts.service == .running
        let status = running ? facts.status : nil

        checks.append(HealthCheck(.appLocation, facts.inApplicationsFolder ? .ok : .warning))
        switch facts.service {
        case .running: checks.append(HealthCheck(.service, .ok))
        case .checking: checks.append(HealthCheck(.service, .info))
        default: checks.append(HealthCheck(.service, .problem))
        }
        if let seen = status?.appRunning {
            checks.append(HealthCheck(.appSeen, seen ? .ok : .problem))
        }

        // The service's answer first: it is as fresh, and says whether ClamStop set the value.
        if let disabled = status?.sleepDisabled ?? facts.system?.sleepDisabled {
            // Set by ClamStop to stay awake: expected while the service runs, and only then.
            let ours = status?.sleepDisabledByClamStop == true
            checks.append(HealthCheck(.sleepDisabled, disabled && !ours ? .problem : .ok))
        }
        // While the service handles a sleep, a changed mode and a scheduled wake are expected.
        let atRest = status.map { $0.phase == .idle } ?? true
        if let mode = status?.hibernateMode ?? facts.system?.hibernateMode {
            checks.append(HealthCheck(.hibernateMode, mode != HibernateMode.default && atRest ? .warning : .ok))
        }
        if let system = facts.system {
            let stray = !system.scheduledWakes.isEmpty && atRest && status?.pendingWake == nil
            checks.append(HealthCheck(.scheduledWake, stray ? .warning : .ok))
        }

        switch facts.notifications {
        case .allowed: checks.append(HealthCheck(.notifications, .ok))
        case .denied: checks.append(HealthCheck(.notifications, .warning))
        case .notAsked: checks.append(HealthCheck(.notifications, .info))
        case .unknown: break
        }
        if status?.settings.keepAwakeForAgents == true {
            checks.append(HealthCheck(.agentHooks, facts.agentsMissingHooks.isEmpty ? .ok : .warning))
        }
        checks.append(HealthCheck(.openAtLogin, facts.openAtLogin ? .ok : .info))
        checks.append(HealthCheck(.menuBarIcon, facts.menuBarIconShown ? .ok : .info))
        return checks
    }
}
