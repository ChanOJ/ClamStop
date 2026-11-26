// Mac App Store feasibility spike: what can a sandboxed app (no root helper) do?
//
//   StoreSpike --probe          non-destructive checks (no sleep, nothing left behind)
//   StoreSpike --lid iokit      on lid close, sleep with IOPMSleepSystem(IOPMFindPowerManagement())
//   StoreSpike --lid pmset      on lid close, spawn /usr/bin/pmset sleepnow
//
// Logs go to stdout and to <container>/spike.log (NSHomeDirectory() is the container when sandboxed).

import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

var signalSources: [DispatchSourceSignal] = []
var heartbeat: DispatchSourceTimer?

let args = CommandLine.arguments
let logURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("spike.log")

func log(_ s: String) {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line = "\(f.string(from: Date())) \(s)\n"
    print(line, terminator: ""); fflush(stdout)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: false, encoding: .utf8)
    }
}

func kr(_ r: kern_return_t) -> String {
    r == KERN_SUCCESS ? "success" : String(format: "0x%08x (%@)", r, String(cString: mach_error_string(r)))
}

let kClamshellMsg: UInt32 = 0xE0034100
let kMsgCanSleep: UInt32 = 0xE0000270
let kMsgWillSleep: UInt32 = 0xE0000280
let kMsgHasPoweredOn: UInt32 = 0xE0000300

func rootDomain() -> io_service_t {
    IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
}

func clamshellClosed() -> Bool? {
    let root = rootDomain(); defer { IOObjectRelease(root) }
    return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool
}

func run(_ path: String, _ a: [String]) -> String {
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = a
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "spawn failed: \(error)" }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return "exit=\(p.terminationStatus) out=\(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
}

func header() {
    let env = ProcessInfo.processInfo.environment
    log("uid=\(getuid()) sandboxed=\(env["APP_SANDBOX_CONTAINER_ID"] != nil) container=\(env["APP_SANDBOX_CONTAINER_ID"] ?? "-") home=\(NSHomeDirectory())")
}

// MARK: - Lid + power notifications

var lastClosed = false
var notifyPort: IONotificationPortRef?
var lidNotifier: io_object_t = 0
var pmRoot: io_connect_t = 0
var pmPort: IONotificationPortRef?
var pmNotifier: io_object_t = 0

func registerNotifications(onClose: @escaping () -> Void) {
    lastClosed = clamshellClosed() ?? false
    notifyPort = IONotificationPortCreate(kIOMainPortDefault)
    IONotificationPortSetDispatchQueue(notifyPort, .main)
    closeHandler = onClose
    let r = IOServiceAddInterestNotification(notifyPort, rootDomain(), kIOGeneralInterest, { _, _, msg, arg in
        guard msg == kClamshellMsg else { return }
        let closed = UInt(bitPattern: arg) & 1 != 0
        log("lid message: closed=\(closed)")
        defer { lastClosed = closed }
        if closed && !lastClosed { closeHandler?() }
    }, nil, &lidNotifier)
    log("IOServiceAddInterestNotification(IOPMrootDomain): \(kr(r))")

    pmRoot = IORegisterForSystemPower(nil, &pmPort, { _, _, type, arg in
        switch type {
        case kMsgCanSleep: IOAllowPowerChange(pmRoot, Int(bitPattern: arg))
        case kMsgWillSleep: log("power: will sleep"); IOAllowPowerChange(pmRoot, Int(bitPattern: arg))
        case kMsgHasPoweredOn: log("power: has powered on, closed=\(String(describing: clamshellClosed()))")
        default: break
        }
    }, &pmNotifier)
    log("IORegisterForSystemPower: \(pmRoot != 0 ? "success" : "FAILED (0)")")
    if pmPort != nil { IONotificationPortSetDispatchQueue(pmPort, .main) }
}
var closeHandler: (() -> Void)?

func sleepIOKit() {
    let fb = IOPMFindPowerManagement(kIOMainPortDefault)
    guard fb != 0 else { log("IOPMFindPowerManagement: FAILED (0)"); return }
    let r = IOPMSleepSystem(fb)
    log("IOPMSleepSystem: \(kr(r))")
    IOServiceClose(fb)
}

// MARK: - Modes

header()
if args.contains("--probe") {
    log("AppleClamshellState read: \(String(describing: clamshellClosed()))")
    registerNotifications(onClose: {})

    let fb = IOPMFindPowerManagement(kIOMainPortDefault)
    log("IOPMFindPowerManagement (RootDomainUserClient open): \(fb != 0 ? "success" : "FAILED (0)")")
    if fb != 0 { IOServiceClose(fb) }

    // Assertion creation (keep-awake feature) is allowed for normal apps; check sandbox.
    var aid: IOPMAssertionID = 0
    let ar = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                         IOPMAssertionLevel(kIOPMAssertionLevelOn), "StoreSpike test" as CFString, &aid)
    log("IOPMAssertionCreateWithName: \(kr(ar))"); if ar == KERN_SUCCESS { IOPMAssertionRelease(aid) }

    // Scheduled wake (needed for delayed hibernation). Far future, cancelled right after.
    let when = Date(timeIntervalSinceNow: 30 * 86400).timeIntervalSinceReferenceDate.rounded()
    let date = CFDateCreate(nil, when)!
    let sr = IOPMSchedulePowerEvent(date, "io.github.chanoj.clamstop.storespike" as CFString, kIOPMAutoWake as CFString)
    log("IOPMSchedulePowerEvent(wake): \(kr(sr))")
    if sr == KERN_SUCCESS {
        log("IOPMCancelScheduledPowerEvent: \(kr(IOPMCancelScheduledPowerEvent(date, "io.github.chanoj.clamstop.storespike" as CFString, kIOPMAutoWake as CFString)))")
    }

    // Hibernation mode needs root (pmset -a hibernatemode): tested by spawning pmset below.
    log("spawn /usr/bin/pmset -g: \(run("/usr/bin/pmset", ["-g"]).prefix(80))")
    log("spawn /usr/bin/pmset -a hibernatemode 3 (no-op value): \(run("/usr/bin/pmset", ["-a", "hibernatemode", "3"]))")
    log("spawn /usr/bin/pmset sched cancelall-test (-g sched): \(run("/usr/bin/pmset", ["-g", "sched"]).prefix(120))")
    log("probe done")
    exit(0)
}

if let i = args.firstIndex(of: "--lid"), i + 1 < args.count {
    let method = args[i + 1]
    registerNotifications {
        log("transition open -> closed, sleeping with \(method)")
        if method == "pmset" { log("pmset sleepnow: \(run("/usr/bin/pmset", ["sleepnow"]))") } else { sleepIOKit() }
    }
    log("waiting for lid close (Ctrl-C to stop)")
    dispatchMain()
}

// MARK: - Stay awake with the lid closed (no root)
//   --awake assertions   hold PreventSystemSleep + PreventUserIdleSystemSleep assertions
//   --awake clamshell    RootDomainUserClient kPMSetClamshellSleepState (12) = 1, reset to 0 on exit
//   --clamshell-reset    set kPMSetClamshellSleepState back to 0 and exit

let kPMSetClamshellSleepState: UInt32 = 12

func setClamshellSleepDisabled(_ disabled: Bool) -> kern_return_t {
    let fb = IOPMFindPowerManagement(kIOMainPortDefault)
    guard fb != 0 else { return KERN_FAILURE }
    defer { IOServiceClose(fb) }
    var input: UInt64 = disabled ? 1 : 0
    return IOConnectCallScalarMethod(fb, kPMSetClamshellSleepState, &input, 1, nil, nil)
}

func powerSource() -> String {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return "?" }
    return type as String
}

if args.contains("--clamshell-reset") {
    log("kPMSetClamshellSleepState(0): \(kr(setClamshellSleepDisabled(false)))")
    exit(0)
}

if args.contains("--clamshell-probe") {
    log("kPMSetClamshellSleepState(1): \(kr(setClamshellSleepDisabled(true)))")
    log("kPMSetClamshellSleepState(0): \(kr(setClamshellSleepDisabled(false)))")
    exit(0)
}

if let i = args.firstIndex(of: "--awake"), i + 1 < args.count {
    let method = args[i + 1]
    var ids: [IOPMAssertionID] = []
    if method == "assertions" {
        for type in ["PreventSystemSleep", kIOPMAssertionTypePreventUserIdleSystemSleep] {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "StoreSpike lid-closed test" as CFString, &id)
            log("assertion \(type): \(kr(r))"); ids.append(id)
        }
    } else {
        log("kPMSetClamshellSleepState(1): \(kr(setClamshellSleepDisabled(true)))")
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                log("signal \(sig): kPMSetClamshellSleepState(0): \(kr(setClamshellSleepDisabled(false)))")
                exit(0)
            }
            src.resume(); signalSources.append(src)
        }
    }
    registerNotifications(onClose: {})
    // Heartbeat: proves the Mac stayed awake (a gap means it slept).
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: 15)
    timer.setEventHandler { log("heartbeat power=\(powerSource()) closed=\(String(describing: clamshellClosed()))") }
    timer.resume(); heartbeat = timer
    log("holding (\(method)); Ctrl-C to stop")
    dispatchMain()
}

print("usage: StoreSpike --probe | --lid iokit|pmset | --awake assertions|clamshell | --clamshell-probe | --clamshell-reset")
exit(2)
