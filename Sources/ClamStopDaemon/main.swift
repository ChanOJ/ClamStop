// ClamStop privileged daemon: sleep on lid close, delayed hibernation, XPC service for the app.
//
// Normally started by launchd (registered by the app with SMAppService.daemon).
// For manual testing, run it as root in a terminal:
//   sudo ClamStopDaemon --foreground [--delay-seconds N]
// Other commands: --restore-defaults (hibernatemode 3, cancel ClamStop wakes), --status.

import Foundation
import ClamStopShared

/// Glue between the IOKit monitor, the state machine, persistence and XPC. Main queue only.
final class DaemonService {
    let store: FileStore
    let power = SystemPower()
    let controller: PowerController
    private(set) var settings: ClamStopSettings

    init(store: FileStore, delayOverride: TimeInterval?) {
        self.store = store
        settings = store.loadSettings()
        controller = PowerController(settings: settings, effects: power, store: store, log: Log.info)
        controller.delayOverride = delayOverride
    }

    func apply(_ newSettings: ClamStopSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        store.saveSettings(newSettings)
        controller.apply(settings: newSettings)
        Log.info("settings: enabled=\(newSettings.enabled) delay=\(newSettings.hibernateDelayMinutes) min")
    }

    /// Uninstall: macOS defaults back, then delete the daemon's files.
    func restoreDefaults() {
        controller.restoreDefaults()
        store.removeAll()
        Log.info("removed \(store.directory.path)")
    }

    func status() -> DaemonStatus {
        DaemonStatus(version: ClamStopVersion.current, settings: settings, phase: controller.state.phase,
                     pendingWake: controller.state.pendingWake, lidClosed: power.isLidClosed(),
                     sleepDisabled: power.sleepDisabled, hibernateMode: power.currentHibernateMode())
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

Log.info("ClamStopDaemon \(ClamStopVersion.current) starting (pid \(getpid()), foreground=\(foreground))")
Log.info("settings: enabled=\(service.settings.enabled) delay=\(service.settings.hibernateDelayMinutes) min"
         + (delayOverride.map { ", delay override \(Int($0)) s" } ?? ""))
if service.power.sleepDisabled {
    Log.error("SleepDisabled is set (pmset disablesleep 1): lid close cannot put the Mac to sleep")
}

service.controller.start()

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
    service.controller.systemDidWake()
}
guard monitor.start() else {
    Log.error("cannot register for power notifications")
    exit(1)
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

var xpcServer: XPCServer?
if !foreground {
    xpcServer = XPCServer(service: service)
    xpcServer?.start()
}

dispatchMain()
