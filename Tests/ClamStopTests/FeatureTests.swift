import Foundation
import Testing
@testable import ClamStopShared

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func controller(_ settings: ClamStopSettings = ClamStopSettings(hibernateDelayMinutes: 10),
                        context: PowerContext = PowerContext()) -> (PowerController, FakeEffects, [SleepEvent.Kind]) {
    let effects = FakeEffects()
    effects.context = context
    let c = PowerController(settings: settings, effects: effects, store: MemoryStore())
    c.start()
    return (c, effects, [])
}

private func closeLid(_ c: PowerController, _ e: FakeEffects) {
    e.lidClosed = true
    c.lidChanged(closed: true)
}

// MARK: Agent keep-awake in the controller

@Suite struct AgentKeepAwakeTests {
    @Test func agentsWorkingPreventsSleepBeforeTheLidCloses() {
        let (c, e, _) = controller()
        c.agentsChanged(working: true)
        // Must be set before the lid closes: a Mac without display sleeps at once otherwise.
        #expect(e.sleepDisabled)
        #expect(c.state.sleepDisabledByClamStop == true)
        closeLid(c, e)
        #expect(e.sleepRequests == 0)
        #expect(c.keepingAwakeForAgents)
    }

    @Test func agentsDoneSleepsThenHibernationPathAsUsual() {
        let (c, e, _) = controller()
        c.agentsChanged(working: true)
        closeLid(c, e)
        c.agentsChanged(working: false)
        #expect(!e.sleepDisabled)
        #expect(c.state.sleepDisabledByClamStop == nil)
        #expect(e.sleepRequests == 1)
        #expect(!c.keepingAwakeForAgents)
        c.systemWillSleep()
        #expect(c.state.phase == .awaitingHibernation)
        #expect(e.scheduled == [e.clock.addingTimeInterval(600)])
    }

    @Test func agentsDoneWithImmediateHibernation() {
        let (c, e, _) = controller(ClamStopSettings(hibernateDelayMinutes: 0))
        c.agentsChanged(working: true)
        closeLid(c, e)
        c.agentsChanged(working: false)
        #expect(e.hibernateMode == 25)
        #expect(c.state.phase == .hibernating)
        #expect(!e.sleepDisabled)
    }

    @Test func timeLimitSleepsEvenIfAgentsStillWork() {
        let (c, e, _) = controller(ClamStopSettings(hibernateDelayMinutes: 10, maxAwakeHours: 2))
        c.agentsChanged(working: true)
        closeLid(c, e)
        e.advance(2 * 3600)
        #expect(e.sleepRequests == 1)
        #expect(!e.sleepDisabled)
        #expect(!c.keepingAwakeForAgents)
        // Still working: the next check must not take disablesleep again.
        c.reevaluate(trigger: "agent check")
        #expect(!e.sleepDisabled)
        // Lid opened: back to normal.
        e.lidClosed = false
        c.lidChanged(closed: false)
        #expect(e.sleepDisabled)
    }

    @Test func noLimitKeepsAwake() {
        let (c, e, _) = controller(ClamStopSettings(hibernateDelayMinutes: 10, maxAwakeHours: 0))
        c.agentsChanged(working: true)
        closeLid(c, e)
        e.advance(48 * 3600)
        c.reevaluate(trigger: "agent check")
        #expect(c.keepingAwakeForAgents)
        #expect(e.sleepRequests == 0)
    }

    @Test func lowBatteryEndsKeepAwake() {
        var context = PowerContext(onPowerAdapter: false, batteryPercent: 50)
        let (c, e, _) = controller(ClamStopSettings(hibernateDelayMinutes: 10, onlyWhileCharging: false), context: context)
        c.agentsChanged(working: true)
        closeLid(c, e)
        #expect(c.keepingAwakeForAgents)
        context.batteryPercent = 19
        e.context = context
        c.reevaluate(trigger: "agent check")
        #expect(!c.keepingAwakeForAgents)
        #expect(e.sleepRequests == 1)
        #expect(!e.sleepDisabled)
    }

    @Test func thermalPressureEndsKeepAwake() {
        let (c, e, _) = controller()
        c.agentsChanged(working: true)
        closeLid(c, e)
        e.context.thermalPressure = true
        c.reevaluate(trigger: "agent check")
        #expect(e.sleepRequests == 1)
    }

    @Test func lidOpenStopsKeepingAwake() {
        let (c, e, _) = controller()
        c.agentsChanged(working: true)
        closeLid(c, e)
        e.lidClosed = false
        c.lidChanged(closed: false)
        #expect(!c.keepingAwakeForAgents)
        #expect(e.sleepDisabled)  // agents still work: ready for the next close
        c.agentsChanged(working: false)
        #expect(!e.sleepDisabled)
        #expect(e.sleepRequests == 0)
    }

    @Test func featureOffMeansNormalSleep() {
        let (c, e, _) = controller(ClamStopSettings(hibernateDelayMinutes: 10, keepAwakeForAgents: false))
        c.agentsChanged(working: true)
        #expect(!e.sleepDisabled)
        closeLid(c, e)
        #expect(e.sleepRequests == 1)
    }

    @Test func unpluggingEndsKeepAwake() {
        let (c, e, _) = controller()
        c.agentsChanged(working: true)
        closeLid(c, e)
        #expect(c.keepingAwakeForAgents)
        e.context.onPowerAdapter = false
        e.context.batteryPercent = 90
        c.reevaluate(trigger: "agent check")
        #expect(!c.keepingAwakeForAgents)
        #expect(e.sleepRequests == 1)
        #expect(!e.sleepDisabled)
    }

    @Test func heatGuardCanBeTurnedOff() {
        let (c, e, _) = controller(ClamStopSettings(hibernateDelayMinutes: 10, heatGuard: false))
        c.agentsChanged(working: true)
        closeLid(c, e)
        e.context.thermalPressure = true
        c.reevaluate(trigger: "agent check")
        #expect(c.keepingAwakeForAgents)
    }

    @Test func sleepNowWhileKeepingAwake() {
        let (c, e, _) = controller()
        c.agentsChanged(working: true)
        closeLid(c, e)
        c.sleepNow()
        #expect(!e.sleepDisabled)
        #expect(e.sleepRequests == 1)
        #expect(!c.keepingAwakeForAgents)
        c.reevaluate(trigger: "agent check")  // agents still work: no new hold until the lid opens
        #expect(!e.sleepDisabled)
    }

    @Test func foreignDisableSleepIsLeftAlone() {
        let (c, e, _) = controller()
        e.sleepDisabled = true  // set by the user or another tool
        c.agentsChanged(working: true)
        c.agentsChanged(working: false)
        #expect(e.sleepDisabled)
        #expect(c.state.sleepDisabledByClamStop == nil)
    }

    @Test func restartReleasesOwnDisableSleep() {
        let store = MemoryStore()
        store.state.sleepDisabledByClamStop = true
        let e = FakeEffects()
        e.sleepDisabled = true
        let c = PowerController(settings: ClamStopSettings(), effects: e, store: store)
        c.start()
        #expect(!e.sleepDisabled)
        #expect(store.state.sleepDisabledByClamStop == nil)
    }

    @Test func stopAndUninstallRelease() {
        let (c, e, _) = controller()
        c.agentsChanged(working: true)
        c.stop()
        #expect(!e.sleepDisabled)
        c.agentsChanged(working: false)
        c.agentsChanged(working: true)
        c.restoreDefaults()
        #expect(!e.sleepDisabled)
        #expect(e.hibernateMode == 3)
        #expect(e.scheduled.isEmpty)
    }

    @Test func turningClamStopOffReleases() {
        let (c, e, _) = controller()
        c.agentsChanged(working: true)
        #expect(e.sleepDisabled)
        c.apply(settings: ClamStopSettings(enabled: false))
        #expect(!e.sleepDisabled)
    }

    @Test func recordsSleepLogEvents() {
        let (c, e, _) = controller()
        var kinds: [SleepEvent.Kind] = []
        c.record = { kind, _ in kinds.append(kind) }
        c.agentsChanged(working: true)
        closeLid(c, e)
        c.agentsChanged(working: false)
        c.systemWillSleep()
        e.lidClosed = false
        c.systemDidWake()
        #expect(kinds == [.lidClosed, .keptAwakeForAgents, .agentsDone, .sleep, .wake])
    }
}

// MARK: Other rules in the controller

@Suite struct RuleControllerTests {
    @Test func batteryProfileDelay() {
        let s = ClamStopSettings(hibernateDelayMinutes: 120, separateBatterySettings: true,
                                 battery: PowerSourceProfile(enabled: true, hibernateDelayMinutes: 5))
        let (c, e, _) = controller(s, context: PowerContext(onPowerAdapter: false, batteryPercent: 80))
        closeLid(c, e)
        c.systemWillSleep()
        #expect(e.scheduled == [e.clock.addingTimeInterval(300)])
    }

    @Test func powerAdapterProfileDelay() {
        let s = ClamStopSettings(hibernateDelayMinutes: 120, separateBatterySettings: true,
                                 battery: PowerSourceProfile(enabled: true, hibernateDelayMinutes: 5))
        let (c, e, _) = controller(s, context: PowerContext(onPowerAdapter: true))
        closeLid(c, e)
        c.systemWillSleep()
        #expect(e.scheduled == [e.clock.addingTimeInterval(7200)])
    }

    @Test func offOnPowerAdapter() {
        let s = ClamStopSettings(separateBatterySettings: true, onPowerAdapterEnabled: false)
        let (c, e, _) = controller(s, context: PowerContext(onPowerAdapter: true))
        closeLid(c, e)
        #expect(e.sleepRequests == 0)
        c.systemWillSleep()  // macOS sleeps by itself (no display): no hibernation either
        #expect(e.scheduled.isEmpty)
    }

    @Test func lowBatteryHibernatesAtOnce() {
        let s = ClamStopSettings(hibernateDelayMinutes: 60, lowBatteryHibernation: true, lowBatteryPercent: 15)
        let (c, e, _) = controller(s, context: PowerContext(onPowerAdapter: false, batteryPercent: 12))
        closeLid(c, e)
        #expect(e.hibernateMode == 25)
        #expect(c.state.phase == .hibernating)
    }

    @Test func lowBatteryIgnoresTestOverride() {
        let s = ClamStopSettings(hibernateDelayMinutes: 60, lowBatteryHibernation: true, lowBatteryPercent: 15)
        let (c, e, _) = controller(s, context: PowerContext(onPowerAdapter: false, batteryPercent: 12))
        c.delayOverride = 120
        closeLid(c, e)
        #expect(c.state.phase == .hibernating)
    }

    @Test func hibernateNowWithTheLidOpen() {
        let (c, e, _) = controller(ClamStopSettings(hibernateDelayMinutes: ClamStopSettings.never))
        c.hibernateNow()
        #expect(e.hibernateMode == 25)
        #expect(c.state.phase == .hibernating)
        #expect(e.sleepRequests == 1)
        c.systemWillSleep()
        e.advance(600)
        c.systemDidWake()
        #expect(e.hibernateMode == 3)
        #expect(c.state.phase == .idle)
    }
}

// MARK: Policy

@Suite struct SleepPolicyTests {
    private func decide(_ s: ClamStopSettings, _ context: PowerContext = PowerContext(), agents: Bool = false) -> LidDecision {
        SleepPolicy.decide(settings: s, context: context, agentsWorking: agents)
    }

    @Test func basics() {
        #expect(decide(ClamStopSettings(enabled: false)) == .leaveAlone(reason: "ClamStop off"))
        #expect(decide(ClamStopSettings(hibernateDelayMinutes: 5)) == .sleep(hibernateAfter: 300, reason: "lid closed"))
        #expect(decide(ClamStopSettings(hibernateDelayMinutes: -1)) == .sleep(hibernateAfter: nil, reason: "lid closed"))
        #expect(decide(ClamStopSettings(), agents: true) == .keepAwake)
    }

    @Test func batteryGuardsOnlyOnBattery() {
        // Default: staying awake with the lid closed needs the power adapter.
        #expect(decide(ClamStopSettings(), PowerContext(onPowerAdapter: false, batteryPercent: 90), agents: true)
            == .sleep(hibernateAfter: 3600, reason: "on battery"))
        let onBattery = ClamStopSettings(onlyWhileCharging: false)
        #expect(decide(onBattery, PowerContext(onPowerAdapter: false, batteryPercent: 19), agents: true)
            == .sleep(hibernateAfter: 3600, reason: "battery below 20 %"))
        #expect(decide(onBattery, PowerContext(onPowerAdapter: false, batteryPercent: 20), agents: true)
            == .keepAwake)
        #expect(decide(ClamStopSettings(), PowerContext(onPowerAdapter: true, batteryPercent: 5), agents: true)
            == .keepAwake)
    }

    @Test func lowBatteryWinsOverAgents() {
        let s = ClamStopSettings(lowBatteryHibernation: true, lowBatteryPercent: 30, onlyWhileCharging: false)
        #expect(decide(s, PowerContext(onPowerAdapter: false, batteryPercent: 30), agents: true)
            == .sleep(hibernateAfter: 0, reason: "battery at 30 %"))
        // On power adapter the level does not matter.
        #expect(decide(s, PowerContext(onPowerAdapter: true, batteryPercent: 10)) == .sleep(hibernateAfter: 3600, reason: "lid closed"))
    }
}

// MARK: Settings model

@Suite struct SettingsModelTests {
    @Test func oldSettingsFileMigrates() throws {
        let old = Data(#"{"enabled":false,"hibernateDelayMinutes":10,"agentMaxHours":8,"displayExceptions":["A"]}"#.utf8)
        let s = try JSONDecoder().decode(ClamStopSettings.self, from: old)
        #expect(!s.enabled)
        #expect(s.hibernateDelayMinutes == 10)
        #expect(s.keepAwakeForAgents)
        #expect(s.maxAwakeHours == 0)
        #expect(!s.separateBatterySettings)
        #expect(s.batteryFloorPercent == 20)
        #expect(s.heatGuard)
        #expect(s.onlyWhileCharging)
    }

    @Test func roundTrip() throws {
        let s = ClamStopSettings(hibernateDelayMinutes: 5, separateBatterySettings: true,
                                 battery: PowerSourceProfile(enabled: false, hibernateDelayMinutes: 0),
                                 lowBatteryHibernation: true, lowBatteryPercent: 20, batteryFloorPercent: 30,
                                 heatGuard: false, onlyWhileCharging: false, maxAwakeHours: 4)
        #expect(try JSONDecoder().decode(ClamStopSettings.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func batteryFloorHasAMinimum() {
        #expect(ClamStopSettings(batteryFloorPercent: 1).batteryFloorPercent == 5)
    }

    @Test func olderStatusDecodes() throws {
        let old = Data(#"{"version":"0.1.0","settings":{"enabled":true,"hibernateDelayMinutes":10},"phase":"idle","lidClosed":false,"sleepDisabled":false}"#.utf8)
        let status = try #require(DaemonStatus.decode(old))
        #expect(status.agents == nil)
        #expect(status.settings.hibernateDelayMinutes == 10)
    }
}

// MARK: Agent tracker

@Suite struct AgentTrackerTests {
    private func message(_ event: String, session: String = "s1", agent: AgentKind = .claude) -> AgentHookMessage {
        AgentHookMessage(agent: agent, event: event, sessionID: session, transcriptPath: "/tmp/\(session).jsonl",
                         agentPID: 42, agentStartMicros: 7)
    }

    @Test func turnLifecycleWithGrace() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit"), now: t0)
        #expect(t.isWorking)
        t.handle(message("Stop"), now: t0 + 60)
        #expect(t.sessions.first?.finishing == true)
        t.tick(now: t0 + 60 + 89) { _ in AgentProbe(alive: true) }
        #expect(t.isWorking)
        t.tick(now: t0 + 60 + 91) { _ in AgentProbe(alive: true) }
        #expect(!t.isWorking)
    }

    @Test func nextTurnDuringGraceKeepsTheLease() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit"), now: t0)
        t.handle(message("Stop"), now: t0 + 10)
        t.handle(message("UserPromptSubmit"), now: t0 + 50)
        t.tick(now: t0 + 200) { _ in AgentProbe(alive: true, newestActivity: t0 + 190) }
        #expect(t.isWorking)
        #expect(t.sessions.first?.finishing == false)
    }

    @Test func transcriptWrittenAtTurnEndDoesNotCount() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit"), now: t0)
        t.handle(message("Stop"), now: t0 + 10)
        // Written just after the Stop hook (seen with Claude Code): not new work.
        t.tick(now: t0 + 101) { _ in AgentProbe(alive: true, newestActivity: t0 + 10.004) }
        #expect(!t.isWorking)
    }

    @Test func transcriptWrittenWellAfterTheTurnCounts() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit"), now: t0)
        t.handle(message("Stop"), now: t0 + 10)
        t.tick(now: t0 + 40) { _ in AgentProbe(alive: true, newestActivity: t0 + 30) }
        #expect(t.sessions.first?.finishing == false)
    }

    @Test func backgroundWorkReactivatesAfterTheTurn() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit"), now: t0)
        t.handle(message("Stop"), now: t0 + 10)
        t.tick(now: t0 + 20) { _ in AgentProbe(alive: true, cpuSeconds: 100) }
        t.tick(now: t0 + 35) { _ in AgentProbe(alive: true, cpuSeconds: 104) }  // a build runs
        #expect(t.sessions.first?.finishing == false)
        t.tick(now: t0 + 300) { _ in AgentProbe(alive: true, cpuSeconds: 104.01) }
        #expect(t.isWorking)  // active, idle for less than 30 min
    }

    @Test func idleCPUDoesNotCount() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit"), now: t0)
        t.handle(message("Stop"), now: t0 + 10)
        var cpu = 50.0
        for step in 1...8 {
            cpu += 0.05
            t.tick(now: t0 + 10 + Double(step) * 15) { _ in AgentProbe(alive: true, cpuSeconds: cpu) }
        }
        #expect(!t.isWorking)
    }

    @Test func processGoneDropsAtOnce() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit"), now: t0)
        t.tick(now: t0 + 15) { _ in AgentProbe(alive: false) }
        #expect(!t.isWorking)
    }

    @Test func unknownLivenessIsNotDeath() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit"), now: t0)
        t.tick(now: t0 + 15) { _ in AgentProbe(alive: nil) }
        #expect(t.isWorking)
    }

    @Test func silentActiveLeaseExpires() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit"), now: t0)
        t.tick(now: t0 + 29 * 60) { _ in AgentProbe(alive: true) }
        #expect(t.isWorking)
        t.tick(now: t0 + 31 * 60) { _ in AgentProbe(alive: true) }
        #expect(!t.isWorking)
    }

    @Test func subagentsKeepTheLease() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit"), now: t0)
        t.handle(message("SubagentStart"), now: t0 + 1)
        t.handle(message("Stop"), now: t0 + 2)  // parent turn waits
        t.tick(now: t0 + 3 * 3600) { _ in AgentProbe(alive: true) }
        #expect(t.isWorking)
        t.handle(message("SubagentStop"), now: t0 + 3 * 3600)
        t.handle(message("Stop"), now: t0 + 3 * 3600 + 1)
        t.tick(now: t0 + 3 * 3600 + 100) { _ in AgentProbe(alive: true) }
        #expect(!t.isWorking)
    }

    @Test func severalSessionsAndAgents() {
        let t = AgentTracker()
        t.handle(message("UserPromptSubmit", session: "a"), now: t0)
        t.handle(message("UserPromptSubmit", session: "a", agent: .codex), now: t0)
        t.handle(message("SessionEnd", session: "a"), now: t0 + 5)
        #expect(t.isWorking)
        #expect(t.sessions.map(\.agent) == [.codex])
        t.handle(message("SessionEnd", session: "a", agent: .codex), now: t0 + 6)
        #expect(!t.isWorking)
    }

    @Test func eventsWithoutLeaseAreIgnored() {
        let t = AgentTracker()
        t.handle(message("Stop"), now: t0)
        t.handle(message("SubagentStart"), now: t0)
        #expect(!t.isWorking)
    }

    @Test func hookInputParsing() throws {
        let json = Data(#"{"session_id":"abc","transcript_path":"/u/.claude/projects/p/abc.jsonl","cwd":"/u","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#.utf8)
        let m = try #require(AgentHookMessage.fromHookInput(json, agent: .claude))
        #expect(m.event == "UserPromptSubmit")
        #expect(m.sessionID == "abc")
        #expect(m.transcriptPath == "/u/.claude/projects/p/abc.jsonl")
        #expect(AgentHookMessage.fromHookInput(Data("nope".utf8), agent: .claude) == nil)
        #expect(AgentHookMessage.fromHookInput(Data(#"{"hook_event_name":"Stop"}"#.utf8), agent: .codex) == nil)
    }

    @Test func processTableFindsItself() throws {
        let me = try #require(ProcessTable.entry(getpid()))
        #expect(ProcessTable.isAlive(pid: me.pid, startMicros: me.startMicros))
        #expect(!ProcessTable.isAlive(pid: me.pid, startMicros: me.startMicros + 1))
        #expect((ProcessTable.cpuSeconds(getpid()) ?? 0) > 0)
        #expect(ProcessTable.agentKind(ofExecutable: "/x/claude.app/Contents/MacOS/claude") == .claude)
        #expect(ProcessTable.agentKind(ofExecutable: "/Applications/Claude.app/Contents/MacOS/Claude") == nil)
    }
}

// MARK: Hook settings

@Suite struct AgentHookSettingsTests {
    let command = #""/Applications/ClamStop.app/Contents/MacOS/ClamStop" --agent-hook claude"#
    let events = ["UserPromptSubmit", "Stop"]

    private var userSettings: [String: Any] {
        [
            "model": "opus",
            "hooks": [
                "Stop": [["matcher": "", "hooks": [["type": "command", "command": "say done"]]]],
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "check.sh"]]]],
            ],
        ]
    }

    private func commands(_ s: [String: Any], _ event: String) -> [String] {
        ((s["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }

    @Test func mergeKeepsOtherHooksAndIsIdempotent() {
        let once = AgentHookSettings.merging(into: userSettings, command: command, events: events)
        let twice = AgentHookSettings.merging(into: once, command: command, events: events)
        #expect(commands(twice, "Stop") == ["say done", command])
        #expect(commands(twice, "UserPromptSubmit") == [command])
        #expect(commands(twice, "PreToolUse") == ["check.sh"])
        #expect(twice["model"] as? String == "opus")
        #expect(AgentHookSettings.state(of: twice, command: command, events: events) == .installed)
    }

    @Test func removeRestoresTheUserHooks() {
        let merged = AgentHookSettings.merging(into: userSettings, command: command, events: events)
        let removed = AgentHookSettings.removing(from: merged)
        #expect(NSDictionary(dictionary: removed).isEqual(to: userSettings))
        #expect(AgentHookSettings.state(of: removed, command: command, events: events) == .notInstalled)
        let empty = AgentHookSettings.removing(from: AgentHookSettings.merging(into: [:], command: command, events: events))
        #expect(empty.isEmpty)
    }

    @Test func otherCopyIsOutdatedAndReplaced() {
        let old = AgentHookSettings.merging(into: userSettings,
                                            command: #""/Users/x/Downloads/ClamStop.app/Contents/MacOS/ClamStop" --agent-hook claude"#,
                                            events: events)
        #expect(AgentHookSettings.state(of: old, command: command, events: events) == .outdated)
        let fixed = AgentHookSettings.merging(into: old, command: command, events: events)
        #expect(commands(fixed, "Stop") == ["say done", command])
    }
}

// MARK: Sleep log

@Suite struct SleepLogTests {
    @Test func sessionsWithBatteryAndHibernation() {
        let events = [
            SleepEvent(date: t0, kind: .lidClosed, batteryPercent: 80),
            SleepEvent(date: t0 + 1, kind: .sleep, batteryPercent: 80),
            SleepEvent(date: t0 + 3600, kind: .hibernate, batteryPercent: 79),
            SleepEvent(date: t0 + 7200, kind: .wake, batteryPercent: 78, detail: SleepLog.wakeLidOpen),
            SleepEvent(date: t0 + 7201, kind: .lidOpened, batteryPercent: 78),
            SleepEvent(date: t0 + 9000, kind: .sleep, batteryPercent: 70),
            SleepEvent(date: t0 + 9500, kind: .wake, batteryPercent: 70, detail: "lid closed"),
            SleepEvent(date: t0 + 9600, kind: .sleep, batteryPercent: 70),
        ]
        let sessions = SleepLog.sessions(from: events)
        #expect(sessions.count == 2)
        #expect(sessions[0].end == nil)  // newest first, still asleep
        #expect(sessions[0].wakes == 1)
        #expect(sessions[1].hibernated)
        #expect(sessions[1].batteryUsed == 2)
        #expect(sessions[1].end == t0 + 7200)
        #expect(sessions[1].wakes == 0)
    }

    @Test func retention() {
        let old = SleepEvent(date: t0, kind: .sleep)
        let events = SleepLog.appending(SleepEvent(date: t0 + SleepLog.retention + 1, kind: .wake), to: [old])
        #expect(events.map(\.kind) == [.wake])
    }

    @Test func capacity() {
        var events: [SleepEvent] = []
        for i in 0..<(SleepLog.capacity + 10) {
            events = SleepLog.appending(SleepEvent(date: t0 + Double(i), kind: .sleep), to: events)
        }
        #expect(events.count == SleepLog.capacity)
        #expect(events.first?.date == t0 + 10)
    }
}

// MARK: "Stay awake" sessions (spec C1, C2)

@Suite struct StayAwakeSessionTests {
    @Test func sessionPreventsIdleSleepAndHoldsTheLid() {
        let (c, e, _) = controller()
        c.startSession(until: nil)
        #expect(e.idleSleepPrevented)
        #expect(e.sleepDisabled)  // before the lid closes
        closeLid(c, e)
        #expect(e.sleepRequests == 0)
        #expect(c.keepingAwakeForAgents)
        c.stopSession()
        #expect(!e.idleSleepPrevented)
        #expect(!e.sleepDisabled)
        #expect(e.sleepRequests == 1)  // lid closed: sleep as usual
    }

    @Test func sessionEndsAtItsTime() {
        let (c, e, _) = controller()
        c.startSession(until: e.clock.addingTimeInterval(1800))
        e.advance(1799)
        #expect(c.session != nil)
        e.advance(2)
        #expect(c.session == nil)
        #expect(!e.idleSleepPrevented)
    }

    @Test func onBatteryTheLidClosedHoldNeedsTheAdapterByDefault() {
        let (c, e, _) = controller(context: PowerContext(onPowerAdapter: false, batteryPercent: 80))
        c.startSession(until: nil)
        #expect(e.idleSleepPrevented)  // lid open: idle sleep only
        #expect(!e.sleepDisabled)
        closeLid(c, e)
        #expect(e.sleepRequests == 1)
        c.systemWillSleep()
        #expect(c.session == nil)  // any sleep ends the session
    }

    @Test func batteryFloorEndsTheSessionWithTheLidOpen() {
        let (c, e, _) = controller(ClamStopSettings(hibernateDelayMinutes: 10, batteryFloorPercent: 20),
                                   context: PowerContext(onPowerAdapter: false, batteryPercent: 50))
        c.startSession(until: nil)
        e.context.batteryPercent = 19
        e.advance(PowerController.sessionCheckInterval)
        #expect(c.session == nil)
        #expect(!e.idleSleepPrevented)
    }

    @Test func sleepNowEndsTheSession() {
        let (c, e, _) = controller()
        c.startSession(until: nil)
        c.sleepNow()
        #expect(c.session == nil)
        #expect(!e.sleepDisabled)
        #expect(e.sleepRequests == 1)
    }

    @Test func openingTheLidKeepsTheSession() {
        let (c, e, _) = controller()
        c.startSession(until: nil)
        closeLid(c, e)
        e.lidClosed = false
        c.lidChanged(closed: false)
        #expect(c.session != nil)
        #expect(e.idleSleepPrevented)
        #expect(e.sleepDisabled)
    }
}

// MARK: Notices for notifications (spec H5)

@Suite struct NoticeTests {
    @Test func guardReasonsFromPolicyDecisions() {
        #expect(Notice.Reason(decisionReason: "time limit reached") == .maxDuration)
        #expect(Notice.Reason(decisionReason: "Mac too hot") == .heat)
        #expect(Notice.Reason(decisionReason: "on battery") == .unplugged)
        #expect(Notice.Reason(decisionReason: "battery below 20 %") == .batteryFloor)
        #expect(Notice.Reason(decisionReason: "battery at 10 %") == .lowBattery)
        #expect(Notice.Reason(decisionReason: "lid closed") == nil)
    }

    @Test func sessionTimeUpIsNoticed() {
        let (c, e, _) = controller()
        c.startSession(until: e.clock.addingTimeInterval(600))
        e.advance(600)
        #expect(c.notices.map(\.kind) == [.sessionEnded])
        #expect(c.notices.first?.reason == .timeUp)
    }

    @Test func turningOffIsNotNoticed() {
        let (c, _, _) = controller()
        c.startSession(until: nil)
        c.stopSession()
        c.startSession(until: nil)
        c.sleepNow()
        #expect(c.notices.isEmpty)
    }

    @Test func heatStopWithTheLidClosedIsNoticed() {
        let (c, e, _) = controller()
        c.agentsChanged(working: true)
        closeLid(c, e)
        e.context.thermalPressure = true
        c.reevaluate(trigger: "agent check")
        #expect(c.notices.map(\.kind) == [.safetyStop])
        #expect(c.notices.first?.reason == .heat)
    }

    @Test func agentsDoneIsNotNoticed() {
        let (c, e, _) = controller()
        c.agentsChanged(working: true)
        closeLid(c, e)
        c.agentsChanged(working: false)
        #expect(c.notices.isEmpty)
    }

    @Test func batteryFloorWithTheLidOpenEndsTheSessionWithANotice() {
        let (c, e, _) = controller(context: PowerContext(onPowerAdapter: false, batteryPercent: 50))
        c.startSession(until: nil)
        e.context.batteryPercent = 10
        e.advance(PowerController.sessionCheckInterval)
        #expect(c.notices.first?.kind == .sessionEnded)
        #expect(c.notices.first?.reason == .batteryFloor)
        #expect(c.notices.first?.value == 20)
    }

    @Test func keepsOnlyTheLastNotices() {
        let (c, e, _) = controller()
        for _ in 0..<(Notice.limit + 3) {
            c.startSession(until: e.clock.addingTimeInterval(60))
            e.advance(60)
        }
        #expect(c.notices.count == Notice.limit)
    }
}
