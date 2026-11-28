import Foundation
import ClamStopShared

extension AppModel {
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
            keepingAwake: false, onPowerAdapter: !onBattery, batteryPercent: 76, lastLidDecision: nil,
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
        func event(_ ago: TimeInterval, _ kind: SleepEvent.Kind, _ battery: Int, _ detail: String? = nil,
                   _ wake: WakeReason? = nil, _ thermal: ThermalLevel? = nil) -> SleepEvent {
            SleepEvent(date: now - ago, kind: kind, batteryPercent: battery, detail: detail, wakeReason: wake?.rawValue,
                       thermal: thermal?.rawValue)
        }
        sleepLog = [
            event(136_000, .lidClosed, 64),
            event(135_990, .keptAwake, 64, KeepAwakeReason.agents.rawValue),
            event(133_000, .thermalChanged, 42, ThermalLevel.heavy.rawValue, nil, .heavy),
            event(130_000, .keepAwakeEnded, 19, KeepAwakeEnd.batteryFloor.rawValue, nil, .heavy),
            event(129_990, .sleep, 19),
            event(100_000, .lidOpened, 18),
            event(99_999, .wake, 18, SleepLog.wakeLidOpen, .lid),
            event(41_000, .lidClosed, 79),
            event(40_990, .sleep, 79),
            event(37_390, .hibernate, 79),
            event(6_660, .lidOpened, 76),
            event(6_659, .wake, 76, SleepLog.wakeLidOpen, .lid),
            event(1_800, .sleep, 75),
            event(600, .wake, 75, SleepLog.wakeLidOpen, .keyboard),
        ]
    }
}
