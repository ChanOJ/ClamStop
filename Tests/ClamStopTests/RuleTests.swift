import Foundation
import Testing
@testable import ClamStopShared

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// Friday 2027-01-15, 08:00 UTC (`FakeEffects` starts there).
private let friday = 6
private let saturday = 7

private let deskRule = Rule(power: .adapter, display: .connected, action: .stayAwake)
private let nightRule = Rule(time: TimeWindow(start: 23 * 60, end: 7 * 60), action: .sleep, hibernateDelayMinutes: 0)

private let desk = PowerContext(onPowerAdapter: true, externalDisplay: true)
private let onBattery = PowerContext(onPowerAdapter: false, batteryPercent: 80)

private func controller(_ settings: ClamStopSettings,
                        context: PowerContext = PowerContext()) -> (PowerController, FakeEffects) {
    let effects = FakeEffects()
    effects.context = context
    let c = PowerController(settings: settings, effects: effects, store: MemoryStore())
    c.calendar = utc
    c.start()
    return (c, effects)
}

private func closeLid(_ c: PowerController, _ e: FakeEffects) {
    e.lidClosed = true
    c.lidChanged(closed: true)
}

private func change(_ c: PowerController, _ e: FakeEffects, _ context: PowerContext) {
    e.context = context
    c.conditionsChanged(trigger: "test")
    e.advance(PowerController.settleDelay)
}

@Suite struct TimeWindowTests {
    @Test func sameDay() {
        let window = TimeWindow(start: 540, end: 600, days: [friday])
        #expect(window.contains(LocalTime(weekday: friday, minute: 540)))
        #expect(window.contains(LocalTime(weekday: friday, minute: 599)))
        #expect(!window.contains(LocalTime(weekday: friday, minute: 600)))
        #expect(!window.contains(LocalTime(weekday: saturday, minute: 550)))
    }

    @Test func pastMidnightBelongsToTheStartDay() {
        let window = TimeWindow(start: 1380, end: 420, days: [friday])
        #expect(window.contains(LocalTime(weekday: friday, minute: 1380)))
        #expect(window.contains(LocalTime(weekday: saturday, minute: 419)))
        #expect(!window.contains(LocalTime(weekday: saturday, minute: 420)))
        #expect(!window.contains(LocalTime(weekday: friday, minute: 100)))
        #expect(!window.contains(LocalTime(weekday: saturday, minute: 1380)))
    }

    @Test func sundayLooksBackToSaturday() {
        let window = TimeWindow(start: 1380, end: 420, days: [saturday])
        #expect(window.contains(LocalTime(weekday: 1, minute: 10)))
    }

    @Test func equalTimesCoverTheWholeDay() {
        let window = TimeWindow(start: 0, end: 0, days: [friday])
        #expect(window.contains(LocalTime(weekday: friday, minute: 1439)))
        #expect(!window.contains(LocalTime(weekday: saturday, minute: 0)))
    }
}

@Suite struct RulePolicyTests {
    private func decide(_ s: ClamStopSettings, _ context: PowerContext) -> LidDecision {
        SleepPolicy.decide(settings: s, context: context, agentsWorking: false)
    }

    @Test func everyConditionMustHold() {
        #expect(deskRule.matches(desk))
        #expect(!deskRule.matches(PowerContext(onPowerAdapter: true)))
        #expect(!deskRule.matches(PowerContext(onPowerAdapter: false, externalDisplay: true)))
        #expect(Rule(display: .notConnected).matches(PowerContext()))
    }

    @Test func invalidOrDisabledRulesNeverMatch() {
        #expect(!Rule().matches(desk))
        #expect(!Rule(enabled: false, power: .adapter).matches(desk))
        #expect(!Rule(time: TimeWindow(start: 0, end: 0, days: [])).isValid)
        // Without a local time a time condition cannot be checked.
        #expect(!nightRule.matches(desk))
    }

    @Test func firstMatchingRuleWins() {
        let sleepAtDesk = Rule(display: .connected, action: .macOS)
        let s = ClamStopSettings(rules: [deskRule, sleepAtDesk])
        #expect(decide(s, desk) == .keepAwake)
        #expect(decide(s, PowerContext(onPowerAdapter: false, externalDisplay: true))
            == .leaveAlone(reason: "rule: do what macOS does"))
        #expect(decide(s, PowerContext()) == .sleep(hibernateAfter: 3600, reason: "lid closed"))
    }

    @Test func ruleWinsOverTheBatterySettings() {
        let s = ClamStopSettings(separateBatterySettings: true,
                                 battery: PowerSourceProfile(enabled: false),
                                 rules: [Rule(power: .battery, action: .sleep, hibernateDelayMinutes: 5)])
        #expect(decide(s, onBattery) == .sleep(hibernateAfter: 300, reason: "lid closed"))
    }

    @Test func masterSwitchOffIgnoresRules() {
        let s = ClamStopSettings(enabled: false, rules: [deskRule])
        #expect(decide(s, desk) == .leaveAlone(reason: "ClamStop off"))
    }

    @Test func safetyGuardsWinOverStayAwake() {
        let stay = Rule(display: .connected, action: .stayAwake)
        let battery = PowerContext(onPowerAdapter: false, batteryPercent: 80, externalDisplay: true)
        #expect(decide(ClamStopSettings(rules: [stay]), battery) == .sleep(hibernateAfter: 3600, reason: "on battery"))
        #expect(decide(ClamStopSettings(onlyWhileCharging: false, rules: [stay]), battery) == .keepAwake)
        var hot = desk
        hot.thermalPressure = true
        #expect(decide(ClamStopSettings(rules: [stay]), hot) == .sleep(hibernateAfter: 3600, reason: "Mac too hot"))
        let low = ClamStopSettings(lowBatteryHibernation: true, lowBatteryPercent: 30, onlyWhileCharging: false,
                                   rules: [stay])
        var empty = battery
        empty.batteryPercent = 20
        #expect(decide(low, empty) == .sleep(hibernateAfter: 0, reason: "battery at 20 %"))
    }

    @Test func rulesSurviveEncoding() throws {
        let s = ClamStopSettings(rules: [deskRule, nightRule])
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(ClamStopSettings.self, from: data) == s)
        #expect(try JSONDecoder().decode(ClamStopSettings.self, from: Data("{}".utf8)).rules.isEmpty)
    }
}

@Suite struct RuleKeepAwakeTests {
    @Test func theCurrentPlanSaysWhatTheGuardsLeave() {
        let stay = Rule(display: .connected, action: .stayAwake)
        let (c, e) = controller(ClamStopSettings(hibernateDelayMinutes: 5, rules: [stay]), context: desk)
        #expect(c.currentPlan?.action == .stayAwake)
        e.context = PowerContext(onPowerAdapter: false, batteryPercent: 80, externalDisplay: true)
        #expect(c.currentPlan?.action == .sleep)
        #expect(c.currentPlan?.hibernateDelayMinutes == 5)
        #expect(c.currentPlan?.rule?.id == stay.id)
        c.setAppRunning(false)
        #expect(c.currentPlan == nil)
    }

    @Test func screenAndPowerNeedNoSleepPrevention() {
        let (c, e) = controller(ClamStopSettings(rules: [deskRule]), context: desk)
        #expect(!e.sleepDisabled)  // macOS stays awake by itself
        closeLid(c, e)
        #expect(e.sleepRequests == 0)
        #expect(c.keepingAwakeForAgents)
        #expect(!e.sleepDisabled)
    }

    @Test func withoutScreenSleepIsPreventedBeforeTheLidCloses() {
        let rule = Rule(power: .adapter, action: .stayAwake)
        let (c, e) = controller(ClamStopSettings(rules: [rule]))
        c.setAppRunning(false)
        #expect(!e.sleepDisabled)
        c.setAppRunning(true)
        #expect(e.sleepDisabled)
        closeLid(c, e)
        #expect(e.sleepDisabled)
        #expect(e.sleepRequests == 0)
    }

    @Test func unpluggingTheScreenSleepsAfterItSettled() {
        let rule = Rule(display: .connected, action: .stayAwake)
        let (c, e) = controller(ClamStopSettings(rules: [rule]), context: desk)
        closeLid(c, e)
        e.context = PowerContext()
        c.conditionsChanged(trigger: "test")
        #expect(e.sleepRequests == 0)
        e.advance(PowerController.settleDelay)
        #expect(e.sleepRequests == 1)
        #expect(!e.sleepDisabled)
        c.systemWillSleep()
        #expect(c.state.phase == .awaitingHibernation)
    }

    @Test func aScreenThatComesBackChangesNothing() {
        let rule = Rule(display: .connected, action: .stayAwake)
        let (c, e) = controller(ClamStopSettings(rules: [rule]), context: desk)
        closeLid(c, e)
        e.context = PowerContext()
        c.conditionsChanged(trigger: "gone")
        e.advance(1)
        e.context = desk
        c.conditionsChanged(trigger: "back")
        e.advance(PowerController.settleDelay)
        #expect(e.sleepRequests == 0)
        #expect(c.keepingAwakeForAgents)
    }

    @Test func leftToMacOSThenUnpluggedSleeps() {
        let rule = Rule(power: .adapter, action: .macOS)
        let (c, e) = controller(ClamStopSettings(rules: [rule]), context: desk)
        closeLid(c, e)
        #expect(e.sleepRequests == 0)
        change(c, e, PowerContext(onPowerAdapter: false, batteryPercent: 80, externalDisplay: true))
        #expect(e.sleepRequests == 1)
    }

    @Test func pluggingInWhileAwakeAndForcedToSleepOnceIsNotRepeated() {
        let (c, e) = controller(ClamStopSettings(rules: [deskRule]), context: onBattery)
        closeLid(c, e)
        #expect(e.sleepRequests == 1)
        c.systemWillSleep()
        c.systemDidWake()  // external keyboard, lid still closed: the user is using the Mac
        change(c, e, PowerContext(onPowerAdapter: false, batteryPercent: 70))
        #expect(e.sleepRequests == 1)
    }

    @Test func endOfTheTimeWindowSleeps() {
        let rule = Rule(time: TimeWindow(start: 8 * 60, end: 8 * 60 + 2), action: .stayAwake)
        let (c, e) = controller(ClamStopSettings(rules: [rule]))
        c.reevaluate(trigger: "app connected")
        #expect(e.sleepDisabled)
        closeLid(c, e)
        e.advance(60)
        #expect(e.sleepRequests == 0)
        e.advance(60)
        #expect(e.sleepRequests == 1)
        #expect(!e.sleepDisabled)
        #expect(c.notices.isEmpty)
    }

    @Test func startOfTheTimeWindowPreventsSleep() {
        let rule = Rule(time: TimeWindow(start: 8 * 60 + 1, end: 9 * 60), action: .stayAwake)
        let (c, e) = controller(ClamStopSettings(rules: [rule]))
        #expect(!e.sleepDisabled)
        e.advance(60)
        #expect(e.sleepDisabled)
        #expect(c.currentPlan?.rule?.id == rule.id)
        #expect(c.currentPlan?.action == .stayAwake)
    }

    @Test func heatEndsItAndNotifies() {
        let rule = Rule(power: .adapter, action: .stayAwake)
        let (c, e) = controller(ClamStopSettings(rules: [rule]))
        closeLid(c, e)
        e.context.thermalPressure = true
        e.advance(60)
        #expect(e.sleepRequests == 1)
        #expect(!e.sleepDisabled)
        #expect(c.notices.map(\.reason) == [.heat])
        e.context.thermalPressure = false
        e.advance(60)
        #expect(!e.sleepDisabled)  // not again before the lid opens
    }

    @Test func noSleepPreventionDuringADarkWake() {
        let rule = Rule(power: .adapter, action: .stayAwake)
        let (c, e) = controller(ClamStopSettings(rules: [rule]), context: onBattery)
        closeLid(c, e)
        c.systemWillSleep()
        e.context = PowerContext()  // plugged in while asleep
        c.systemDidWake(fullWake: false)
        e.advance(60)
        #expect(!e.sleepDisabled)
    }

    @Test func sleepNowThenWakeWithTheLidOpenAppliesTheRuleAgain() {
        let rule = Rule(power: .adapter, action: .stayAwake)
        let (c, e) = controller(ClamStopSettings(rules: [rule]))
        c.sleepNow()
        #expect(!e.sleepDisabled)
        c.systemWillSleep()
        c.systemDidWake()
        #expect(e.sleepDisabled)
        #expect(c.state.phase == .idle)
    }

    @Test func appleMenuSleepWithTheLidClosedStillHibernates() {
        let (c, e) = controller(ClamStopSettings(hibernateDelayMinutes: 10, rules: [deskRule]), context: desk)
        closeLid(c, e)
        c.systemWillSleep()
        #expect(e.scheduled == [e.clock.addingTimeInterval(600)])
    }

    @Test func restoringDefaultsDropsTheRules() {
        let rule = Rule(power: .adapter, action: .stayAwake)
        let (c, e) = controller(ClamStopSettings(rules: [rule]))
        c.restoreDefaults()
        e.advance(120)
        c.conditionsChanged(trigger: "test")
        e.advance(PowerController.settleDelay)
        #expect(!e.sleepDisabled)
    }

    @Test func changingSettingsWithTheLidClosedDoesNotForceSleepLater() {
        let (c, e) = controller(ClamStopSettings(rules: [Rule(power: .adapter, action: .macOS)]), context: desk)
        closeLid(c, e)
        c.apply(settings: ClamStopSettings())
        change(c, e, desk)
        #expect(e.sleepRequests == 0)
    }
}
