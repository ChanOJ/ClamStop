import Foundation
import notify

/// How warm the Mac is: macOS's thermal pressure levels (`libkern/OSThermalNotification.h`).
/// Apps get no temperature in degrees without private interfaces.
///
/// `ProcessInfo.thermalState` is coarser: it says "fair" for both `moderate` and `heavy` (seen on
/// an M5 Pro, 2026-11-28).
public enum ThermalLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case nominal
    case moderate
    /// A large load, lid closed or not: macOS slows the processors down and the level holds.
    case heavy
    case trapping
    case sleeping

    /// Darwin notification that carries the level as its state
    /// (`kOSThermalNotificationPressureLevelName`).
    public static let pressureNotification = "com.apple.system.thermalpressurelevel"

    /// From the notification's state: 0 to 4 on macOS.
    public init(pressure: UInt64) {
        self = Self.allCases[Int(min(pressure, UInt64(Self.allCases.count - 1)))]
    }

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .moderate
        case .serious: self = .trapping
        case .critical: self = .sleeping
        @unknown default: self = .sleeping
        }
    }

    /// The warmer of the two readings, so that a Mac that only fills one of them is still seen.
    public init(pressure: UInt64?, state: ProcessInfo.ThermalState) {
        self = max(pressure.map(ThermalLevel.init(pressure:)) ?? .nominal, ThermalLevel(state))
    }

    /// The level now. Reading it also turns on `ProcessInfo`'s change notification.
    public static var current: ThermalLevel {
        ThermalLevel(pressure: readPressure(), state: ProcessInfo.processInfo.thermalState)
    }

    private static func readPressure() -> UInt64? {
        var token: Int32 = 0
        guard notify_register_check(pressureNotification, &token) == NOTIFY_STATUS_OK else { return nil }
        defer { notify_cancel(token) }
        var level: UInt64 = 0
        return notify_get_state(token, &level) == NOTIFY_STATUS_OK ? level : nil
    }

    /// "Very hot": the heat guard lets the Mac sleep from this level on (spec E2).
    public var isTooHot: Bool { self >= .trapping }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
