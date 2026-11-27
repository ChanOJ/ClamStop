import Foundation
import Testing
@testable import ClamStopShared

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let handBrake = WatchedApp(name: "HandBrake", bundlePath: "/Applications/HandBrake.app",
                                   executables: ["HandBrakeCLI"])
private let ffmpeg = WatchedApp(name: "ffmpeg", executables: ["ffmpeg"])

private func process(_ pid: Int32, _ path: String, parent: Int32 = 1, started: Date = t0 - 1000) -> ProcessTable.Entry {
    ProcessTable.Entry(pid: pid, parent: parent, startMicros: UInt64(started.timeIntervalSince1970 * 1_000_000),
                       path: path)
}

private let handBrakeProcess = process(10, "/Applications/HandBrake.app/Contents/MacOS/HandBrake")

/// An `AppTracker` with a controlled clock and CPU counters.
private final class Probe {
    let tracker = AppTracker()
    var now = t0
    var processes: [ProcessTable.Entry] = []
    var asserting: Set<Int32> = []
    var cpu: [Int32: Double] = [:]

    init(_ apps: [WatchedApp] = [handBrake]) { tracker.watch(apps) }

    @discardableResult
    func tick(after seconds: TimeInterval = AppTracker.tickInterval, adding used: [Int32: Double] = [:]) -> WatchedAppActivity.State {
        now += seconds
        for (pid, value) in used { cpu[pid, default: 0] += value }
        tracker.tick(now: now, processes: processes, asserting: asserting) { self.cpu[$0] ?? 0 }
        return tracker.activity[0].state
    }
}

@Suite struct AppTrackerTests {
    @Test func matching() {
        #expect(handBrake.matches(executablePath: "/Applications/HandBrake.app/Contents/XPCServices/x.xpc/Contents/MacOS/x"))
        #expect(handBrake.matches(executablePath: "/opt/homebrew/bin/HandBrakeCLI"))
        #expect(!handBrake.matches(executablePath: "/Applications/HandBrake.app.backup/HandBrake"))
        #expect(ffmpeg.matches(executablePath: "/opt/homebrew/Cellar/ffmpeg/7.1/bin/ffmpeg"))
        #expect(!ffmpeg.matches(executablePath: "/usr/local/bin/ffmpeg-helper"))
    }

    @Test func notRunningThenIdle() {
        let p = Probe()
        #expect(p.tick() == .notRunning)
        p.processes = [handBrakeProcess]
        p.cpu[10] = 500  // CPU used long ago does not count
        #expect(p.tick() == .idle)
        #expect(p.tick(adding: [10: 0.5]) == .idle)  // 3 % of a core
        #expect(!p.tracker.isWorking)
    }

    @Test func processorMakesItWork() {
        let p = Probe()
        p.processes = [handBrakeProcess]
        p.tick()
        #expect(p.tick(adding: [10: 1.5]) == .working)
        #expect(p.tracker.isWorking)
    }

    @Test func powerAssertionMakesItWorkAtOnce() {
        let p = Probe()
        p.processes = [handBrakeProcess]
        p.asserting = [10]
        #expect(p.tick() == .working)
    }

    @Test func someoneElsesAssertionDoesNot() {
        let p = Probe()
        p.processes = [handBrakeProcess, process(99, "/Applications/Other.app/Contents/MacOS/Other")]
        p.asserting = [99]
        #expect(p.tick() == .idle)
    }

    @Test func childProcessesCountIncludingNewOnes() {
        let p = Probe()
        p.processes = [handBrakeProcess]
        p.tick()
        // Started after the last probe, by the app: all its CPU time is recent.
        p.processes.append(process(20, "/usr/bin/encoder", parent: 10, started: p.now + 1))
        #expect(p.tick(adding: [20: 5]) == .working)
    }

    @Test func graceThenDone() {
        let p = Probe()
        p.processes = [handBrakeProcess]
        p.asserting = [10]
        p.tick()
        p.asserting = []
        #expect(p.tick(after: 15) == .finishing)
        #expect(p.tracker.isWorking)
        #expect(p.tick(after: 80) == .idle)
        #expect(!p.tracker.isWorking)
    }

    @Test func aQuitAppFinishesToo() {
        let p = Probe([ffmpeg])
        p.processes = [process(30, "/opt/homebrew/bin/ffmpeg")]
        p.asserting = [30]
        p.tick()
        p.processes = []
        #expect(p.tick() == .finishing)
        #expect(p.tick(after: AppTracker.gracePeriod) == .notRunning)
    }

    @Test func unwatchedAppsAreForgotten() {
        let p = Probe([handBrake, ffmpeg])
        p.processes = [handBrakeProcess]
        p.asserting = [10]
        p.tick()
        p.tracker.watch([ffmpeg])
        #expect(!p.tracker.isWorking)
        #expect(p.tracker.activity.map(\.name) == ["ffmpeg"])
    }

    @Test func watchedAppsSurviveEncoding() throws {
        let s = ClamStopSettings(watchedApps: [handBrake, ffmpeg])
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(ClamStopSettings.self, from: data) == s)
        #expect(try JSONDecoder().decode(ClamStopSettings.self, from: Data("{}".utf8)).watchedApps.isEmpty)
    }
}

@Suite struct AppKeepAwakeTests {
    private func controller(_ settings: ClamStopSettings = ClamStopSettings(),
                            context: PowerContext = PowerContext()) -> (PowerController, FakeEffects) {
        let effects = FakeEffects()
        effects.context = context
        let c = PowerController(settings: settings, effects: effects, store: MemoryStore())
        c.start()
        return (c, effects)
    }

    private func closeLid(_ c: PowerController, _ e: FakeEffects) {
        e.lidClosed = true
        c.lidChanged(closed: true)
    }

    @Test func aWorkingAppKeepsTheMacAwakeThenItSleeps() {
        let (c, e) = controller(context: PowerContext(onPowerAdapter: true, externalDisplay: true))
        c.appsChanged(working: true)
        #expect(e.sleepDisabled)
        closeLid(c, e)
        #expect(e.sleepRequests == 0)
        c.appsChanged(working: false)
        #expect(e.sleepRequests == 1)
        #expect(!e.sleepDisabled)
    }

    @Test func safetyGuardsApply() {
        let (c, e) = controller(context: PowerContext(onPowerAdapter: false, batteryPercent: 80))
        c.appsChanged(working: true)
        #expect(!e.sleepDisabled)
        closeLid(c, e)
        #expect(e.sleepRequests == 1)
    }

    @Test func worksWithTheAgentSwitchOff() {
        let (c, e) = controller(ClamStopSettings(keepAwakeForAgents: false))
        c.appsChanged(working: true)
        closeLid(c, e)
        #expect(e.sleepRequests == 0)
    }

    @Test func doWhatMacOSDoesWins() {
        let (c, e) = controller(ClamStopSettings(enabled: false))
        c.appsChanged(working: true)
        #expect(!e.sleepDisabled)
    }

    @Test func notPartOfThePlanWithoutSessionsAndAgents() {
        let (c, _) = controller()
        c.appsChanged(working: true)
        #expect(c.currentPlan?.action == .sleep)
    }

    @Test func restoringDefaultsForgetsTheApps() {
        let (c, e) = controller(ClamStopSettings(watchedApps: [ffmpeg]))
        c.appsChanged(working: true)
        c.restoreDefaults()
        #expect(!e.sleepDisabled)
        #expect(c.settings.watchedApps.isEmpty)
        #expect(!c.appsWorking)
    }
}
