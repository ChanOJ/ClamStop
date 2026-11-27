import Foundation
import ClamStopShared

/// Settings sent to the daemon as a whole `ClamStopSettings`, agent hooks, journal, menu actions
/// and the plain-words sentences shown in the settings window and the menu.
extension AppModel {
    var settings: ClamStopSettings { status?.settings ?? ClamStopSettings() }
    var serviceRunning: Bool { serviceState == .running }

    /// Change some settings and send them all to the daemon.
    func changeSettings(_ change: (inout ClamStopSettings) -> Void) {
        guard let current = status?.settings else { return }
        var next = current
        change(&next)
        guard next != current else { return }
        if Self.previewSettings {
            var preview = status
            preview?.settings = next
            if let preview { setPreviewStatus(preview) }
            return
        }
        update { try await $0.setSettings(next) }
    }

    // MARK: Menu actions

    func sleepNow() {
        update { try await $0.sleepNow() }
    }

    func hibernateNow() {
        update { try await $0.hibernateNow() }
    }

    /// "Stay awake" (spec C1): `minutes` nil = until turned off.
    func startSession(minutes: Int?) {
        update { try await $0.startSession(seconds: Double((minutes ?? 0) * 60)) }
    }

    func startSession(until date: Date) {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return }
        update { try await $0.startSession(seconds: seconds) }
    }

    func stopSession() {
        update { try await $0.stopSession() }
    }

    /// Durations offered in the "Stay Awake" menu, in minutes.
    static let sessionDurations = [5, 10, 15, 30, 60, 120, 300, 480]

    /// "For 5 Minutes", "For 1 Hour", "For 2 Hours" (menu titles).
    static func durationTitle(_ minutes: Int) -> String {
        switch minutes {
        case 60: String(localized: "For 1 Hour")
        case let m where m % 60 == 0: String(localized: "For \(m / 60) Hours")
        case let m: String(localized: "For \(m) Minutes")
        }
    }

    static func nextFullHour(after date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? date.addingTimeInterval(3600)
    }

    /// Menu bar icon state (spec H1).
    var iconState: MenuBarIconState {
        guard statusIsOK, let status else { return .inactive }
        let agentsHolding = !(status.agents ?? []).isEmpty
            && (status.keepingAwakeForAgents == true || status.sleepDisabledByClamStop == true)
        // Same precedence as the menu lines: a Stay Awake session first, then AI agents.
        if status.session != nil { return .awake(.session) }
        if agentsHolding { return .awake(.agents) }
        return .active
    }

    /// Closing the lid would keep the Mac awake now (a session or AI agents, within the Safety
    /// guards): the "Sleeps when you close the lid" line no longer applies.
    var lidLineOverridden: Bool {
        statusIsOK && (status?.sleepDisabledByClamStop == true || status?.keepingAwakeForAgents == true)
    }

    /// Grey menu line saying why the Mac stays awake when AI agents hold it: "Staying awake
    /// while Claude Code works". nil otherwise (a session has its own line).
    var awakeLine: String? {
        guard iconState == .awake(.agents), let sessions = status?.agents, !sessions.isEmpty else { return nil }
        let kinds = Set(sessions.map(\.agent.displayName)).sorted()
        let names = kinds.formatted(.list(type: .and))
        switch (kinds.count > 1, sessions.allSatisfy(\.finishing)) {
        case (false, false): return String(localized: "Staying awake while \(names) works")
        case (false, true): return String(localized: "Staying awake while \(names) finishes")
        case (true, false): return String(localized: "Staying awake while \(names) work")
        case (true, true): return String(localized: "Staying awake while \(names) finish")
        }
    }

    /// Short time left next to the icon: "25m", "1h 20m" (nil without an end time).
    var sessionTimeLeft: String? {
        guard serviceRunning, let until = status?.session?.until else { return nil }
        let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        if minutes < 60 { return String(localized: "\(minutes)m", comment: "Time left in the menu bar") }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60)h", comment: "Time left in the menu bar") }
        return String(localized: "\(minutes / 60)h \(minutes % 60)m", comment: "Time left in the menu bar")
    }

    /// "Staying awake until 15:30 (25 min left)" or "Staying awake until you turn it off".
    var sessionLine: String? {
        guard serviceRunning, let session = status?.session else { return nil }
        guard let until = session.until else { return String(localized: "Staying awake until you turn it off") }
        let time = until.formatted(date: .omitted, time: .shortened)
        let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        let left: String
        switch minutes {
        case ..<60: left = String(localized: "\(minutes) min left")
        case let m where m % 60 == 0: left = String(localized: "\(m / 60) h left")
        case let m: left = String(localized: "\(m / 60) h \(m % 60) min left")
        }
        return String(localized: "Staying awake until \(time) (\(left))")
    }

    // MARK: Sentences

    /// "Immediately", "After 5 minutes", "After 1 hour", "Never".
    static func delayTitle(_ minutes: Int) -> String {
        switch minutes {
        case ..<0: String(localized: "Never")
        case 0: String(localized: "Immediately")
        case 60: String(localized: "After 1 hour")
        case let m where m % 60 == 0: String(localized: "After \(m / 60) hours")
        default: String(localized: "After \(minutes) minutes")
        }
    }

    /// The live sentence at the top of the General tab (spec section 5).
    var summary: String {
        guard serviceRunning, let status else { return statusLine }
        let s = status.settings
        guard s.enabled else {
            return String(localized: "When you close the lid, macOS decides, as if ClamStop were not installed.")
        }
        var parts = [String(localized: "When you close the lid, your Mac goes to sleep, even with a screen plugged in.")]
        switch s.hibernateDelayMinutes {
        case ..<0: break
        case 0: parts.append(String(localized: "Right away, it stops using the battery completely (hibernation)."))
        case let m: parts.append(String(localized: "\(Self.delayTitle(m)) asleep, it stops using the battery completely (hibernation)."))
        }
        if s.separateBatterySettings {
            parts.append(String(localized: "On battery, the settings of the Rules tab apply."))
        }
        if s.keepAwakeForAgents, agentHooksInstalled {
            parts.append(String(localized: "While AI agents work, it stays awake."))
        }
        return parts.joined(separator: " ")
    }

    /// Second line of the menu status, nil when there is nothing to add.
    var menuDetail: String? {
        guard serviceRunning, let s = status?.settings, s.enabled else { return nil }
        switch s.hibernateDelayMinutes {
        case ..<0: return nil
        case 0: return String(localized: "Stops using the battery right away")
        case 60: return String(localized: "Stops using the battery after 1 hour asleep")
        case let m where m % 60 == 0: return String(localized: "Stops using the battery after \(m / 60) hours asleep")
        case let m: return String(localized: "Stops using the battery after \(m) minutes asleep")
        }
    }

    // MARK: Preview

    /// Development aid (`--preview-settings [--tab name]`, with `--snapshot`): the settings with
    /// sample values and a working agent, without the background service.
    static let previewSettings = CommandLine.arguments.contains("--preview-settings")

    func startSettingsPreview() {
        let settings = ClamStopSettings(hibernateDelayMinutes: 60, separateBatterySettings: true,
                                        battery: PowerSourceProfile(enabled: true, hibernateDelayMinutes: 15),
                                        lowBatteryHibernation: true, lowBatteryPercent: 10)
        let status = DaemonStatus(
            version: ClamStopVersion.current, settings: settings, phase: .idle, pendingWake: nil, lidClosed: false,
            sleepDisabled: true, hibernateMode: 3, sleepDisabledByClamStop: true,
            agents: [AgentSessionInfo(agent: .claude, since: Date(), finishing: false, subagents: 0)],
            keepingAwakeForAgents: false, onPowerAdapter: true, batteryPercent: 76, lastLidDecision: nil)
        setPreviewStatus(status)
        agentHookStates = [.claude: .installed, .codex: .notFound]
        let now = Date()
        sleepLog = [
            SleepEvent(date: now - 86_400 * 2, kind: .sleep, batteryPercent: 91),
            SleepEvent(date: now - 86_400 * 2 + 3600, kind: .hibernate, batteryPercent: 90),
            SleepEvent(date: now - 86_400 - 30_000, kind: .wake, batteryPercent: 89, detail: SleepLog.wakeLidOpen),
            SleepEvent(date: now - 7200, kind: .sleep, batteryPercent: 80),
            SleepEvent(date: now - 3000, kind: .wake, batteryPercent: 79, detail: SleepLog.wakeLidOpen),
        ]
    }

    // MARK: Agent hooks

    func refreshAgentHooks() {
        var states: [AgentKind: AgentHookSettings.State] = [:]
        for target in AgentHookInstaller.targets() {
            states[target.agent] = AgentHookInstaller.state(target)
        }
        if states != agentHookStates { agentHookStates = states }
    }

    /// Hooks pointing to another copy of ClamStop (the app moved or was replaced): fix them.
    func updateOutdatedAgentHooks() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        for target in AgentHookInstaller.targets() where AgentHookInstaller.state(target) == .outdated {
            try? AgentHookInstaller.install(target)
        }
    }

    var agentHooksInstalled: Bool {
        agentHookStates.values.contains(.installed)
    }

    var agentsFound: [AgentKind] {
        AgentKind.allCases.filter { (agentHookStates[$0] ?? .notFound) != .notFound }
    }

    /// Files changed by installing the hooks, for the confirmation shown first (spec I5).
    var agentHookFiles: [String] {
        AgentHookInstaller.targets()
            .filter { (agentHookStates[$0.agent] ?? .notFound) != .notFound }
            .map { $0.file.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
    }

    /// Add (or remove) ClamStop's hook in every agent found on this Mac.
    func setAgentHooks(installed: Bool) {
        guard !Self.previewSettings else { return }
        do {
            for target in AgentHookInstaller.targets() where AgentHookInstaller.state(target) != .notFound {
                if installed {
                    try AgentHookInstaller.install(target)
                } else {
                    try AgentHookInstaller.uninstall(target)
                }
            }
        } catch {
            errorMessage = String(localized: "The AI agent settings could not be changed: \(error.localizedDescription)")
        }
        refreshAgentHooks()
    }

    // MARK: Journal

    func loadSleepLog() {
        guard !Self.previewSettings else { return }
        Task {
            if let events = try? await client.sleepLog() {
                sleepLog = events
            }
        }
    }

    // MARK: First run

    /// Send the first-run choices once the service answers (it may not run yet at the last step).
    func applyPendingFirstRun() {
        guard let result = pendingFirstRun, serviceRunning, status != nil else { return }
        pendingFirstRun = nil
        if result.choice == .agents { setAgentHooks(installed: true) }
        changeSettings {
            $0.enabled = true
            $0.keepAwakeForAgents = result.choice == .agents
            $0.hibernateDelayMinutes = result.hibernateDelayMinutes
        }
    }
}

/// First-run screen 1 choice (spec section 5).
enum FirstRunChoice {
    case sleep
    case agents
}

struct FirstRunResult {
    var choice: FirstRunChoice
    var hibernateDelayMinutes: Int
}
