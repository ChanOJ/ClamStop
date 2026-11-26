// Probe: does IOPMRequestSysWake (private IOKit API) with UserVisible = false give a dark wake
// (no display, no audio) on Apple Silicon, also on AC power? Run as root:
//   sudo swift spike/darkwake.swift [seconds]
// Waits for the lid to close, requests a wake after `seconds` (default 120), then sleeps.
// ClamStop must be off ("Sleep when the lid closes" unchecked) during the test.

import Foundation
import IOKit
import IOKit.pwr_mgt

let delay = TimeInterval(CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 120)
func log(_ s: String) { print("\(Date()) \(s)"); fflush(stdout) }

typealias RequestSysWake = @convention(c) (CFDictionary) -> IOReturn
guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
      let sym = dlsym(handle, "IOPMRequestSysWake") else { log("IOPMRequestSysWake not found"); exit(1) }
let requestSysWake = unsafeBitCast(sym, to: RequestSysWake.self)

let kMsgClamshell: UInt32 = 0xE0034100
var lastClosed = false
let port = IONotificationPortCreate(kIOMainPortDefault)!
IONotificationPortSetDispatchQueue(port, .main)
let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
var notifier: io_object_t = 0
IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { _, _, msg, arg in
    guard msg == kMsgClamshell else { return }
    let closed = UInt(bitPattern: arg) & 1 != 0
    defer { lastClosed = closed }
    let caps = IORegistryEntryCreateCFProperty(root, "System Capabilities" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Int ?? -1
    log("lid \(closed ? "closed" : "open") capabilities=\(caps)")
    guard closed, !lastClosed else { return }
    let date = Date().addingTimeInterval(delay)
    let request: [String: Any] = [
        "time": date,                       // kIOPMPowerEventTimeKey
        "scheduledby": "io.github.chanoj.clamstop.probe",  // kIOPMPowerEventAppNameKey
        "leeway": 0,                        // kIOPMPowerEventLeewayKey (seconds)
        "UserVisible": false,               // kIOPMPowerEventUserVisible
    ]
    let kr = requestSysWake(request as CFDictionary)
    log("IOPMRequestSysWake at \(date): \(String(format: "0x%08x", kr))")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["sleepnow"]
    try? p.run(); p.waitUntilExit()
}, nil, &notifier)
log("waiting for lid close (delay \(Int(delay)) s), uid=\(getuid())")
dispatchMain()
