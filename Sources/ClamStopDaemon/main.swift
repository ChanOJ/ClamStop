// ClamStop privileged daemon: sleep on lid close, delayed hibernation, XPC service for the app.
//
// Normally started by launchd (registered by the app with SMAppService.daemon).
// For manual testing, run it as root in a terminal:
//   sudo ClamStopDaemon --foreground [--delay-seconds N] [--simulate-agent SECONDS]
// (--simulate-agent: pretend an AI agent works for that long, to test keep-awake without hooks.)
// Other commands: --restore-defaults (hibernatemode 3, cancel ClamStop wakes), --status.

import Foundation
import IOKit.ps
import notify
import ClamStopShared

/// Glue between the IOKit monitor, the state machine, persistence and XPC. Main queue only.
final class DaemonService {
    let store: FileStore
    let power = SystemPower()
    let controller: PowerController
    let agents = AgentMonitor()
    let apps = AppMonitor()
    private(set) var settings: ClamStopSettings
    private(set) var sleepLog: [SleepEvent]

    init(store: FileStore, delayOverride: TimeInterval?) {
        self.store = store
        settings = store.loadSettings()
        sleepLog = store.loadSleepLog()
        controller = PowerController(settings: settings, effects: power, store: store, log: Log.info)
        controller.delayOverride = delayOverride
        controller.record = { [unowned self] kind, detail in self.record(kind, detail) }
        agents.onChange = { [unowned self] working in
            self.controller.agentsChanged(working: working)
            self.controller.reevaluate(trigger: "agent check")
        }
        apps.onChange = { [unowned self] working in
            self.controller.appsChanged(working: working)
            self.controller.reevaluate(trigger: "app check")
        }
    }

    /// Watch the chosen apps only while ClamStop is on and the app runs.
    func updateApps() {
        apps.update(watched: settings.watchedApps, active: settings.enabled && controller.appRunning)
    }

    private var appWatcher: DispatchSourceProcess?
    private var appPID: pid_t = 0

    /// The app polls its status: watch its process, and stay inactive once it ends.
    func appConnected(pid: pid_t) {
        if pid == appPID, appWatcher != nil {
            return
        }
        appWatcher?.cancel()
        appPID = pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.appPID == pid else { return }
            Log.info("app process \(pid) ended")
            self.appWatcher?.cancel()
            self.appWatcher = nil
            self.appPID = 0
            self.controller.setAppRunning(false)
            self.updateApps()
        }
        source.resume()
        appWatcher = source
        // The process may have ended before the watch started.
        if kill(pid, 0) != 0, errno == ESRCH {
            source.cancel()
            appWatcher = nil
            appPID = 0
            controller.setAppRunning(false)
            updateApps()
            return
        }
        Log.info("app process \(pid) connected")
        controller.setAppRunning(true)
        updateApps()
    }

    func externalDisplayChanged(_ connected: Bool) {
        guard connected != power.externalDisplay else { return }
        power.externalDisplay = connected
        Log.info("external display \(connected ? "connected" : "disconnected")")
        controller.conditionsChanged(trigger: "display changed")
    }

    func record(_ kind: SleepEvent.Kind, _ detail: String?) {
        let battery = SystemPower.battery()
        sleepLog = SleepLog.appending(SleepEvent(date: Date(), kind: kind, batteryPercent: battery.percent,
                                                 onPowerAdapter: battery.onPowerAdapter, detail: detail,
                                                 wakeReason: kind == .wake ? power.wakeReason.rawValue : nil),
                                      to: sleepLog)
        store.saveSleepLog(sleepLog)
    }

    func apply(_ newSettings: ClamStopSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        store.saveSettings(newSettings)
        controller.apply(settings: newSettings)
        updateApps()
        Log.info("settings: \(String(decoding: (try? JSONEncoder().encode(newSettings)) ?? Data(), as: UTF8.self))")
    }

    /// Uninstall: macOS defaults back, then delete the daemon's files.

    func restoreDefaults() {
        agents.reset()
        controller.agentsChanged(working: false)
        apps.update(watched: [], active: false)
        controller.restoreDefaults()
        store.removeAll()
        Log.info("removed \(store.directory.path)")
    }

    func status() -> DaemonStatus {
        let context = power.powerContext()
        return DaemonStatus(
            version: ClamStopVersion.current, settings: settings, phase: controller.state.phase,
            pendingWake: controller.state.pendingWake, lidClosed: power.isLidClosed(),
            sleepDisabled: power.sleepDisabled, hibernateMode: power.currentHibernateMode(),
            sleepDisabledByClamStop: controller.state.sleepDisabledByClamStop == true,
            agents: agents.tracker.sessions, keepingAwakeForAgents: controller.keepingAwakeForAgents,
            onPowerAdapter: context.onPowerAdapter, batteryPercent: context.batteryPercent,
            lastLidDecision: controller.lastLidDecision, appRunning: controller.appRunning, session: controller.session,
            notices: controller.notices, lidPlan: controller.currentPlan, apps: apps.tracker.activity)
    }
}

let arguments = CommandLine.arguments
func argumentValue(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

let foreground = arguments.contains("--foreground")
Log.mirrorToStdout = foreground || arguments.contains("--restore-defaults") || arguments.contains("--status")

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("ClamStopDaemon must run as root (sudo).\n".utf8))
    exit(1)
}

let delayOverride = argumentValue("--delay-seconds").flatMap(TimeInterval.init)
let service = DaemonService(store: FileStore(), delayOverride: delayOverride)

if arguments.contains("--restore-defaults") {
    service.restoreDefaults()
    exit(0)
}
if arguments.contains("--status") {
    let status = service.status()
    print(String(decoding: status.encoded(), as: UTF8.self))
    print("own scheduled events: \(SystemPower.ownScheduledEvents())")
    exit(0)
}

// The build of the enclosing app, to tell which one launchd runs after an update.
let build = XPCServer.containingAppURL().flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleVersion"] as? String }
Log.info("ClamStopDaemon \(ClamStopVersion.current) (build \(build ?? "?")) starting (pid \(getpid()), foreground=\(foreground))")
Log.info("settings: enabled=\(service.settings.enabled) delay=\(service.settings.hibernateDelayMinutes) min"
         + " agents=\(service.controller.settings.keepAwakeForAgents)"
         + (delayOverride.map { ", delay override \(Int($0)) s" } ?? ""))
if service.power.sleepDisabled {
    Log.error("SleepDisabled is set (pmset disablesleep 1): lid close cannot put the Mac to sleep")
}

service.controller.start()
// Inactive until the app connects (in the foreground test mode there is no app).
if foreground {
    service.updateApps()
} else {
    service.controller.setAppRunning(false)
}

let monitor = PowerEventMonitor()
monitor.onLidChange = { closed in
    Log.info("lid \(closed ? "closed" : "open") (\(service.power.wakeDescription))")
    service.controller.lidChanged(closed: closed)
}
monitor.onWillSleep = {
    Log.info("power: will sleep")
    service.controller.systemWillSleep()
}
monitor.onDidWake = {
    Log.info("power: has powered on, lid closed=\(service.power.isLidClosed()) \(service.power.wakeDescription)")
    service.controller.systemDidWake(fullWake: service.power.isFullWake)
}
guard monitor.start() else {
    Log.error("cannot register for power notifications")
    exit(1)
}

// Power adapter plugged in or unplugged (rules, battery profile, safety guards).
var powerSourceToken: Int32 = 0
notify_register_dispatch(kIOPSNotifyPowerSource, &powerSourceToken, .main) { _ in
    Log.info("power source changed, on adapter=\(SystemPower.battery().onPowerAdapter)")
    service.controller.conditionsChanged(trigger: "power source changed")
}

// Leave the system as it was on SIGTERM (unregister, shutdown) and Ctrl-C.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        Log.info("signal \(sig): restoring state and exiting")
        service.controller.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

if let seconds = argumentValue("--simulate-agent").flatMap(TimeInterval.init) {
    // Test aid: a fake agent session, ended after `seconds` (then the grace period applies).
    let session = "simulated-\(getpid())"
    service.agents.handle(AgentHookMessage(agent: .claude, event: "UserPromptSubmit", sessionID: session))
    Log.info("simulated agent working for \(Int(seconds)) s")
    DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds) {
        Log.info("simulated agent: turn ended")
        service.agents.handle(AgentHookMessage(agent: .claude, event: "Stop", sessionID: session))
    }
}

var xpcServer: XPCServer?
if !foreground {
    xpcServer = XPCServer(service: service)
    xpcServer?.start()
}

dispatchMain()
