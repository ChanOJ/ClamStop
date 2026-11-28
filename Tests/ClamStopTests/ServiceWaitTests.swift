import Foundation
import Testing
@testable import ClamStopShared

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let delay = ServiceWait.reminderDelay

@Suite struct ServiceWaitTests {
    /// `reminderIsDue` mutates, which `#expect` cannot do in place.
    private func due(_ wait: inout ServiceWait, off: Bool = true, at date: Date) -> Bool {
        wait.reminderIsDue(switchOff: off, now: date)
    }

    private func waiting() -> ServiceWait {
        var wait = ServiceWait()
        wait.update(waiting: true, now: t0)
        return wait
    }

    @Test func relaxedWhileTheServiceAnswers() {
        #expect(ServiceWait().interval(now: t0) == ServiceWait.relaxedInterval)
    }

    @Test func eagerForTwoDelaysThenRelaxed() {
        var wait = waiting()
        wait.update(waiting: true, now: t0 + delay)  // later updates do not restart the wait
        #expect(wait.interval(now: t0 + 2 * delay - 1) == ServiceWait.eagerInterval)
        #expect(wait.interval(now: t0 + 2 * delay) == ServiceWait.relaxedInterval)
    }

    @Test func oneReminderAfterTheDelayOnlyWithTheSwitchOff() {
        var wait = waiting()
        let early = due(&wait, at: t0 + delay - 1)
        let switchOn = due(&wait, off: false, at: t0 + delay)
        let first = due(&wait, at: t0 + delay)
        let second = due(&wait, at: t0 + 3 * delay)
        #expect([early, switchOn, first, second] == [false, false, true, false])
    }

    @Test func eagerAgainWhenTheUserActs() {
        var wait = waiting()
        wait.userIsActing(now: t0 + 5 * delay)
        #expect(wait.interval(now: t0 + 5 * delay + 1) == ServiceWait.eagerInterval)
        #expect(wait.interval(now: t0 + 6 * delay) == ServiceWait.relaxedInterval)
    }

    @Test func anAnswerStartsOver() {
        var wait = waiting()
        let first = due(&wait, at: t0 + delay)
        wait.update(waiting: false, now: t0 + delay)
        #expect(wait.interval(now: t0 + delay) == ServiceWait.relaxedInterval)
        wait.update(waiting: true, now: t0 + 10 * delay)
        #expect(wait.interval(now: t0 + 10 * delay) == ServiceWait.eagerInterval)
        let again = due(&wait, at: t0 + 11 * delay)
        #expect(first && again)
    }
}
