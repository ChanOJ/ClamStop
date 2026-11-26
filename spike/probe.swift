// Verification probe for points 1 and 3: lid close detection through IOKit
// (no polling) and forced sleep despite "prevent sleep" assertions.
// Usage: probe [--sleep]   (logs to stdout; --sleep runs `pmset sleepnow` on lid close)

import Foundation
import IOKit
import IOKit.pwr_mgt

let forceSleep = CommandLine.arguments.contains("--sleep")

func log(_ s: String) {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    print("\(f.string(from: Date())) \(s)")
    fflush(stdout)
}

// kIOPMMessageClamshellStateChange = iokit_family_msg(sub_iokit_powermanagement, 0x100)
let kClamshellMsg: UInt32 = 0xE0034100
let kClamshellStateBit: UInt = 1 << 0
let kClamshellSleepBit: UInt = 1 << 1
// iokit_common_msg(x) = 0xE0000000 | x (macros are not imported into Swift)
let kMsgCanSleep: UInt32 = 0xE0000270
let kMsgWillSleep: UInt32 = 0xE0000280
let kMsgWillPowerOn: UInt32 = 0xE0000320
let kMsgHasPoweredOn: UInt32 = 0xE0000300

func clamshellClosed() -> Bool? {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(root) }
    let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return v?.takeRetainedValue() as? Bool
}

func preventingAssertions() -> [String] {
    var dict: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
          let byPid = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
    var out: [String] = []
    for (pid, list) in byPid {
        for a in list {
            let type = a["AssertType"] as? String ?? "?"
            guard type == "PreventUserIdleSystemSleep" || type == "PreventSystemSleep"
                    || type == "NoIdleSleepAssertion" else { continue }
            out.append("pid \(pid) \(type) \"\(a["AssertName"] as? String ?? "")\"")
        }
    }
    return out
}

var lastClosed = clamshellClosed() ?? false
log("start: closed=\(lastClosed) forceSleep=\(forceSleep) uid=\(getuid())")
log("assertions: \(preventingAssertions())")

// Lid notifications on IOPMrootDomain.
let port = IONotificationPortCreate(kIOMainPortDefault)!
IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
var notifier: io_object_t = 0
let kr = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { _, _, msg, arg in
    guard msg == kClamshellMsg else { return }
    let bits = UInt(bitPattern: arg)
    let closed = bits & kClamshellStateBit != 0
    let causesSleep = bits & kClamshellSleepBit != 0
    log("clamshell msg: closed=\(closed) causesSleep=\(causesSleep) registry=\(String(describing: clamshellClosed()))")
    defer { lastClosed = closed }
    guard closed, !lastClosed else { return }
    log("transition open -> closed; assertions: \(preventingAssertions())")
    if forceSleep {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        try? p.run(); p.waitUntilExit()
        log("pmset sleepnow exit=\(p.terminationStatus)")
    }
}, nil, &notifier)
log("IOServiceAddInterestNotification kr=\(kr)")

// Sleep / wake events, to see whether the sleep really happened.
var rootPort: io_connect_t = 0
var pmPort: IONotificationPortRef?
var pmNotifier: io_object_t = 0
rootPort = IORegisterForSystemPower(nil, &pmPort, { _, _, type, arg in
    switch type {
    case kMsgCanSleep: log("power: can sleep?"); IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    case kMsgWillSleep: log("power: will sleep"); IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    case kMsgWillPowerOn: log("power: will power on")
    case kMsgHasPoweredOn: log("power: has powered on, closed=\(String(describing: clamshellClosed()))")
    default: break
    }
}, &pmNotifier)
IONotificationPortSetDispatchQueue(pmPort, DispatchQueue.main)

dispatchMain()
