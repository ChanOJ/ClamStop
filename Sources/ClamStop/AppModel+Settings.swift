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

    // MARK: Rules (spec D1)

    func saveRuleDraft() {
        guard let rule = ruleDraft, rule.isValid else { return }
        ruleDraft = nil
        changeSettings {
            if let index = $0.rules.firstIndex(where: { $0.id == rule.id }) {
                $0.rules[index] = rule
            } else {
                $0.rules.append(rule)
            }
        }
    }

    func setRule(_ rule: Rule, enabled: Bool) {
        changeSettings {
            guard let index = $0.rules.firstIndex(where: { $0.id == rule.id }) else { return }
            $0.rules[index].enabled = enabled
        }
    }

    func moveRule(_ rule: Rule, by offset: Int) {
        changeSettings {
            guard let index = $0.rules.firstIndex(where: { $0.id == rule.id }),
                  $0.rules.indices.contains(index + offset) else { return }
            $0.rules.swapAt(index, index + offset)
        }
    }

    func deleteRule(_ rule: Rule) {
        changeSettings { $0.rules.removeAll { $0.id == rule.id } }
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
        // Same precedence as the menu lines: a Stay Awake session first, then AI agents, then apps.
        if status.session != nil { return .awake(.session) }
        if agentsHolding { return .awake(.agents) }
        if !workingApps.isEmpty,
           status.keepingAwakeForAgents == true || status.sleepDisabledByClamStop == true {
            return .awake(.app)
        }
        return .active
    }

    /// Closing the lid would keep the Mac awake now (a session or AI agents, within the Safety
    /// guards): the "Sleeps when you close the lid" line no longer applies.
    var lidLineOverridden: Bool {
        statusIsOK && status?.lidPlan?.action != .stayAwake
            && (status?.sleepDisabledByClamStop == true || status?.keepingAwakeForAgents == true)
    }

    /// Watched apps that hold the Mac awake.
    private var workingApps: [WatchedAppActivity] {
        (status?.apps ?? []).filter(\.holdsTheMac)
    }

    /// Grey menu line saying why the Mac stays awake when AI agents or watched apps hold it:
    /// "Staying awake while Claude Code works". nil otherwise (a session has its own line).
    var awakeLine: String? {
        let names: [String]
        let finishing: Bool
        switch iconState {
        case .awake(.agents):
            let sessions = status?.agents ?? []
            names = Set(sessions.map(\.agent.displayName)).sorted()
            finishing = sessions.allSatisfy(\.finishing)
        case .awake(.app):
            names = workingApps.map(\.name)
            finishing = workingApps.allSatisfy { $0.state == .finishing }
        default:
            return nil
        }
        guard !names.isEmpty else { return nil }
        let list = names.formatted(.list(type: .and))
        switch (names.count > 1, finishing) {
        case (false, false): return String(localized: "Staying awake while \(list) works")
        case (false, true): return String(localized: "Staying awake while \(list) finishes")
        case (true, false): return String(localized: "Staying awake while \(list) work")
        case (true, true): return String(localized: "Staying awake while \(list) finish")
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

    /// The separate battery settings apply now, not those for the power adapter.
    var usesBatterySettings: Bool {
        status?.settings.separateBatterySettings == true && status?.onPowerAdapter == false
            && status?.lidPlan?.rule == nil
    }

    /// The live sentence at the top of the General tab (spec section 5).
    var summary: String {
        guard serviceRunning, let status else { return statusLine }
        let s = status.settings
        guard s.enabled else {
            return String(localized: "When you close the lid, macOS decides, as if ClamStop were not installed.")
        }
        let plan = status.lidPlan
        let action = plan?.action ?? .sleep
        var parts: [String] = []
        if plan?.rule != nil { parts.append(String(localized: "A rule applies now.")) }
        switch action {
        case .sleep:
            parts.append(usesBatterySettings
                ? String(localized: "On battery, when you close the lid, your Mac goes to sleep, even with a screen plugged in.")
                : String(localized: "When you close the lid, your Mac goes to sleep, even with a screen plugged in."))
            switch plan?.hibernateDelayMinutes ?? s.hibernateDelayMinutes {
            case ..<0: break
            case 0: parts.append(String(localized: "Right away, it stops using the battery completely (hibernation)."))
            case let m: parts.append(String(localized: "\(Self.delayTitle(m)) asleep, it stops using the battery completely (hibernation)."))
            }
        case .stayAwake:
            parts.append(String(localized: "When you close the lid, your Mac stays awake."))
        case .macOS:
            parts.append(usesBatterySettings
                ? String(localized: "On battery, when you close the lid, macOS decides, as if ClamStop were not installed.")
                : String(localized: "When you close the lid, macOS decides, as if ClamStop were not installed."))
        }
        if action == .sleep {
            switch (s.keepAwakeForAgents && agentHooksInstalled, !s.watchedApps.isEmpty) {
            case (true, true): parts.append(String(localized: "While AI agents or your chosen apps work, it stays awake."))
            case (true, false): parts.append(String(localized: "While AI agents work, it stays awake."))
            case (false, true): parts.append(String(localized: "While your chosen apps work, it stays awake."))
            case (false, false): break
            }
        }
        return parts.joined(separator: " ")
    }

    /// Second line of the menu status, nil when there is nothing to add.
    var menuDetail: String? {
        guard serviceRunning, let s = status?.settings, s.enabled else { return nil }
        let plan = status?.lidPlan
        guard plan == nil || plan?.action == .sleep else { return nil }
        let battery = usesBatterySettings
        switch plan?.hibernateDelayMinutes ?? s.hibernateDelayMinutes {
        case ..<0: return nil
        case 0:
            return battery ? String(localized: "On battery: stops using the battery right away")
                : String(localized: "Stops using the battery right away")
        case 60:
            return battery ? String(localized: "On battery: stops using the battery after 1 hour asleep")
                : String(localized: "Stops using the battery after 1 hour asleep")
        case let m where m % 60 == 0:
            return battery ? String(localized: "On battery: stops using the battery after \(m / 60) hours asleep")
                : String(localized: "Stops using the battery after \(m / 60) hours asleep")
        case let m:
            return battery ? String(localized: "On battery: stops using the battery after \(m) minutes asleep")
                : String(localized: "Stops using the battery after \(m) minutes asleep")
        }
    }

    // MARK: Preview

    /// Development aid (`--preview-settings [--tab name] [--on-battery]`, with `--snapshot`): the
    /// settings with sample values and a working agent, without the background service.
    static let previewSettings = CommandLine.arguments.contains("--preview-settings")

    func startSettingsPreview() {
        let settings = ClamStopSettings(hibernateDelayMinutes: 60, separateBatterySettings: true,
                                        battery: PowerSourceProfile(enabled: true, hibernateDelayMinutes: 15),
                                        lowBatteryHibernation: true, lowBatteryPercent: 10, rules: [
                                            Rule(power: .adapter, display: .connected, action: .stayAwake),
                                            Rule(time: TimeWindow(start: 23 * 60, end: 7 * 60), action: .sleep,
                                                 hibernateDelayMinutes: 0),
                                        ], watchedApps: [
                                            WatchedApp(name: "HandBrake", bundlePath: "/Applications/HandBrake.app"),
                                            WatchedApp(name: "ffmpeg", executables: ["ffmpeg"]),
                                        ])
        let onBattery = CommandLine.arguments.contains("--on-battery")
        let status = DaemonStatus(
            version: ClamStopVersion.current, settings: settings, phase: .idle, pendingWake: nil, lidClosed: false,
            sleepDisabled: true, hibernateMode: 3, sleepDisabledByClamStop: true,
            agents: [AgentSessionInfo(agent: .claude, since: Date(), finishing: false, subagents: 0)],
            keepingAwakeForAgents: false, onPowerAdapter: !onBattery, batteryPercent: 76, lastLidDecision: nil,
            lidPlan: settings.lidPlan(for: PowerContext(onPowerAdapter: !onBattery, externalDisplay: !onBattery)),
            apps: zip(settings.watchedApps, [WatchedAppActivity.State.working, .notRunning]).map {
                WatchedAppActivity(id: $0.id, name: $0.name, state: $1)
            })
        setPreviewStatus(status)
        // Development aid: `--edit-rule` shows the rule editor.
        if CommandLine.arguments.contains("--edit-rule") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.ruleDraft = Rule(power: .battery, time: TimeWindow(start: 22 * 60, end: 7 * 60), action: .stayAwake)
            }
        }
        agentHookStates = [.claude: .installed, .cursor: .notInstalled]
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
        for target in AgentHookTarget.all {
            states[target.agent] = AgentHookInstaller.state(target)
        }
        if states != agentHookStates { agentHookStates = states }
    }

    /// Hooks pointing to another copy of ClamStop (the app moved or was replaced): fix them.
    func updateOutdatedAgentHooks() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        for target in AgentHookTarget.all where AgentHookInstaller.state(target) == .outdated {
            try? AgentHookInstaller.install(target)
        }
    }

    var agentHooksInstalled: Bool {
        agentHookStates.values.contains(.installed)
    }

    var agentsFound: [AgentKind] {
        AgentKind.allCases.filter { (agentHookStates[$0] ?? .notFound) != .notFound }
    }

    /// Agents on this Mac that do not have the hook yet.
    var agentsMissingHooks: [AgentKind] {
        agentsFound.filter { agentHookStates[$0] != .installed }
    }

    /// Files changed by installing the hooks, for the confirmation shown first (spec I5).
    var agentHookFiles: [String] {
        let missing = Set(agentsMissingHooks)
        return AgentHookTarget.all.filter { missing.contains($0.agent) }.map { "~/" + $0.file }
    }

    /// Add ClamStop's hook to every agent found on this Mac, or remove it from every agent.
    func setAgentHooks(installed: Bool) {
        guard !Self.previewSettings else { return }
        var failure: Error?
        // One agent's unreadable settings do not stop the others.
        for target in AgentHookTarget.all {
            do {
                if !installed {
                    try AgentHookInstaller.uninstall(target)
                } else if AgentHookInstaller.state(target) != .notFound {
                    try AgentHookInstaller.install(target)
                }
            } catch {
                failure = error
            }
        }
        if let failure {
            errorMessage = String(localized: "The AI agent settings could not be changed: \(failure.localizedDescription)")
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
