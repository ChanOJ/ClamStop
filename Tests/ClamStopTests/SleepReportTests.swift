import ClamStopAppCore
import ClamStopShared
import Foundation
import Testing

private let night = Date(timeIntervalSince1970: 1_000_000)
private let hour: TimeInterval = 3600

private func event(_ after: TimeInterval, _ kind: SleepEvent.Kind, _ battery: Int? = nil, adapter: Bool = false,
                   _ detail: String? = nil) -> SleepEvent {
    SleepEvent(date: night + after, kind: kind, batteryPercent: battery, onPowerAdapter: adapter, detail: detail)
}

private func nightOfSleep(_ length: TimeInterval = 8 * hour + 19 * 60, before: Int? = 80, after: Int? = 78,
                          adapter: Bool = false, hibernated: Bool = true) -> [SleepEvent] {
    [event(-10, .lidClosed, before, adapter: adapter), event(0, .sleep, before, adapter: adapter)]
        + (hibernated ? [event(hour, .hibernate, before, adapter: adapter)] : [])
        + [event(length, .lidOpened, after, adapter: adapter),
           event(length + 1, .wake, after, adapter: adapter, SleepLog.wakeLidOpen)]
}

private func report(_ events: [SleepEvent], at: TimeInterval = 8 * hour + 19 * 60 + 10, last: Date? = nil,
                    minimum: TimeInterval = SleepReport.minimumSleep) -> SleepReport? {
    SleepReport.latest(events: events, now: night + at, lastReported: last, minimumSleep: minimum)
}

@Suite struct SleepReportTests {
    @Test func afterANight() throws {
        let found = try #require(report(nightOfSleep()))
        #expect(found.start == night)
        #expect(found.hibernated)
        #expect(found.body == "8 h 19 min asleep · battery 80 % → 78 % (−2 %) · hibernated")
    }

    @Test func onceForEachSleep() throws {
        let first = try #require(report(nightOfSleep()))
        #expect(report(nightOfSleep(), last: first.end) == nil)
        #expect(report(nightOfSleep(), last: first.end - 0.4) == nil)
        #expect(report(nightOfSleep(), last: night - hour) != nil)
    }

    @Test func onlyLongAndRecentSleeps() {
        #expect(report(nightOfSleep(4 * hour - 60), at: 4 * hour) == nil)
        #expect(report(nightOfSleep(4 * hour), at: 4 * hour + 10) != nil)
        #expect(report(nightOfSleep(), at: 10 * hour) == nil)
        #expect(report(nightOfSleep(300), at: 310, minimum: 120) != nil)
    }

    @Test func stillAsleepOrEmpty() {
        #expect(report([event(0, .sleep, 80)]) == nil)
        #expect(report([]) == nil)
    }

    @Test func aShortNapAfterTheNightDoesNotHideIt() {
        let nap = 8 * hour + 19 * 60 + 600
        let events = nightOfSleep() + [event(nap, .sleep, 78), event(nap + 60, .wake, 78, SleepLog.wakeLidOpen)]
        #expect(report(events, at: nap + 70)?.start == night)
    }

    @Test func words() throws {
        let plugged = try #require(report(nightOfSleep(5 * hour, before: 80, after: 80, adapter: true,
                                                       hibernated: false), at: 5 * hour + 10))
        #expect(plugged.body == "5 h asleep · on power adapter, battery 80 %")
        let charged = try #require(report(nightOfSleep(5 * hour, before: 40, after: 90, hibernated: false),
                                          at: 5 * hour + 10))
        #expect(charged.body == "5 h asleep · battery 40 % → 90 %")
        let unknown = try #require(report(nightOfSleep(5 * hour, before: nil, after: nil, hibernated: false),
                                          at: 5 * hour + 10))
        #expect(unknown.body == "5 h asleep")
    }
}
