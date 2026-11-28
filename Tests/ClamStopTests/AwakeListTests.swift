import ClamStopDiagnostics
import ClamStopShared
import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_000_000)

private let processes: [Int32: ProcessIdentity] = [
    1: ProcessIdentity(name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude"),
    2: ProcessIdentity(name: "Claude Helper", path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
    3: ProcessIdentity(name: "backupd", path: "/System/Library/CoreServices/TimeMachine/backupd"),
    4: ProcessIdentity(name: "backupd-helper", path: "/System/Library/CoreServices/TimeMachine/backupd-helper"),
    5: ProcessIdentity(name: "caffeinate", path: "/usr/bin/caffeinate"),
    6: ProcessIdentity(name: "ClamStopDaemon", path: "/Applications/ClamStop.app/Contents/MacOS/ClamStopDaemon"),
    7: ProcessIdentity(name: "Safari", path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"),
    8: ProcessIdentity(name: "unknown", path: nil),
]

private func assertion(_ pid: Int32, _ type: String = "PreventUserIdleSystemSleep", _ name: String = "",
                       after: TimeInterval = 0) -> PowerAssertion {
    PowerAssertion(pid: pid, type: type, name: name, since: start + after)
}

private func list(_ assertions: [PowerAssertion], status: DaemonStatus? = nil, sleepDisabled: Bool? = false) -> AwakeList {
    AwakeList(assertions: assertions, status: status, sleepDisabled: sleepDisabled) { processes[$0]! }
}

private func status(session: StayAwakeSession? = nil, sleepDisabled: Bool = false, byClamStop: Bool = false,
                    agents: [AgentSessionInfo] = [], apps: [WatchedAppActivity] = [],
                    settings: ClamStopSettings = ClamStopSettings()) -> DaemonStatus {
    DaemonStatus(version: "0.1.0", settings: settings, phase: .idle, pendingWake: nil, lidClosed: false,
                 sleepDisabled: sleepDisabled, hibernateMode: 3, sleepDisabledByClamStop: byClamStop,
                 agents: agents, session: session, apps: apps)
}

@Suite struct AwakeListTests {
    @Test func oneLinePerAppWithItsHelpers() {
        let result = list([assertion(2, "PreventUserIdleDisplaySleep", "Video", after: 60),
                           assertion(1, "NoIdleSleepAssertion", "Electron", after: 10),
                           assertion(1, "NoIdleSleepAssertion", "Electron", after: 20)])
        #expect(result.apps.count == 1)
        let app = result.apps[0]
        #expect(app.name == "Claude")
        #expect(app.appBundlePath == "/Applications/Claude.app")
        #expect(app.keepsMac && app.keepsScreen)
        #expect(app.since == start + 10)
        #expect(app.details == ["Video", "Electron"])
    }

    @Test func macOSServicesAreSetApartUnderReadableNames() {
        let result = list([assertion(3, after: 5), assertion(4), assertion(8)])
        #expect(result.apps.isEmpty)
        #expect(result.system.map(\.name) == ["Time Machine backup", "unknown"])
        #expect(result.system[0].since == start)
    }

    @Test func commandsAndAppleAppsCountAsApps() {
        let result = list([assertion(5, after: 1), assertion(7, after: 2)])
        #expect(result.apps.map(\.name) == ["caffeinate", "Safari"])
    }

    @Test func otherAssertionsAndOurOwnAreLeftOut() {
        let result = list([assertion(1, "UserIsActive"), assertion(1, "BackgroundTask"),
                           assertion(1, "ExternalMedia"), assertion(6)])
        #expect(result.isEmpty)
    }

    @Test func clamStopReasons() {
        let since = start
        let agent = AgentSessionInfo(agent: .claude, since: since, finishing: false, subagents: 0)
        let busy = WatchedAppActivity(id: UUID(), name: "HandBrake", state: .working)
        let idle = WatchedAppActivity(id: UUID(), name: "ffmpeg", state: .idle)
        let holding = status(session: StayAwakeSession(started: since, until: nil), sleepDisabled: true,
                             byClamStop: true, agents: [agent, agent], apps: [busy, idle])
        #expect(list([], status: holding).clamStop == [
            .session(since: since, until: nil), .agents(names: ["Claude Code"], since: since),
            .apps(names: ["HandBrake"]),
        ])
        #expect(!list([], status: holding).sleepDisabledElsewhere)
        #expect(list([], status: status(sleepDisabled: true, byClamStop: true)).clamStop == [.rule])
        // Agents work, but nothing is held (a safety guard, or agents are not kept awake for).
        #expect(list([], status: status(agents: [agent])).clamStop.isEmpty)
    }

    @Test func sleepDisabledByAnotherTool() {
        #expect(list([], status: status(sleepDisabled: true)).sleepDisabledElsewhere)
        #expect(list([], sleepDisabled: true).sleepDisabledElsewhere)
        #expect(!list([], sleepDisabled: nil).sleepDisabledElsewhere)
    }

    @Test func theReportNamesAppsButNotTheirRequests() {
        let awake = list([assertion(1, "PreventUserIdleDisplaySleep", "My secret film.mp4"), assertion(3)])
        let facts = HealthFacts(service: .running, status: nil, system: nil, inApplicationsFolder: true,
                                notifications: .allowed, openAtLogin: true, menuBarIconShown: true,
                                agentsMissingHooks: [])
        var report = DiagnosticsReport(date: start + 3600, appVersion: "1", macOSVersion: "27", model: "Mac",
                                       facts: facts, events: [], log: .success(""))
        report.awake = awake
        let text = report.text(home: "/Users/someone")
        #expect(text.contains("## Holding sleep off\nscreen Claude for 60 min\nmacOS mac Time Machine backup for 60 min"))
        #expect(!text.contains("secret"))
    }
}
