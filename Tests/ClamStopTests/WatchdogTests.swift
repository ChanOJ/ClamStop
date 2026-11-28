import Foundation
import Testing
@testable import ClamStopShared

/// The daemon's watchdog over the app (spec E4).
@Suite struct WatchdogTests {
    private func setUp(context: PowerContext = PowerContext()) -> (PowerController, FakeEffects) {
        let effects = FakeEffects()
        effects.context = context
        let controller = PowerController(settings: ClamStopSettings(), effects: effects, store: MemoryStore())
        controller.start()
        return (controller, effects)
    }

    /// Let `seconds` pass, firing the timers as they come due; the app reports when `reporting`.
    private func pass(_ seconds: Int, _ controller: PowerController, _ effects: FakeEffects, reporting: Bool = false) {
        for _ in 0..<(seconds / 5) {
            if reporting { controller.appHeartbeat() }
            effects.clock += 5
            let due = effects.timers.filter { $0.0 <= effects.clock }
            effects.timers.removeAll { $0.0 <= effects.clock }
            due.forEach { $0.1() }
        }
    }

    private func closeLid(_ controller: PowerController, _ effects: FakeEffects) {
        effects.lidClosed = true
        controller.lidChanged(closed: true)
    }

    @Test func aSilentAppLosesItsSessionAfter30Seconds() {
        let (controller, effects) = setUp()
        var told = 0
        controller.onAppUnresponsive = { told += 1 }
        controller.appHeartbeat()
        controller.startSession(until: nil)
        pass(30, controller, effects)  // the first check still sees the last report
        #expect(controller.session != nil)
        pass(5, controller, effects)
        #expect(controller.session == nil)
        #expect(!controller.appRunning)
        #expect(controller.appUnresponsive)
        #expect(told == 1)
        #expect(effects.sleepRequests == 0)  // lid open
    }

    @Test func reportsKeepTheSession() {
        let (controller, effects) = setUp()
        controller.appHeartbeat()
        controller.startSession(until: nil)
        pass(120, controller, effects, reporting: true)
        #expect(controller.session != nil)
    }

    @Test func theNextReportMakesClamStopActiveAgain() {
        let (controller, effects) = setUp()
        controller.appHeartbeat()
        controller.startSession(until: nil)
        pass(60, controller, effects)
        controller.appHeartbeat()
        #expect(controller.appRunning)
        #expect(!controller.appUnresponsive)
        controller.startSession(until: nil)
        pass(60, controller, effects)
        #expect(!controller.appRunning)  // watched again
    }

    @Test func nothingHeldNothingWatched() {
        let (controller, effects) = setUp()
        controller.appHeartbeat()
        pass(120, controller, effects)
        #expect(controller.appRunning)
    }

    @Test func withoutAnyReportTheAppIsNotWatched() {
        let (controller, effects) = setUp()
        controller.startSession(until: nil)
        pass(120, controller, effects)
        #expect(controller.session != nil)
    }

    @Test func timeAsleepDoesNotCount() {
        let (controller, effects) = setUp()
        controller.appHeartbeat()
        controller.startSession(until: nil)
        controller.systemWillSleep()
        controller.startSession(until: nil)  // still held while not fully awake
        pass(120, controller, effects)
        #expect(controller.appRunning)
    }

    @Test func aClosedLidSleepsAndTheJournalSaysWhy() {
        let (controller, effects) = setUp()
        var ends: [String?] = []
        controller.record = { kind, detail in if kind == .keepAwakeEnded { ends.append(detail) } }
        controller.appHeartbeat()
        controller.startSession(until: nil)
        closeLid(controller, effects)
        let before = effects.sleepRequests
        pass(40, controller, effects)
        #expect(effects.sleepRequests == before + 1)
        #expect(ends == [KeepAwakeEnd.appUnresponsive.rawValue])
    }

    @Test func quittingWithTheLidClosedSleepsToo() {
        let (controller, effects) = setUp()
        var ends: [String?] = []
        controller.record = { kind, detail in if kind == .keepAwakeEnded { ends.append(detail) } }
        controller.startSession(until: nil)
        closeLid(controller, effects)
        let before = effects.sleepRequests
        controller.setAppRunning(false)
        #expect(effects.sleepRequests == before + 1)
        #expect(ends == [KeepAwakeEnd.appQuit.rawValue])
    }

    @Test func aScreenAndThePowerAdapterLeaveMacOSInCharge() {
        let (controller, effects) = setUp(context: PowerContext(onPowerAdapter: true, externalDisplay: true))
        controller.startSession(until: nil)
        closeLid(controller, effects)
        let before = effects.sleepRequests
        controller.setAppRunning(false)
        #expect(effects.sleepRequests == before)
    }
}
