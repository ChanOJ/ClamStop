import Foundation
import os
import ClamStopShared

private let logger = Logger(subsystem: ClamStopID.appBundleID, category: "lock")

/// Locks the screen at once (spec F2), from the app: the root daemon is not in the user's
/// session. macOS has no public call for this: `SACLockScreenImmediate` is private, so the Store
/// edition has no such setting. If it disappears or fails, the screens are put to sleep, which
/// locks after the delay set in System Settings > Lock Screen.
enum ScreenLocker {
#if !APPSTORE
    private typealias LockNow = @convention(c) () -> Int32
    private static let lockNow: LockNow? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
                                  RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockNow.self)
    }()
#endif

    static func lock() {
#if !APPSTORE
        if let lockNow {
            let result = lockNow()
            logger.notice("lid closed: screen lock asked, result \(result)")
            if result == 0 { return }
        }
#endif
        logger.notice("lid closed: putting the screens to sleep to lock")
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        do {
            try pmset.run()
        } catch {
            logger.error("pmset displaysleepnow: \(error.localizedDescription, privacy: .public)")
        }
    }
}
