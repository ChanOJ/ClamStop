import ClamStopAppCore
import Foundation
import Testing
@testable import ClamStopShared

/// Thermal levels: journal, logs and the heat guard (spec E2).
@Suite struct ThermalTests {
    private final class Journal {
        var events: [(SleepEvent.Kind, String?)] = []
    }

    private func setUp() -> (PowerController, FakeEffects, Journal) {
        let effects = FakeEffects()
        let controller = PowerController(settings: ClamStopSettings(), effects: effects, store: MemoryStore())
        let journal = Journal()
        controller.record = { journal.events.append(($0, $1)) }
        controller.start()
        controller.thermalChanged(.nominal)
        return (controller, effects, journal)
    }

    private func keepAwakeWithTheLidClosed(_ controller: PowerController, _ effects: FakeEffects) {
        controller.startSession(until: nil)
        effects.lidClosed = true
        controller.lidChanged(closed: true)
    }

    private func settle(_ effects: FakeEffects) {
        effects.clock += PowerController.settleDelay
        let due = effects.timers.filter { $0.0 <= effects.clock }
        effects.timers.removeAll { $0.0 <= effects.clock }
        due.forEach { $0.1() }
    }

    @Test func pressureLevels() {
        #expect((0...4).map { ThermalLevel(pressure: $0) } == ThermalLevel.allCases)
        #expect(ThermalLevel(pressure: 99) == .sleeping)
        #expect(ThermalLevel.allCases.filter(\.isTooHot) == [.trapping, .sleeping])
    }

    @Test func theWarmerReadingCounts() {
        // Seen on an M5 Pro: `fair` while the pressure level is heavy.
        #expect(ThermalLevel(pressure: 2, state: .fair) == .heavy)
        #expect(!ThermalLevel(pressure: 2, state: .fair).isTooHot)
        // `serious` stays enough on its own, as before the pressure level was read.
        #expect(ThermalLevel(pressure: 0, state: .serious).isTooHot)
        #expect(ThermalLevel(pressure: nil, state: .nominal) == .nominal)
        #expect(ThermalLevel(pressure: 3, state: .fair).isTooHot)
    }

    @Test func notedOnlyWhileStayingAwakeWithTheLidClosed() {
        let (controller, effects, journal) = setUp()
        controller.thermalChanged(.moderate)
        #expect(!journal.events.contains { $0.0 == .thermalChanged })
        keepAwakeWithTheLidClosed(controller, effects)
        controller.thermalChanged(.nominal)
        controller.thermalChanged(.nominal)  // not a change
        #expect(journal.events.filter { $0.0 == .thermalChanged }.map(\.1) == ["nominal"])
    }

    @Test func aHotMacSleepsOnceTheLevelHasSettled() {
        let (controller, effects, journal) = setUp()
        keepAwakeWithTheLidClosed(controller, effects)
        #expect(controller.keepingAwakeForAgents)
        effects.context.thermalPressure = true
        controller.thermalChanged(.trapping)
        settle(effects)
        #expect(!controller.keepingAwakeForAgents)
        #expect(effects.sleepRequests == 1)
        #expect(journal.events.suffix(2).map(\.0) == [.thermalChanged, .agentsDone])
        #expect(journal.events.last?.1 == KeepAwakeEnd.heat.rawValue)
    }

    @Test func olderEntriesHaveNoLevel() throws {
        let old = Data(#"{"date":0,"kind":"sleep"}"#.utf8)
        #expect(try JSONDecoder().decode(SleepEvent.self, from: old).thermal == nil)
    }

    @Test func inTheDiagnostics() {
        let facts = HealthFacts(service: .running, status: nil, system: nil, inApplicationsFolder: true,
                                notifications: .allowed, openAtLogin: true, menuBarIconShown: true,
                                agentsMissingHooks: [])
        let event = SleepEvent(date: Date(), kind: .sleep, thermal: "heavy")
        let text = DiagnosticsReport(date: Date(), appVersion: "1", macOSVersion: "27", model: "Mac",
                                     facts: facts, events: [event], log: .success(""), thermalLevel: .trapping)
            .text(home: "/Users/someone")
        #expect(text.contains("Thermal level: trapping"))
        #expect(text.contains("sleep thermal=heavy"))
    }
}
