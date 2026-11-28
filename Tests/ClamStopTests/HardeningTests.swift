@testable import ClamStopShared
import Foundation
import Security
import Testing

@Suite struct CallerTests {
    @Test func onlyRootTheConsoleUserAndTheAppUserControl() {
        #expect(CallerPolicy.mayControl(caller: 0, consoleUser: nil, appUser: nil))
        #expect(CallerPolicy.mayControl(caller: 501, consoleUser: 501, appUser: nil))
        #expect(CallerPolicy.mayControl(caller: 501, consoleUser: 502, appUser: 501))
        #expect(!CallerPolicy.mayControl(caller: 503, consoleUser: 502, appUser: 501))
        #expect(!CallerPolicy.mayControl(caller: 501, consoleUser: nil, appUser: nil))
    }

    @Test func requirementsCompile() {
        let texts = [ClientRequirement.developerID(appID: ClamStopID.appBundleID, team: "ABCDE12345"),
                     ClientRequirement.exactBuild(appID: ClamStopID.appBundleID,
                                                  cdhash: String(repeating: "0a", count: 20))]
        for text in texts {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
        }
    }
}

@Suite struct AgentLimitTests {
    private func start(_ session: String, transcript: String? = nil) -> AgentHookMessage {
        AgentHookMessage(agent: .claude, event: "UserPromptSubmit", sessionID: session, transcriptPath: transcript)
    }

    @Test func oversizedOrOddValuesAreIgnored() {
        let tracker = AgentTracker()
        let now = Date()
        tracker.handle(start(""), now: now)
        tracker.handle(start(String(repeating: "a", count: 257)), now: now)
        tracker.handle(start("two\nlines"), now: now)
        tracker.handle(start("long path", transcript: "/" + String(repeating: "a", count: 1024)), now: now)
        #expect(tracker.leases.isEmpty)
    }

    @Test func sessionsAreLimited() {
        let tracker = AgentTracker()
        for i in 0..<(AgentTracker.maxLeases + 5) { tracker.handle(start("s\(i)"), now: Date(), owner: 501) }
        #expect(tracker.leases.count == AgentTracker.maxLeases)
        // A session already followed still reports.
        tracker.handle(start("s0", transcript: "/t.jsonl"), now: Date(), owner: 501)
        #expect(tracker.leases["claude-s0"]?.transcriptPath == "/t.jsonl")
        #expect(tracker.leases["claude-s0"]?.owner == 501)
    }

    @Test func onlyTheOwnersFilesCountAsActivity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("s"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appendingPathComponent("s.jsonl").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: transcript))
        try Data("x".utf8).write(to: folder.appendingPathComponent("s/sub.jsonl"))
        #expect(ProcessTable.newestActivity(transcript: transcript, owner: getuid()) != nil)
        #expect(ProcessTable.newestActivity(transcript: transcript, owner: getuid() + 1) == nil)
        #expect(ProcessTable.newestActivity(transcript: transcript) != nil)
    }
}

@Suite struct SettingsLimitTests {
    @Test func decodedValuesAreClamped() throws {
        let rule = #"{"id":"00000000-0000-0000-0000-000000000000","enabled":true,"power":"battery","action":"sleep","hibernateDelayMinutes":9223372036854775807}"#
        let json = #"{"maxAwakeHours":9223372036854775807,"battery":{"enabled":true,"hibernateDelayMinutes":9223372036854775807},"rules":["# + rule + "]}"
        let settings = try JSONDecoder().decode(ClamStopSettings.self, from: Data(json.utf8))
        #expect(settings.maxAwakeHours == ClamStopSettings.maxAwakeHoursLimit)
        #expect(settings.battery.hibernateDelayMinutes == ClamStopSettings.maxDelayMinutes)
        #expect(settings.rules.first?.hibernateDelayMinutes == ClamStopSettings.maxDelayMinutes)
        #expect(settings.rules.first?.power == .battery)
    }

    @Test func listsAreLimited() {
        let rules = (0..<(ClamStopSettings.maxRules + 1)).map { _ in Rule(power: .battery) }
        #expect(ClamStopSettings(rules: rules).rules.count == ClamStopSettings.maxRules)
    }

    @Test func settingsSurviveARoundTrip() throws {
        let settings = ClamStopSettings(separateBatterySettings: true, rules: [
            Rule(display: .connected, time: TimeWindow(start: 60, end: 120), action: .stayAwake)])
        let decoded = try JSONDecoder().decode(ClamStopSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}

@Suite struct PersistFirstTests {
    private final class Spy: StateStore {
        var saved: [PersistedState] = []
        func load() -> PersistedState { PersistedState() }
        func save(_ state: PersistedState) { saved.append(state) }
    }

    @Test func disablesleepIsRecordedBeforeItIsSet() {
        let effects = FakeEffects()
        let store = Spy()
        let controller = PowerController(settings: ClamStopSettings(), effects: effects, store: store)
        controller.start()
        var recordedWhenSet = false
        effects.onSetSleepDisabled = { recordedWhenSet = store.saved.last?.sleepDisabledByClamStop == true }
        controller.startSession(until: nil)
        #expect(effects.sleepDisabled)
        #expect(recordedWhenSet)
    }

    @Test func aRefusedDisablesleepIsNotRecorded() {
        let effects = FakeEffects()
        effects.setSleepDisabledFails = true
        let store = Spy()
        let controller = PowerController(settings: ClamStopSettings(), effects: effects, store: store)
        controller.start()
        controller.startSession(until: nil)
        #expect(controller.state.sleepDisabledByClamStop == nil)
        #expect(store.saved.last?.sleepDisabledByClamStop == nil)
    }

    @Test func nothingIsHeldAfterRestoringDefaults() {
        let effects = FakeEffects()
        let controller = PowerController(settings: ClamStopSettings(), effects: effects, store: Spy())
        controller.start()
        controller.restoreDefaults()
        controller.startSession(until: nil)
        #expect(!effects.sleepDisabled)
    }
}
