import Foundation
import Testing
@testable import ClamStopShared

final class FakeEffects: PowerEffects {
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var lidClosed = false
    var hibernateMode: Int? = 3
    var scheduled: [Date] = []
    var sleepRequests = 0
    var cancelAllCount = 0
    var setModeFails = false
    var timers: [(Date, () -> Void)] = []

    func now() -> Date { clock }
    func isLidClosed() -> Bool { lidClosed }
    func requestSleep(after delay: TimeInterval) { sleepRequests += 1 }
    func scheduleWake(at date: Date) -> Bool { scheduled.append(date); return true }
    func cancelWake(at date: Date) { scheduled.removeAll { $0 == date } }
    func cancelAllOwnWakes() { cancelAllCount += 1; scheduled.removeAll() }
    func currentHibernateMode() -> Int? { hibernateMode }
    func setHibernateMode(_ mode: Int) -> Bool {
        guard !setModeFails else { return false }
        hibernateMode = mode
        return true
    }
    func run(at date: Date, _ block: @escaping () -> Void) { timers.append((date, block)) }

    func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
        let due = timers.filter { $0.0 <= clock }
        timers.removeAll { $0.0 <= clock }
        due.forEach { $0.1() }
    }
}

final class MemoryStore: StateStore {
    var state = PersistedState()
    func load() -> PersistedState { state }
    func save(_ state: PersistedState) { self.state = state }
}

private func makeController(delayMinutes: Int = 10, enabled: Bool = true,
                            store: MemoryStore = MemoryStore()) -> (PowerController, FakeEffects, MemoryStore) {
    let effects = FakeEffects()
    let controller = PowerController(settings: ClamStopSettings(enabled: enabled, hibernateDelayMinutes: delayMinutes),
                                     effects: effects, store: store)
    controller.start()
    return (controller, effects, store)
}

/// Lid closes, the controller asks for sleep and the system goes to sleep.
private func closeLidAndSleep(_ c: PowerController, _ e: FakeEffects) {
    e.lidClosed = true
    c.lidChanged(closed: true)
    c.systemWillSleep()
}

@Suite struct LidTests {
    @Test func sleepsOnlyOnOpenToClosedTransition() {
        let (c, e, _) = makeController()
        e.lidClosed = true
        c.lidChanged(closed: true)
        c.lidChanged(closed: true)
        #expect(e.sleepRequests == 1)
        c.lidChanged(closed: false)
        c.lidChanged(closed: false)  // two "open" messages on wake
        #expect(e.sleepRequests == 1)
        c.lidChanged(closed: true)
        #expect(e.sleepRequests == 2)
    }

    @Test func disabledDoesNothing() {
        let (c, e, _) = makeController(enabled: false)
        closeLidAndSleep(c, e)
        #expect(e.sleepRequests == 0)
        #expect(e.scheduled.isEmpty)
        #expect(c.state.phase == .idle)
    }

    @Test func lidAlreadyClosedAtStartDoesNotSleep() {
        let effects = FakeEffects()
        effects.lidClosed = true
        let c = PowerController(settings: ClamStopSettings(), effects: effects, store: MemoryStore())
        c.start()
        c.lidChanged(closed: true)
        #expect(effects.sleepRequests == 0)
    }
}

@Suite struct HibernationTests {
    @Test func schedulesWakeAfterDelayOnLidClosedSleep() {
        let (c, e, s) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        #expect(e.scheduled.count == 1)
        #expect(abs(e.scheduled[0].timeIntervalSince(e.clock) - 600) <= 1)
        #expect(c.state.phase == .awaitingHibernation)
        #expect(s.state.pendingWake == e.scheduled[0])
    }

    @Test func noWakeWhenDelayIsZero() {
        let (c, e, _) = makeController(delayMinutes: 0)
        closeLidAndSleep(c, e)
        #expect(e.sleepRequests == 1)
        #expect(e.scheduled.isEmpty)
        #expect(c.state.phase == .idle)
    }

    @Test func noWakeWhenSleepingWithLidOpen() {
        let (c, e, _) = makeController()
        c.systemWillSleep()
        #expect(e.scheduled.isEmpty)
    }

    @Test func scheduledWakeWithLidClosedHibernatesThenRestores() {
        let (c, e, s) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        e.advance(600)
        c.systemDidWake()
        #expect(e.hibernateMode == 25)
        #expect(e.sleepRequests == 2)
        #expect(e.scheduled.isEmpty)
        #expect(c.state.phase == .hibernating)
        #expect(s.state.savedHibernateMode == 3)

        c.systemWillSleep()  // into hibernation: no new wake
        #expect(e.scheduled.isEmpty)

        e.advance(300)
        e.lidClosed = false
        c.lidChanged(closed: false)
        c.systemDidWake()  // wake from hibernation
        #expect(e.hibernateMode == 3)
        #expect(c.state == PersistedState())
    }

    @Test func slightlyEarlyScheduledWakeCountsAsScheduled() {
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        e.advance(600 - 30)
        c.systemDidWake()
        #expect(c.state.phase == .hibernating)
    }

    @Test func userWakeWithLidOpenCancelsWake() {
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        e.advance(120)
        e.lidClosed = false
        c.lidChanged(closed: false)
        c.systemDidWake()
        #expect(e.scheduled.isEmpty)
        #expect(e.hibernateMode == 3)
        #expect(c.state == PersistedState())
    }

    @Test func earlyDarkWakeKeepsPlanThenHibernatesAtDeadline() {
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        let wake = e.scheduled[0]
        e.advance(200)
        c.systemDidWake()  // maintenance wake, lid closed
        #expect(c.state.phase == .awaitingHibernation)
        #expect(e.scheduled == [wake])
        c.systemWillSleep()  // back to sleep: keep the same wake
        #expect(e.scheduled == [wake])
        e.advance(400)
        c.systemDidWake()
        #expect(c.state.phase == .hibernating)
        c.systemWillSleep()
        e.advance(PowerController.missedDeadlineGrace)  // stale timers: no effect
        #expect(c.state.phase == .hibernating)
    }

    @Test func clamshellUserSessionPastDeadlineCancelsPlan() {
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        e.advance(200)
        c.systemDidWake()  // external keyboard wake, lid closed, then the Mac stays awake
        e.advance(400 + PowerController.missedDeadlineGrace)
        #expect(c.state == PersistedState())
        #expect(e.scheduled.isEmpty)
        #expect(e.hibernateMode == 3)
    }

    @Test func lidOpenedAfterEarlyWakeCancelsPlan() {
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        e.advance(200)
        c.systemDidWake()
        e.lidClosed = false
        c.lidChanged(closed: false)
        #expect(c.state == PersistedState())
        #expect(e.scheduled.isEmpty)
    }

    @Test func hibernationThatNeverHappensIsRolledBack() {
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        e.advance(600)
        c.systemDidWake()
        #expect(e.hibernateMode == 25)
        e.advance(PowerController.hibernationTimeout)  // no sleep happened
        #expect(e.hibernateMode == 3)
        #expect(c.state == PersistedState())
    }

    @Test func keepsUserHibernateMode() {
        let (c, e, _) = makeController(delayMinutes: 10)
        e.hibernateMode = 0
        closeLidAndSleep(c, e)
        e.advance(600)
        c.systemDidWake()
        #expect(e.hibernateMode == 25)
        c.systemWillSleep()
        e.advance(300)
        c.systemDidWake()
        #expect(e.hibernateMode == 0)
    }

    @Test func failingToSetModeFallsBackToNormalSleep() {
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        e.setModeFails = true
        e.advance(600)
        c.systemDidWake()
        #expect(e.hibernateMode == 3)
        #expect(e.sleepRequests == 2)
        #expect(c.state.phase == .idle)
    }

    @Test func darkScheduledWakeHibernatesFromTimer() {
        // Apple Silicon: the scheduled wake is dark, with no wake notification at all.
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        e.advance(600)
        #expect(c.state.phase == .hibernating)
        #expect(e.hibernateMode == 25)
        #expect(e.sleepRequests == 2)
        e.advance(600)  // user wakes it from hibernation much later
        e.lidClosed = false
        c.systemDidWake()
        #expect(e.hibernateMode == 3)
        #expect(c.state == PersistedState())
    }

    @Test func lidMessageInDarkWakeAfterDeadlineHibernates() {
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        e.timers.removeAll()  // the timer did not fire (yet)
        e.advance(300)
        c.lidChanged(closed: true)  // dark wake before the deadline
        #expect(c.state.phase == .awaitingHibernation)
        e.advance(300)
        c.lidChanged(closed: true)
        #expect(c.state.phase == .hibernating)
    }

    @Test func deadlineTimerIgnoredWhenFullyAwake() {
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        e.advance(100)
        c.systemDidWake()  // keyboard wake, lid closed, user works
        e.advance(500)
        #expect(c.state.phase == .awaitingHibernation)
        #expect(e.hibernateMode == 3)
    }

    @Test func delayOverrideInSeconds() {
        let (c, e, _) = makeController(delayMinutes: 10)
        c.delayOverride = 120
        closeLidAndSleep(c, e)
        #expect(abs(e.scheduled[0].timeIntervalSince(e.clock) - 120) <= 1)
    }
}

@Suite struct RecoveryTests {
    @Test func startCleansUpAfterCrashInHibernatingPhase() {
        let store = MemoryStore()
        store.state = PersistedState(phase: .hibernating, pendingWake: nil, savedHibernateMode: 3)
        let effects = FakeEffects()
        effects.hibernateMode = 25
        effects.scheduled = [Date(timeIntervalSince1970: 1_800_000_500)]
        let c = PowerController(settings: ClamStopSettings(), effects: effects, store: store)
        c.start()
        #expect(effects.hibernateMode == 3)
        #expect(effects.scheduled.isEmpty)
        #expect(store.state == PersistedState())
    }

    @Test func startLeavesUserModeAlone() {
        let store = MemoryStore()
        let effects = FakeEffects()
        effects.hibernateMode = 25  // set by the user, not by ClamStop
        let c = PowerController(settings: ClamStopSettings(), effects: effects, store: store)
        c.start()
        #expect(effects.hibernateMode == 25)
        #expect(effects.cancelAllCount == 1)
    }

    @Test func stopCancelsPendingWake() {
        let (c, e, s) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        c.stop()
        #expect(e.scheduled.isEmpty)
        #expect(s.state == PersistedState())
    }

    @Test func restoreDefaultsForcesMode3() {
        let (c, e, _) = makeController()
        e.hibernateMode = 25
        c.restoreDefaults()
        #expect(e.hibernateMode == 3)
        #expect(e.scheduled.isEmpty)
    }

    @Test func disablingWhileAwaitingDropsPlan() {
        let (c, e, _) = makeController(delayMinutes: 10)
        closeLidAndSleep(c, e)
        c.apply(settings: ClamStopSettings(enabled: false, hibernateDelayMinutes: 10))
        #expect(e.scheduled.isEmpty)
        #expect(c.state.phase == .idle)
    }
}

@Suite struct ModelTests {
    @Test func delayIsClamped() {
        #expect(ClamStopSettings(hibernateDelayMinutes: -5).hibernateDelayMinutes == 0)
        #expect(ClamStopSettings(hibernateDelayMinutes: 100_000).hibernateDelayMinutes == ClamStopSettings.maxDelayMinutes)
    }

    @Test func defaults() {
        let s = ClamStopSettings()
        #expect(s.enabled)
        #expect(s.hibernateDelayMinutes == 10)
    }

    @Test func statusRoundTrip() {
        let status = DaemonStatus(version: "1", settings: ClamStopSettings(), phase: .awaitingHibernation,
                                  pendingWake: Date(timeIntervalSince1970: 1_800_000_000), lidClosed: true,
                                  sleepDisabled: false, hibernateMode: 3)
        #expect(DaemonStatus.decode(status.encoded()) == status)
    }
}
