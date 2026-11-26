import Foundation

/// What the daemon knows about the machine when it takes a decision.
public struct PowerContext: Equatable, Sendable {
    public var onPowerAdapter: Bool
    /// nil on a Mac without battery or when it cannot be read.
    public var batteryPercent: Int?
    /// External displays connected now.
    public var connectedDisplays: [String]
    /// `ProcessInfo.thermalState` is serious or critical.
    public var thermalPressure: Bool

    public init(onPowerAdapter: Bool = true, batteryPercent: Int? = nil, connectedDisplays: [String] = [],
                thermalPressure: Bool = false) {
        self.onPowerAdapter = onPowerAdapter
        self.batteryPercent = batteryPercent
        self.connectedDisplays = connectedDisplays
        self.thermalPressure = thermalPressure
    }
}

/// What to do when the lid closes (or when re-evaluating while the lid is closed).
public enum LidDecision: Equatable, Sendable {
    /// Leave the Mac alone: ClamStop is off, or an exception applies.
    case leaveAlone(reason: String)
    /// Stay awake: an AI agent is working.
    case keepAwakeForAgents
    /// Sleep, then hibernate after this many seconds (0 = hibernate now, nil = never).
    case sleep(hibernateAfter: TimeInterval?, reason: String)

    public var summary: String {
        switch self {
        case .leaveAlone(let reason): "left alone: \(reason)"
        case .keepAwakeForAgents: "kept awake: agents working"
        case .sleep(let after, let reason):
            "sleep (\(reason)), hibernate " + (after.map { $0 == 0 ? "now" : "after \(Int($0)) s" } ?? "never")
        }
    }
}

public enum SleepPolicy {
    /// On battery, stop staying awake for agents below this level (adapted from clamshut's floor).
    public static let agentBatteryFloor = 20

    /// - Parameters:
    ///   - settings: already `effective` (locked Pro features off).
    ///   - agentsWorking: an agent session holds a lease.
    ///   - agentTimeUp: the safety limit for staying awake for agents has passed.
    public static func decide(settings: ClamStopSettings, context: PowerContext, agentsWorking: Bool,
                              agentTimeUp: Bool = false, now: Date, calendar: Calendar = .current) -> LidDecision {
        guard settings.enabled else { return .leaveAlone(reason: "ClamStop off") }
        let profile = settings.profile(onPowerAdapter: context.onPowerAdapter)
        guard profile.enabled else {
            return .leaveAlone(reason: context.onPowerAdapter ? "off on power adapter" : "off on battery")
        }
        // Protecting the battery comes before every exception.
        if settings.lowBatteryHibernation, !context.onPowerAdapter, let percent = context.batteryPercent,
           percent <= settings.lowBatteryPercent {
            return .sleep(hibernateAfter: 0, reason: "battery at \(percent) %")
        }
        if settings.timeRange.applies(at: now, onPowerAdapter: context.onPowerAdapter, calendar: calendar) {
            return .leaveAlone(reason: "time range exception")
        }
        if let display = context.connectedDisplays.first(where: { settings.displayExceptions.contains($0) }) {
            return .leaveAlone(reason: "display \(display) connected")
        }
        if settings.keepAwakeForAgents, agentsWorking {
            if agentTimeUp {
                return .sleep(hibernateAfter: profile.hibernateDelay, reason: "agent time limit reached")
            }
            if context.thermalPressure {
                return .sleep(hibernateAfter: profile.hibernateDelay, reason: "thermal pressure")
            }
            if !context.onPowerAdapter, let percent = context.batteryPercent, percent < agentBatteryFloor {
                return .sleep(hibernateAfter: profile.hibernateDelay, reason: "battery below \(agentBatteryFloor) %")
            }
            return .keepAwakeForAgents
        }
        return .sleep(hibernateAfter: profile.hibernateDelay, reason: "lid closed")
    }
}
