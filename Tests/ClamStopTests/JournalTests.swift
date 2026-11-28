@testable import ClamStopAppCore
@testable import ClamStopShared
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func event(_ seconds: TimeInterval, _ kind: SleepEvent.Kind, battery: Int = 80,
                   detail: String? = nil) -> SleepEvent {
    SleepEvent(date: t0 + seconds, kind: kind, batteryPercent: battery, detail: detail)
}

@Suite struct WakeReasonTests {
    /// Strings seen in `pmset -g log` on a MacBook Pro M5 Pro, macOS 27.2.
    @Test(arguments: [
        ("lid IOPortFeatureLDCM.measurement", WakeReason.lid),
        ("smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty RTP.multi-touch", .lid),
        ("MTP.DOCK.CHANNELS.AP0.IRQ nub-spmi-a1.0x0B RTP.keyboard", .keyboard),
        ("smc.sysState.Wake(0x70070000) SMC.OutboxNotEmpty RTP.multi-touch", .trackpad),
        ("smc.sysState.Wake(0x70070000) acdetach ATC0.PMGRCIOWakeup", .powerAdapter),
        ("smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty centauri-alpha E_RX_IP_PACKET ARPT", .network),
        ("NUB.SPMI0Sw3IRQ nub-spmi0.0x02 rtc", .scheduled),
        ("something.new", .other),
    ])
    func categories(reason: String, expected: WakeReason) {
        #expect(WakeReason(reason: reason) == expected)
    }

    @Test func userActivityFromTheType() {
        #expect(WakeReason(reason: "something.new", type: "UserActivity Assertion") == .user)
    }
}

@Suite struct JournalTests {
    @Test func newestFirstByDay() {
        let days = SleepLog.journal(from: [event(0, .lidClosed), event(86_400, .lidOpened)], calendar: utc)
        #expect(days.count == 2)
        #expect(days.first?.entries.map(\.event.kind) == [.lidOpened])
    }

    @Test func theWakeAfterTheLidOpeningSumsUpTheSleep() throws {
        let events = [event(0, .sleep, battery: 80), event(60, .hibernate), event(3600, .lidOpened, battery: 77),
                      event(3601, .wake, battery: 77, detail: SleepLog.wakeLidOpen)]
        let entries = SleepLog.journal(from: events, calendar: utc).flatMap(\.entries)
        #expect(entries.map { $0.asleep != nil } == [true, false, false, false])
        let sleep = try #require(entries.first?.asleep)
        #expect(sleep.batteryUsed == 3)
        #expect(sleep.hibernated)
    }

    @Test func aLidOpeningAloneSumsUpTheSleep() {
        let events = [event(0, .sleep), event(3600, .lidOpened), event(9000, .sleep)]
        let entries = SleepLog.journal(from: events, calendar: utc).flatMap(\.entries)
        #expect(entries.map { $0.asleep != nil } == [false, true, false])
    }

    @Test func oldEntriesStillDecode() throws {
        let json = Data(#"[{"date":0,"kind":"wake","detail":"lid open"}]"#.utf8)
        let events = try JSONDecoder().decode([SleepEvent].self, from: json)
        #expect(events.first?.wakeReason == nil)
    }
}

@Suite struct JournalRecordingTests {
    private final class Log {
        var entries: [(kind: SleepEvent.Kind, detail: String?)] = []
        func details(_ kind: SleepEvent.Kind) -> [String?] { entries.filter { $0.kind == kind }.map(\.detail) }
    }

    private func setUp() -> (PowerController, FakeEffects, Log) {
        let effects = FakeEffects()
        let controller = PowerController(settings: ClamStopSettings(keepAwakeForAgents: true), effects: effects,
                                         store: MemoryStore())
        controller.start()
        let log = Log()
        controller.record = { log.entries.append(($0, $1)) }
        return (controller, effects, log)
    }

    @Test func whyItStaysAwakeAndWhyItStops() {
        let (controller, effects, log) = setUp()
        controller.agentsChanged(working: true)
        effects.lidClosed = true
        controller.lidChanged(closed: true)
        controller.agentsChanged(working: false)
        #expect(log.details(.keptAwakeForAgents) == [KeepAwakeReason.agents.rawValue])
        #expect(log.details(.agentsDone) == [KeepAwakeEnd.finished.rawValue])
    }

    @Test func lidOpeningIsRecordedOnceWhenTheWakeComesFirst() {
        let (controller, effects, log) = setUp()
        effects.lidClosed = true
        controller.lidChanged(closed: true)
        controller.systemWillSleep()
        effects.lidClosed = false
        controller.systemDidWake()
        controller.lidChanged(closed: false)
        #expect(log.entries.map(\.kind) == [.lidClosed, .sleep, .lidOpened, .wake])
    }
}
