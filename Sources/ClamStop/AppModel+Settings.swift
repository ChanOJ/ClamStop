import Foundation
import ClamStopAppCore
import ClamStopShared

/// Settings sent to the daemon as a whole `ClamStopSettings`, rules, menu actions, agent hooks,
/// journal and first run.
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

    /// "+30 min" (spec C4): from the session's end, or a new half hour when it is over. The
    /// service sees it as a new session.
    func extendSession() {
        guard let until = SessionEnd.extended(status?.session, now: Date()) else { return }
        startSession(until: until)
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

    // MARK: Agent hooks

    func refreshAgentHooks() {
        var states: [AgentKind: AgentHookSettings.State] = [:]
        for target in AgentHookTarget.all {
            states[target.agent] = AgentHookInstaller.state(target)
        }
        if states != agentHookStates { agentHookStates = states }
    }

    /// Hooks pointing to another copy of ClamStop (the app moved or was replaced): fix them,
    /// from an installed copy only. Elsewhere, the settings window still offers to install.
    func updateOutdatedAgentHooks() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app",
              AgentHookTarget.mayRepointHooks(toAppAt: bundle.path, home: NSHomeDirectory()) else { return }
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
