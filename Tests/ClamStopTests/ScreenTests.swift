import Foundation
import Testing
@testable import ClamStopShared

private final class FakeScreen: ScreenBrightness {
    var value: Float? = 0.6
    func level() -> Float? { value }
    func setLevel(_ level: Float) -> Bool {
        guard value != nil else { return false }
        value = level
        return true
    }
}

private final class MemoryLevel: SavedLevelStore {
    var savedLevel: Float?
}

private func dimmer() -> (ScreenDimmer, FakeScreen, MemoryLevel) {
    let screen = FakeScreen()
    let store = MemoryLevel()
    let dimmer = ScreenDimmer(screen: screen, store: store)
    dimmer.start(lidClosed: false)
    return (dimmer, screen, store)
}

@Suite struct ScreenDimmerTests {
    @Test func offWhileKeptAwakeThenBackToTheLevelAtClose() {
        let (d, screen, store) = dimmer()
        d.lidChanged(closed: true)
        screen.value = 0.5  // macOS lowers it once the light sensor is covered
        d.update(keptAwake: true)
        #expect(screen.value == 0)
        #expect(store.savedLevel == 0.6)
        d.lidChanged(closed: false)
        #expect(screen.value == 0.6)
        #expect(store.savedLevel == nil)
    }

    @Test func untouchedWhenTheMacGoesToSleep() {
        let (d, screen, store) = dimmer()
        d.lidChanged(closed: true)
        d.update(keptAwake: false)
        #expect(screen.value == 0.6)
        #expect(store.savedLevel == nil)
    }

    @Test func untouchedWithTheLidOpen() {
        let (d, screen, _) = dimmer()
        d.update(keptAwake: true)
        #expect(screen.value == 0.6)
    }

    @Test func anEarlierAnswerDoesNotCountForTheNextClose() {
        let (d, screen, _) = dimmer()
        d.lidChanged(closed: true)
        d.update(keptAwake: true)
        d.lidChanged(closed: false)
        d.lidChanged(closed: true)
        #expect(screen.value == 0.6)
    }

    @Test func setToZeroAgainIfMacOSRaisesItAndTheSavedLevelStays() {
        let (d, screen, store) = dimmer()
        d.lidChanged(closed: true)
        d.update(keptAwake: true)
        screen.value = 0.3
        d.update(keptAwake: true)
        #expect(screen.value == 0)
        #expect(store.savedLevel == 0.6)
    }

    @Test func retriedWhenTheScreenDoesNotAnswerAtOnce() {
        let (d, screen, store) = dimmer()
        d.lidChanged(closed: true)
        d.update(keptAwake: true)
        screen.value = nil
        d.lidChanged(closed: false)
        #expect(store.savedLevel == 0.6)
        screen.value = 0
        d.update(keptAwake: false)
        #expect(screen.value == 0.6)
    }

    @Test func aCrashIsRepairedAtTheNextStartWithTheLidOpen() {
        let screen = FakeScreen()
        screen.value = 0
        let store = MemoryLevel()
        store.savedLevel = 0.4
        ScreenDimmer(screen: screen, store: store).start(lidClosed: true)
        #expect(screen.value == 0)
        ScreenDimmer(screen: screen, store: store).start(lidClosed: false)
        #expect(screen.value == 0.4)
    }
}

@Suite struct KeepScreensOnTests {
    private func controller(_ settings: ClamStopSettings) -> (PowerController, FakeEffects) {
        let effects = FakeEffects()
        let c = PowerController(settings: settings, effects: effects, store: MemoryStore())
        c.start()
        return (c, effects)
    }

    @Test func onlyWhileASessionRuns() {
        let (c, e) = controller(ClamStopSettings(keepScreensOn: true))
        c.agentsChanged(working: true)
        #expect(!e.displaySleepPrevented)
        c.startSession(until: nil)
        #expect(e.displaySleepPrevented)
        c.stopSession()
        #expect(!e.displaySleepPrevented)
    }

    @Test func screensSleepByDefault() {
        let (c, e) = controller(ClamStopSettings())
        c.startSession(until: nil)
        #expect(!e.displaySleepPrevented)
        c.apply(settings: ClamStopSettings(keepScreensOn: true))
        #expect(e.displaySleepPrevented)
    }

    @Test func releasedWhenTheMacSleepsOrTheAppQuits() {
        let (c, e) = controller(ClamStopSettings(keepScreensOn: true))
        c.startSession(until: nil)
        c.systemWillSleep()
        #expect(!e.displaySleepPrevented)
        c.systemDidWake()
        c.startSession(until: nil)
        c.setAppRunning(false)
        #expect(!e.displaySleepPrevented)
    }

    @Test func settingSurvivesEncoding() throws {
        let s = ClamStopSettings(keepScreensOn: true)
        #expect(try JSONDecoder().decode(ClamStopSettings.self, from: JSONEncoder().encode(s)) == s)
        #expect(try JSONDecoder().decode(ClamStopSettings.self, from: Data("{}".utf8)).keepScreensOn == false)
    }
}
