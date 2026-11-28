import AppKit
import Foundation
import UserNotifications
import ClamStopDiagnostics
import ClamStopShared

/// Health check, "Copy Diagnostics" and "Report a Problem" (spec H4).
extension AppModel {
    var healthFacts: HealthFacts {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = Bundle.main.bundleURL.path
        let defaults = UserDefaults.standard
        return HealthFacts(
            service: serviceHealth, status: status, system: systemState,
            inApplicationsFolder: Self.previewSettings || path.hasPrefix("/Applications/")
                || path.hasPrefix(home + "/Applications/"),
            notifications: notificationAccess, openAtLogin: launchAtLogin,
            menuBarIconShown: defaults.object(forKey: DefaultsKey.showMenuBarIcon) as? Bool ?? true,
            agentsMissingHooks: agentsMissingHooks.map(\.displayName))
    }

    var healthChecks: [HealthCheck] { HealthCheck.evaluate(healthFacts) }

    private var serviceHealth: ServiceHealth {
        switch serviceState {
        case .checking: .checking
        case .running: .running
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        case .notResponding: .notResponding
        }
    }

    /// Read again what the app does not already follow: macOS sleep settings and notifications.
    func readHealthFacts() async {
        if Self.previewSettings {
            systemState = SystemSleepState(sleepDisabled: true, hibernateMode: HibernateMode.default)
            notificationAccess = .allowed
            launchAtLogin = true
            return
        }
        systemState = await SystemProbe.sleepState()
        // Only from a ClamStop.app bundle: `current()` raises an exception outside one.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .denied: notificationAccess = .denied
        case .notDetermined: notificationAccess = .notAsked
        default: notificationAccess = .allowed
        }
    }

    /// The checks take no visible time: untick them all, then tick them again one at a time, so
    /// that the click is seen to do something.
    func checkAgain() {
        guard revealedChecks == nil else { return }
        revealedChecks = 0
        refresh()
        Task {
            await readHealthFacts()
            for count in 1...max(1, healthChecks.count) {
                try? await Task.sleep(for: .milliseconds(100))
                revealedChecks = count
            }
            revealedChecks = nil
            let failed = healthChecks.filter(\.failed).count
            VoiceOver.say(failed == 0 ? String(localized: "No problem found")
                : String(localized: "Checks with a problem: \(failed)"))
        }
    }

    /// Read what holds sleep off now (spec H2).
    func loadAwakeList() async {
        if Self.previewSettings {
            awakeList = Self.previewAwakeList()
            return
        }
        // The service's answer says it; without one, ask macOS.
        let sleepDisabled = serviceRunning ? nil : await SystemProbe.sleepState().sleepDisabled
        awakeList = AssertionReader.awakeList(status: serviceRunning ? status : nil, sleepDisabled: sleepDisabled)
    }

    /// Sample values for `--preview-settings --awake`.
    private static func previewAwakeList() -> AwakeList {
        let now = Date()
        func holder(_ name: String, _ app: String?, _ ago: TimeInterval, screen: Bool = false,
                    _ detail: String) -> AwakeList.Holder {
            AwakeList.Holder(name: name, appBundlePath: app, keepsMac: !screen, keepsScreen: screen,
                             since: now - ago, details: [detail])
        }
        return AwakeList(
            clamStop: [.session(since: now - 720, until: nil), .agents(names: ["Claude Code"], since: now - 240)],
            apps: [holder("Music", "/System/Applications/Music.app", 9360, "Playing audio"),
                   holder("Safari", "/Applications/Safari.app", 600, screen: true, "Video playing"),
                   holder("caffeinate", nil, 20, "caffeinate command-line tool")],
            system: [holder("Time Machine backup", nil, 1800, "Backup Job"),
                     holder("Handoff and sharing", nil, 300, "Handoff")])
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private var appVersionAndBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ClamStopVersion.current
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }

    private var problemReport: ProblemReport {
        ProblemReport(appVersion: appVersionAndBuild, macOSVersion: SystemProbe.macOSVersion,
                      model: SystemProbe.hardwareModel, checks: healthChecks)
    }

    func diagnosticsText() async -> String {
        text(of: await diagnosticsReport())
    }

    private func text(of report: DiagnosticsReport, limit: Int = DiagnosticsReport.characterLimit) -> String {
        report.text(home: FileManager.default.homeDirectoryForCurrentUser.path, characterLimit: limit)
    }

    private func diagnosticsReport() async -> DiagnosticsReport {
        await readHealthFacts()
        let events = serviceRunning ? try? await client.sleepLog() : nil
        let log = await SystemProbe.recentLog()
        await loadAwakeList()
        var report = DiagnosticsReport(date: Date(), appVersion: appVersionAndBuild,
                                 macOSVersion: SystemProbe.macOSVersion, model: SystemProbe.hardwareModel,
                                 facts: healthFacts, events: events, log: log,
                                 thermalLevel: .current)
        report.awake = awakeList
        return report
    }

    /// Collect the diagnostics (a few seconds, mostly the log), hand them over, say what happened.
    private func withDiagnostics(_ use: @escaping (DiagnosticsReport) -> String) {
        guard !preparingReport else { return }
        preparingReport = true
        reportMessage = nil
        Task {
            let message = use(await diagnosticsReport())
            preparingReport = false
            reportMessage = message
            VoiceOver.say(message)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyDiagnostics() {
        withDiagnostics { [self] diagnostics in
            copy(text(of: diagnostics))
            return String(localized: "Diagnostics copied.")
        }
    }

    func reportOnGitHub() {
        withDiagnostics { [self] diagnostics in
            copy(ProblemReport.gitHubBlock(text(of: diagnostics)))
            guard let url = problemReport.gitHubIssue(repository: Links.sourceCode), NSWorkspace.shared.open(url) else {
                return String(localized: "Diagnostics copied. The browser could not be opened: go to \(Links.sourceCode.absoluteString)/issues.")
            }
            return String(localized: "Diagnostics copied. Paste them into the issue with ⌘V.")
        }
    }

    /// Apple Mail takes the diagnostics as an attachment. Other mail apps get a `mailto:` link,
    /// which cannot carry a file: they are in the body, and copied too in case the app cuts it.
    /// A browser (webmail) gets a short body, and the diagnostics to paste.
    func reportByEmail() {
        withDiagnostics { [self] diagnostics in
            let report = problemReport
            let full = text(of: diagnostics)
            if Self.defaultMailAppIsAppleMail, let file = Self.writeAttachment(full),
               let service = NSSharingService(named: .composeEmail) {
                let items: [Any] = [report.mailBody(.attached), file]
                if service.canPerform(withItems: items) {
                    service.recipients = [Links.reportEmail]
                    service.subject = report.subject
                    service.perform(withItems: items)
                    return String(localized: "Your e-mail is ready in Mail. Read it, then send it.")
                }
            }
            copy(full)
            let webmail = Self.defaultMailAppIsBrowser
            let body: ProblemReport.MailDiagnostics = webmail
                ? .toPaste : .inBody(text(of: diagnostics, limit: ProblemReport.mailBodyLimit))
            guard let url = report.mailtoURL(address: Links.reportEmail, diagnostics: body),
                  NSWorkspace.shared.open(url) else {
                return String(localized: "Diagnostics copied. No mail app opened: paste them into an e-mail to \(Links.reportEmail).")
            }
            return webmail
                ? String(localized: "Diagnostics copied. Paste them into the e-mail with ⌘V.")
                : String(localized: "Your e-mail is ready. Read it, then send it. Diagnostics missing? Paste them with ⌘V.")
        }
    }

    private static var defaultMailApp: String? {
        guard let mailto = URL(string: "mailto:"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: mailto) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

    private static var defaultMailAppIsAppleMail: Bool { defaultMailApp == "com.apple.mail" }

    /// Mail links go to an app that also opens web pages.
    private static var defaultMailAppIsBrowser: Bool {
        guard let mail = defaultMailApp, let web = URL(string: "https://example.com") else { return false }
        return NSWorkspace.shared.urlsForApplications(toOpen: web)
            .contains { Bundle(url: $0)?.bundleIdentifier == mail }
    }

    private static func writeAttachment(_ text: String) -> URL? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ClamStop-diagnostics.txt")
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }
}
