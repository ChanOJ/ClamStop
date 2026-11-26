import Foundation
import ClamStopShared

/// Pro settings: everything goes to the daemon as a whole `ClamStopSettings`.
extension AppModel {
    var settings: ClamStopSettings { status?.settings ?? ClamStopSettings() }

    func isUnlocked(_ feature: ProFeature) -> Bool {
        Entitlement.isUnlocked(feature)
    }

    /// Change some settings and send them all to the daemon.
    func changeSettings(_ change: (inout ClamStopSettings) -> Void) {
        guard let current = status?.settings else { return }
        var next = current
        change(&next)
        guard next != current else { return }
        if Self.previewPro {
            var preview = status
            preview?.settings = next
            if let preview { setPreviewStatus(preview) }
            return
        }
        update { try await $0.setSettings(next) }
    }

    // MARK: Preview

    /// Development aid (`--preview-pro`, with `--snapshot`): Pro settings with sample values
    /// and a working agent, without the background service.
    static let previewPro = CommandLine.arguments.contains("--preview-pro")

    func startProPreview() {
        let settings = ClamStopSettings(hibernateDelayMinutes: 30, agentMaxHours: 8, separateBatterySettings: true,
                                        battery: PowerSourceProfile(enabled: true, hibernateDelayMinutes: 5),
                                        lowBatteryHibernation: true, lowBatteryPercent: 10,
                                        timeRange: TimeRangeException(enabled: true))
        let status = DaemonStatus(
            version: ClamStopVersion.current, settings: settings, phase: .idle, pendingWake: nil, lidClosed: false,
            sleepDisabled: true, hibernateMode: 3, sleepDisabledByClamStop: true,
            agents: [AgentSessionInfo(agent: .claude, since: Date(), finishing: false, subagents: 0)],
            keepingAwakeForAgents: false, onPowerAdapter: true, batteryPercent: 76,
            connectedDisplays: ["DELL S2719DM"], lastLidDecision: nil)
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

    /// Add (or remove) ClamStop's hook in every agent found on this Mac.
    func setAgentHooks(installed: Bool) {
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

    // MARK: Sleep log

    func loadSleepLog() {
        guard !Self.previewPro else { return }
        Task {
            if let events = try? await client.sleepLog() {
                sleepLog = events
            }
        }
    }
}
