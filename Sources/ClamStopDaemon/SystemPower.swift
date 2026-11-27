import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import ClamStopShared

// IOKit message macros are not imported into Swift; values from IOMessage.h / IOPM.h.
// iokit_common_msg(x) = 0xE0000000 | x
private let kMsgCanSystemSleep: UInt32 = 0xE000_0270
private let kMsgSystemWillSleep: UInt32 = 0xE000_0280
private let kMsgSystemWillPowerOn: UInt32 = 0xE000_0320
private let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300
// kIOPMMessageClamshellStateChange = iokit_family_msg(sub_iokit_powermanagement, 0x100)
private let kMsgClamshellStateChange: UInt32 = 0xE003_4100
private let kClamshellStateBit: UInt = 1 << 0
/// `kIOPMAutoWake`
private let kAutoWakeType = "wake"

/// Real `PowerEffects`: IOKit and pmset. Must be used from the main queue.
final class SystemPower: PowerEffects {
    /// A screen other than the built-in one is connected, as the app reports it: a root daemon
    /// has no window server connection to ask.
    var externalDisplay = false

    func now() -> Date { Date() }

    func isLidClosed() -> Bool {
        Self.rootDomainProperty("AppleClamshellState") as? Bool ?? false
    }

    var sleepDisabled: Bool {
        Self.rootDomainProperty("SleepDisabled") as? Bool ?? false
    }

    /// "System Capabilities" bit 1 (kIOPMSystemCapabilityGraphics): set on a full wake, clear on a dark wake.
    var isFullWake: Bool {
        guard let caps = Self.rootDomainProperty("System Capabilities") as? Int else { return true }
        return caps & 0x2 != 0
    }

    /// Diagnostics: why and how the Mac last woke. "System Capabilities" bit 1 = graphics (full wake).
    var wakeDescription: String {
        let reason = Self.rootDomainProperty("Wake Reason") as? String ?? "?"
        let type = Self.rootDomainProperty("Wake Type") as? String ?? "?"
        let caps = Self.rootDomainProperty("System Capabilities") as? Int ?? -1
        return "reason=\"\(reason)\" type=\"\(type)\" capabilities=\(caps)"
    }

    func requestSleep(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.sleepDisabled {
                Log.error("SleepDisabled is set (pmset disablesleep 1): the Mac will not sleep")
            }
            // Verified on Apple Silicon: sleeps in clamshell mode despite "prevent sleep" assertions.
            let (status, output) = Self.pmset(["sleepnow"])
            Log.info("pmset sleepnow exit=\(status) \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    func scheduleWake(at date: Date) -> Bool {
        let kr = IOPMSchedulePowerEvent(date as CFDate, ClamStopID.daemonLabel as CFString, kAutoWakeType as CFString)
        if kr != kIOReturnSuccess {
            Log.error("IOPMSchedulePowerEvent failed: \(String(format: "0x%08x", kr))")
        }
        return kr == kIOReturnSuccess
    }

    func cancelWake(at date: Date) {
        let kr = IOPMCancelScheduledPowerEvent(date as CFDate, ClamStopID.daemonLabel as CFString, kAutoWakeType as CFString)
        Log.info("cancel wake at \(date): \(kr == kIOReturnSuccess ? "ok" : String(format: "0x%08x", kr))")
    }

    func cancelAllOwnWakes() {
        for event in Self.ownScheduledEvents() {
            guard let time = event["time"] as? Date, let type = event["eventtype"] as? String else { continue }
            let kr = IOPMCancelScheduledPowerEvent(time as CFDate, ClamStopID.daemonLabel as CFString, type as CFString)
            Log.info("cancel stray \(type) at \(time): \(kr == kIOReturnSuccess ? "ok" : String(format: "0x%08x", kr))")
        }
    }

    static func ownScheduledEvents() -> [[String: Any]] {
        guard let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return events.filter { $0["scheduledby"] as? String == ClamStopID.daemonLabel }
    }

    func currentHibernateMode() -> Int? {
        let (status, output) = Self.pmset(["-g"])
        guard status == 0 else { return nil }
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[0] == "hibernatemode" { return Int(fields[1]) }
        }
        return nil
    }

    @discardableResult
    func setHibernateMode(_ mode: Int) -> Bool {
        // Seen on 2026-11-26 during a scheduled wake: pmset exited 0 but `pmset -g` still showed
        // the old value right after. Re-read for a moment, then set again once.
        for attempt in 1...2 {
            let (status, output) = Self.pmset(["-a", "hibernatemode", String(mode)])
            for _ in 0..<5 {
                if status == 0, currentHibernateMode() == mode {
                    Log.info("hibernatemode set to \(mode)" + (attempt > 1 ? " (second attempt)" : ""))
                    return true
                }
                usleep(200_000)
            }
            Log.error("pmset -a hibernatemode \(mode) not applied (attempt \(attempt)): exit=\(status) "
                      + "read back \(currentHibernateMode().map(String.init) ?? "nil") \(output)")
        }
        return false
    }

    func run(at date: Date, _ block: @escaping () -> Void) {
        let seconds = max(0, date.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds, execute: block)
    }

    func powerContext() -> PowerContext {
        let battery = Self.battery()
        let thermal = ProcessInfo.processInfo.thermalState
        return PowerContext(onPowerAdapter: battery.onPowerAdapter, batteryPercent: battery.percent,
                            thermalPressure: thermal == .serious || thermal == .critical,
                            externalDisplay: externalDisplay)
    }

    func isSleepDisabled() -> Bool { sleepDisabled }

    private var idleAssertion: IOPMAssertionID?

    func setIdleSleepPrevented(_ prevented: Bool) {
        if prevented, idleAssertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "ClamStop: Stay awake session" as CFString, &id)
            if result == kIOReturnSuccess {
                idleAssertion = id
                Log.info("idle sleep assertion created")
            } else {
                Log.error("cannot create the idle sleep assertion: \(result)")
            }
        } else if !prevented, let id = idleAssertion {
            IOPMAssertionRelease(id)
            idleAssertion = nil
            Log.info("idle sleep assertion released")
        }
    }

    @discardableResult
    func setSleepDisabled(_ disabled: Bool) -> Bool {
        let (status, output) = Self.pmset(["-a", "disablesleep", disabled ? "1" : "0"])
        for _ in 0..<5 {
            if status == 0, sleepDisabled == disabled { return true }
            usleep(200_000)
        }
        Log.error("pmset -a disablesleep \(disabled ? 1 : 0): exit=\(status) \(output)")
        return false
    }

    /// Power source and battery level (IOKit power sources; works as root, no polling).
    static func battery() -> (onPowerAdapter: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (true, nil) }
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onAdapter = source != kIOPMBatteryPowerKey
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (onAdapter, nil)
        }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (onAdapter, current * 100 / max)
        }
        return (onAdapter, nil)
    }

    /// Processes keeping the Mac from sleeping with a power assertion, their own or one held for
    /// them (coreaudiod holds one for each app playing sound).
    static func processesPreventingSleep() -> Set<Int32> {
        var reference: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&reference) == kIOReturnSuccess,
              let byProcess = reference?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let blocking: Set<String> = [kIOPMAssertPreventUserIdleSystemSleep, "PreventSystemSleep"]
        var result: Set<Int32> = []
        for (owner, assertions) in byProcess {
            for assertion in assertions {
                // The "true" type resolves legacy names (NoIdleSleepAssertion).
                guard let type = (assertion["AssertionTrueType"] ?? assertion["AssertType"]) as? String,
                      blocking.contains(type),
                      (assertion["AssertLevel"] as? Int ?? 0) > 0 else { continue }
                result.insert((assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? owner.int32Value)
            }
        }
        return result
    }

    // MARK: Helpers

    static func rootDomainProperty(_ key: String) -> Any? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    @discardableResult
    static func pmset(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Lid and sleep/wake notifications from IOKit, delivered on the main queue.
final class PowerEventMonitor {
    var onLidChange: (Bool) -> Void = { _ in }
    var onWillSleep: () -> Void = {}
    var onDidWake: () -> Void = {}

    private var lidPort: IONotificationPortRef?
    private var lidNotifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0

    func start() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()

        // Lid: interest notification on IOPMrootDomain (no polling).
        guard let lidPort = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        self.lidPort = lidPort
        IONotificationPortSetDispatchQueue(lidPort, .main)
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let kr = IOServiceAddInterestNotification(lidPort, root, kIOGeneralInterest, { context, _, message, argument in
            guard message == kMsgClamshellStateChange, let context else {
                Log.info("rootDomain message \(String(format: "0x%08x", message))")  // diagnostics
                return
            }
            let monitor = Unmanaged<PowerEventMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.onLidChange(UInt(bitPattern: argument) & kClamshellStateBit != 0)
        }, context, &lidNotifier)
        guard kr == kIOReturnSuccess else {
            Log.error("IOServiceAddInterestNotification failed: \(kr)")
            return false
        }

        // Sleep / wake.
        rootPort = IORegisterForSystemPower(context, &powerPort, { context, _, message, argument in
            guard let context else { return }
            let monitor = Unmanaged<PowerEventMonitor>.fromOpaque(context).takeUnretainedValue()
            switch message {
            case kMsgCanSystemSleep:
                IOAllowPowerChange(monitor.rootPort, Int(bitPattern: argument))
            case kMsgSystemWillSleep:
                // Schedule the hibernation wake before letting the system go.
                monitor.onWillSleep()
                IOAllowPowerChange(monitor.rootPort, Int(bitPattern: argument))
            case kMsgSystemWillPowerOn:
                Log.info("power: will power on")
            case kMsgSystemHasPoweredOn:
                monitor.onDidWake()
            default:
                break
            }
        }, &powerNotifier)
        guard rootPort != 0, let powerPort else {
            Log.error("IORegisterForSystemPower failed")
            return false
        }
        IONotificationPortSetDispatchQueue(powerPort, .main)
        return true
    }
}
