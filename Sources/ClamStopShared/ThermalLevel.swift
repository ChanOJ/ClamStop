import Foundation

/// How warm macOS says the Mac is (`ProcessInfo.thermalState`). Apps get no temperature in
/// degrees without private interfaces, and the heat guard (spec E2) acts on these levels.
public enum ThermalLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    /// The heat guard lets the Mac sleep from this level on.
    public var isTooHot: Bool { self >= .serious }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
