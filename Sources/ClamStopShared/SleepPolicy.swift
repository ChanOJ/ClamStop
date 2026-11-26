import Foundation

/// What the daemon knows about the machine when it takes a decision.
public struct PowerContext: Equatable, Sendable {
    public var onPowerAdapter: Bool
    /// nil on a Mac without battery or when it cannot be read.
    public var batteryPercent: Int?
    /// `ProcessInfo.thermalState` is serious or critical.
    public var thermalPressure: Bool

    public init(onPowerAdapter: Bool = true, batteryPercent: Int? = nil, thermalPressure: Bool = false) {
        self.onPowerAdapter = onPowerAdapter
        self.batteryPercent = batteryPercent
        self.thermalPressure = thermalPressure
    }
}

/// What to do when the lid closes (or when re-evaluating while the lid is closed).
public enum LidDecision: Equatable, Sendable {
    /// Leave the Mac alone: ClamStop is off on this power source.
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
    /// - Parameters:
    ///   - agentsWorking: an agent session holds a lease.
    ///   - agentTimeUp: the longest time to stay awake (`maxAwakeHours`) has passed.
    public static func decide(settings: ClamStopSettings, context: PowerContext, agentsWorking: Bool,
                              agentTimeUp: Bool = false) -> LidDecision {
        guard settings.enabled else { return .leaveAlone(reason: "ClamStop off") }
        let profile = settings.profile(onPowerAdapter: context.onPowerAdapter)
        guard profile.enabled else {
            return .leaveAlone(reason: context.onPowerAdapter ? "off on power adapter" : "off on battery")
        }
        // Protecting the battery comes first.
        if settings.lowBatteryHibernation, !context.onPowerAdapter, let percent = context.batteryPercent,
           percent <= settings.lowBatteryPercent {
            return .sleep(hibernateAfter: 0, reason: "battery at \(percent) %")
        }
        if settings.keepAwakeForAgents, agentsWorking {
            // Safety guards (spec section E).
            if agentTimeUp {
                return .sleep(hibernateAfter: profile.hibernateDelay, reason: "time limit reached")
            }
            if settings.heatGuard, context.thermalPressure {
                return .sleep(hibernateAfter: profile.hibernateDelay, reason: "Mac too hot")
            }
            if !context.onPowerAdapter {
                if settings.onlyWhileCharging {
                    return .sleep(hibernateAfter: profile.hibernateDelay, reason: "on battery")
                }
                if let percent = context.batteryPercent, percent < settings.batteryFloorPercent {
                    return .sleep(hibernateAfter: profile.hibernateDelay,
                                  reason: "battery below \(settings.batteryFloorPercent) %")
                }
            }
            return .keepAwakeForAgents
        }
        return .sleep(hibernateAfter: profile.hibernateDelay, reason: "lid closed")
    }
}
