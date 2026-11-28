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

@Suite struct ServiceRepairTests {
    /// Switch states as seen every second, then whether a repair is due.
    private func repair(_ wait: inout ServiceWait, at seconds: TimeInterval) -> Bool {
        wait.repairIsDue(now: t0 + seconds)
    }

    @Test func soonAfterAnApprovalAndOnlyOnce() {
        var wait = ServiceWait()
        wait.switchIsOff(now: t0)
        // Seen every second while the first request is still out.
        wait.switchIsOn(now: t0 + 60)
        let early = repair(&wait, at: 60 + ServiceWait.patienceAfterApproval - 1)
        wait.switchIsOn(now: t0 + 61)
        let due = repair(&wait, at: 60 + ServiceWait.patienceAfterApproval)
        wait.switchIsOn(now: t0 + 66)
        let again = repair(&wait, at: 72)
        #expect([early, due, again] == [false, true, false])
    }

    @Test func aSwitchThatShowsOnForAMomentIsNotAnApproval() {
        // Right after a registration: off, on for a few seconds, off again (seen on macOS 27.2).
        var wait = ServiceWait()
        wait.switchIsOff(now: t0)
        wait.switchIsOn(now: t0 + 2)
        let during = repair(&wait, at: 12)
        wait.switchIsOff(now: t0 + 15)
        wait.switchIsOn(now: t0 + 90)
        let afterApproval = repair(&wait, at: 90 + ServiceWait.patienceAfterApproval)
        #expect([during, afterApproval] == [false, true])
    }

    @Test func theSwitchMovingAfterOurOwnRepairIsNotAnApproval() {
        var wait = ServiceWait()
        wait.switchIsOff(now: t0)
        wait.switchIsOn(now: t0 + 60)
        let first = repair(&wait, at: 60 + ServiceWait.patienceAfterApproval)
        wait.switchIsOff(now: t0 + 66)
        wait.switchIsOn(now: t0 + 78)
        let soon = repair(&wait, at: 84)
        #expect([first, soon] == [true, false])
    }

    @Test func aSilentServiceIsRegisteredAgainAFewTimes() {
        var wait = ServiceWait()
        var due: [TimeInterval] = []
        for second in stride(from: 0.0, through: 200, by: 1) {
            wait.switchIsOn(now: t0 + second)
            if repair(&wait, at: second) { due.append(second) }
        }
        #expect(due.count == ServiceWait.unattendedRepairs)
        #expect(due.first == ServiceWait.patience)
    }

    @Test func anAnswerStartsOver() {
        var wait = ServiceWait()
        wait.switchIsOn(now: t0)
        wait.update(waiting: false, now: t0 + 1)
        let due = repair(&wait, at: 60)
        #expect(!due)
    }
}

