import CoreGraphics
import Foundation
import IOKit
import os
import ClamStopAppCore
import ClamStopShared

private let logger = Logger(subsystem: ClamStopID.appBundleID, category: "screen")

/// The built-in screen through the private DisplayServices framework (no public API sets the
/// brightness). Full edition only: App Review rejects private API, and a Store build cannot hold
/// the lid closed anyway. Called from the app, not the daemon: it needs the user's session.
final class BuiltInScreen: ScreenBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let get: Get?
    private let set: Set?

    init() {
        #if APPSTORE
        get = nil
        set = nil
        #else
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        get = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
        set = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
        if get == nil || set == nil { logger.error("DisplayServices brightness functions not found") }
        #endif
    }

    private var display: CGDirectDisplayID? {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    func level() -> Float? {
        guard let get, let display else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? value : nil
    }

    func setLevel(_ level: Float) -> Bool {
        guard let set, let display else { return false }
        return set(display, level) == 0
    }
}

/// The level to put back, kept across a crash of the app.
final class DefaultsLevelStore: SavedLevelStore {
    var savedLevel: Float? {
        get { (UserDefaults.standard.object(forKey: DefaultsKey.savedScreenBrightness) as? NSNumber)?.floatValue }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: DefaultsKey.savedScreenBrightness)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.savedScreenBrightness)
            }
        }
    }
}

/// Lid notifications from IOKit (same message as the daemon's monitor; no privilege needed),
/// delivered on the main queue.
final class LidMonitor {
    var onChange: (Bool) -> Void = { _ in }
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    // IOKit message macros are not imported into Swift: kIOPMMessageClamshellStateChange.
    private static let clamshellStateChange: UInt32 = 0xE003_4100

    static var isLidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, message, argument in
            guard message == LidMonitor.clamshellStateChange, let context else { return }
            let monitor = Unmanaged<LidMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.onChange(UInt(bitPattern: argument) & 1 != 0)
        }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
        if result != kIOReturnSuccess { logger.error("no lid notifications: \(result)") }
    }
}
