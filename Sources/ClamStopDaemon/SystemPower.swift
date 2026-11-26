import Foundation
import IOKit
import IOKit.pwr_mgt
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
    func now() -> Date { Date() }

    func isLidClosed() -> Bool {
        Self.rootDomainProperty("AppleClamshellState") as? Bool ?? false
    }

    var sleepDisabled: Bool {
        Self.rootDomainProperty("SleepDisabled") as? Bool ?? false
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
        let (status, output) = Self.pmset(["-a", "hibernatemode", String(mode)])
        let ok = status == 0 && currentHibernateMode() == mode
        if ok {
            Log.info("hibernatemode set to \(mode)")
        } else {
            Log.error("pmset -a hibernatemode \(mode) failed: exit=\(status) \(output)")
        }
        return ok
    }

    func run(at date: Date, _ block: @escaping () -> Void) {
        let seconds = max(0, date.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds, execute: block)
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
            guard message == kMsgClamshellStateChange, let context else { return }
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
