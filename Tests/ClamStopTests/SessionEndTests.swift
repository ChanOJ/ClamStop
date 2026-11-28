import ClamStopDiagnostics
import ClamStopShared
import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_000_000)

private func session(minutes: Double?) -> StayAwakeSession {
    StayAwakeSession(started: start, until: minutes.map { start + $0 * 60 })
}

private func due(_ minutes: Double?, at: Double, reminded: Date? = nil) -> Bool {
    SessionEnd.reminderIsDue(session(minutes: minutes), now: start + at * 60, reminded: reminded)
}

@Suite struct SessionEndTests {
    @Test func fiveMinutesBeforeTheEnd() {
        #expect(!due(30, at: 24.9))
        #expect(due(30, at: 25))
        #expect(due(30, at: 29.9))
        #expect(!due(30, at: 30))
    }

    @Test func notForShortOrOpenEndedSessions() {
        #expect(!due(5, at: 1))
        #expect(!due(10, at: 6))
        #expect(due(15, at: 11))
        #expect(!due(nil, at: 600))
    }

    @Test func onceForEachEnd() {
        #expect(!due(30, at: 26, reminded: start + 30 * 60))
        // The end moved: remind again.
        #expect(due(60, at: 56, reminded: start + 30 * 60))
    }

    @Test func thirtyMinutesMore() {
        #expect(SessionEnd.extended(session(minutes: 30), now: start + 26 * 60) == start + 60 * 60)
        #expect(SessionEnd.extended(session(minutes: 30), now: start + 31 * 60) == start + 61 * 60)
        #expect(SessionEnd.extended(nil, now: start) == start + 30 * 60)
        #expect(SessionEnd.extended(session(minutes: nil), now: start) == nil)
    }
}

@Suite struct LidLockTests {
    private func update(_ lock: inout LidLock, closed: Bool = true, awake: Bool = true, external: Bool = false,
                        enabled: Bool = true) -> Bool {
        lock.update(lidClosed: closed, keptAwake: awake, externalDisplay: external, enabled: enabled)
    }

    @Test func onceForEachClosing() {
        var lock = LidLock()
        #expect(update(&lock))
        #expect(!update(&lock))
        #expect(!update(&lock, closed: false))
        #expect(update(&lock))
    }

    @Test func onlyWhenAskedAndKeptAwake() {
        var lock = LidLock()
        #expect(!update(&lock, enabled: false))
        #expect(!update(&lock, awake: false))
        #expect(!update(&lock, closed: false))
        // The service answers a moment after the lid closed.
        #expect(update(&lock))
    }

    @Test func notWithAnExternalScreenUntilItGoes() {
        var lock = LidLock()
        #expect(!update(&lock, external: true))
        #expect(update(&lock))
    }
}
