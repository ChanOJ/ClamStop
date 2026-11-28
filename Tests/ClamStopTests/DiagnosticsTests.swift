import ClamStopDiagnostics
import ClamStopShared
import Foundation
import Testing

private func status(phase: PowerPhase = .idle, pendingWake: Date? = nil, sleepDisabled: Bool = false,
                    byClamStop: Bool = false, hibernateMode: Int = 3, appRunning: Bool = true,
                    settings: ClamStopSettings = ClamStopSettings()) -> DaemonStatus {
    DaemonStatus(version: "0.1.0", settings: settings, phase: phase, pendingWake: pendingWake, lidClosed: false,
                 sleepDisabled: sleepDisabled, hibernateMode: hibernateMode, sleepDisabledByClamStop: byClamStop,
                 onPowerAdapter: true, batteryPercent: 80, appRunning: appRunning)
}

private func facts(service: ServiceHealth = .running, status answer: DaemonStatus? = status(),
                   system: SystemSleepState? = SystemSleepState(sleepDisabled: false, hibernateMode: 3),
                   inApplications: Bool = true, notifications: NotificationAccess = .allowed,
                   missingHooks: [String] = []) -> HealthFacts {
    HealthFacts(service: service, status: answer, system: system, inApplicationsFolder: inApplications,
                notifications: notifications, openAtLogin: true, menuBarIconShown: true,
                agentsMissingHooks: missingHooks)
}

private func level(_ kind: HealthCheck.Kind, _ facts: HealthFacts) -> HealthCheck.Level? {
    HealthCheck.evaluate(facts).first { $0.kind == kind }?.level
}

@Suite struct HealthCheckTests {
    @Test func everythingWorks() {
        let checks = HealthCheck.evaluate(facts())
        #expect(checks.allSatisfy { $0.level == .ok })
        #expect(checks.count == 10)
    }

    @Test(arguments: [ServiceHealth.requiresApproval, .notRegistered, .notFound, .notResponding])
    func silentService(_ service: ServiceHealth) {
        let silent = facts(service: service, status: nil)
        #expect(level(.service, silent) == .problem)
        #expect(level(.appSeen, silent) == nil)
        #expect(level(.agentHooks, silent) == nil)
        #expect(level(.sleepDisabled, silent) == .ok)
    }

    @Test func staleAnswerOfASilentServiceIsIgnored() {
        let stale = facts(service: .notResponding, status: status(sleepDisabled: true, byClamStop: true),
                          system: SystemSleepState(sleepDisabled: true, hibernateMode: 3))
        #expect(level(.sleepDisabled, stale) == .problem)
    }

    @Test func sleepDisabled() {
        #expect(level(.sleepDisabled, facts(status: status(sleepDisabled: true))) == .problem)
        #expect(level(.sleepDisabled, facts(status: status(sleepDisabled: true, byClamStop: true))) == .ok)
    }

    @Test func leftoversOnlyAtRest() {
        let wake = SystemSleepState(sleepDisabled: false, hibernateMode: 25, scheduledWakes: [Date()])
        let idle = facts(status: status(hibernateMode: 25), system: wake)
        #expect(level(.hibernateMode, idle) == .warning)
        #expect(level(.scheduledWake, idle) == .warning)
        let busy = facts(status: status(phase: .hibernating, hibernateMode: 25), system: wake)
        #expect(level(.hibernateMode, busy) == .ok)
        #expect(level(.scheduledWake, busy) == .ok)
    }

    @Test func appLocationNotificationsHooksAndUnseenApp() {
        let state = facts(status: status(appRunning: false), inApplications: false, notifications: .denied,
                          missingHooks: ["Cursor"])
        #expect(level(.appLocation, state) == .warning)
        #expect(level(.appSeen, state) == .problem)
        #expect(level(.notifications, state) == .warning)
        #expect(level(.agentHooks, state) == .warning)
        let off = facts(status: status(settings: ClamStopSettings(keepAwakeForAgents: false)), missingHooks: ["Cursor"])
        #expect(level(.agentHooks, off) == nil)
    }

    @Test func pmsetOutput() {
        let output = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         hibernatemode        25
         sleep                1 (sleep prevented by caffeinate)
        """
        let state = SystemSleepState(pmsetOutput: output)
        #expect(state.sleepDisabled == true)
        #expect(state.hibernateMode == 25)
        #expect(SystemSleepState(pmsetOutput: "Currently in use:\n hibernatemode 3").sleepDisabled == false)
        #expect(SystemSleepState(pmsetOutput: "").sleepDisabled == nil)
    }
}

@Suite struct DiagnosticsReportTests {
    private func report(events: [SleepEvent]? = [], log: Result<String, DiagnosticsReport.LogUnavailable> = .success(""),
                        facts state: HealthFacts = facts()) -> DiagnosticsReport {
        DiagnosticsReport(date: Date(timeIntervalSince1970: 0), appVersion: "1.2.3 (45)", macOSVersion: "27.2",
                          model: "Mac17,1", facts: state, events: events, log: log)
    }

    @Test func sections() {
        let event = SleepEvent(date: Date(timeIntervalSince1970: 0), kind: .sleep, batteryPercent: 50)
        let text = report(events: [event], log: .success("first line\nsecond line")).text(home: "/Users/someone")
        for part in ["ClamStop: 1.2.3 (45)", "## Health check", "OK service", "hibernatemode: 3",
                     "\"hibernateDelayMinutes\" : 60", "sleep battery=50", "second line"] {
            #expect(text.contains(part), "missing \(part)")
        }
    }

    @Test func unavailableParts() {
        let text = report(events: nil, log: .failure(.init("not an administrator")),
                          facts: facts(service: .notResponding, status: nil, system: nil))
            .text(home: "/Users/someone")
        #expect(text.contains("no answer from the service"))
        #expect(text.contains("## Sleep journal (last 50 events)\nnot available"))
        #expect(text.contains("not available: not an administrator"))
    }

    @Test func noUserName() {
        let app = WatchedApp(name: "Tool", bundlePath: "/Users/someone/Applications/Tool.app")
        let state = facts(status: status(settings: ClamStopSettings(watchedApps: [app])))
        let text = report(log: .success("open /Users/someone/x\ncwd=/Users/other/y /Users/Shared/z"), facts: state)
            .text(home: "/Users/someone")
        #expect(!text.contains("someone"))
        #expect(!text.contains("other"))
        #expect(text.contains("~/Applications/Tool.app"))
        #expect(text.contains("cwd=~/y /Users/Shared/z"))
    }

    @Test func keepsTheNewestLogLinesWithinTheLimits() {
        let many = (1...1000).map { "line \($0) " + String(repeating: "x", count: 10) }.joined(separator: "\n")
        let short = report(log: .success(many)).text(home: "/Users/someone")
        #expect(!short.contains("line 700 "))
        #expect(short.contains("line 701 "))
        let long = (1...300).map { "line \($0) " + String(repeating: "x", count: 1000) }.joined(separator: "\n")
        let text = report(log: .success(long)).text(home: "/Users/someone")
        #expect(text.count <= DiagnosticsReport.characterLimit)
        #expect(text.contains("line 300 "))
        #expect(!text.contains("line 1 x"))
        let mail = report(log: .success(long)).text(home: "/Users/someone",
                                                    characterLimit: ProblemReport.mailBodyLimit)
        #expect(mail.count <= ProblemReport.mailBodyLimit)
        #expect(mail.contains("line 300 "))
    }
}

@Suite struct ProblemReportTests {
    private let report = ProblemReport(appVersion: "1.2.3", macOSVersion: "27.2", model: "Mac17,1",
                                       checks: [HealthCheck(.service, .problem), HealthCheck(.menuBarIcon, .info)])

    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    @Test func gitHubIssue() throws {
        let url = try #require(report.gitHubIssue(repository: URL(string: "https://github.com/owner/name")!))
        #expect(url.absoluteString.hasPrefix("https://github.com/owner/name/issues/new?body="))
        let body = try #require(query(url, "body"))
        #expect(body.contains("Failed checks: service (problem)\n"))
        // Instructions only while writing: a comment is not shown in the published issue.
        #expect(body.contains("<!-- Paste them below this line (⌘V). Read them first: this issue is public. -->"))
        #expect(query(url, "labels") == nil)
        // GitHub turns away addresses of about 8 000 characters.
        #expect(url.absoluteString.count < 2000)
    }

    @Test func mail() throws {
        let url = try #require(report.mailtoURL(address: "bugs@example.org", diagnostics: "one\ntwo"))
        #expect(url.absoluteString.hasPrefix("mailto:bugs@example.org?subject="))
        #expect(query(url, "subject") == "ClamStop 1.2.3: problem report")
        #expect(query(url, "body")?.contains("--- Diagnostics ---\r\none\r\ntwo\r\n") == true)
        #expect(report.mailBody(diagnostics: nil).contains("are attached"))
    }

    @Test func reservedCharacters() throws {
        let odd = ProblemReport(appVersion: "1+2&3=4#5", macOSVersion: "27.2", model: "Mac", checks: [])
        let url = try #require(odd.mailtoURL(address: "bugs@example.org", diagnostics: ""))
        #expect(!url.absoluteString.contains("1+2"))
        #expect(query(url, "subject") == "ClamStop 1+2&3=4#5: problem report")
    }
}
