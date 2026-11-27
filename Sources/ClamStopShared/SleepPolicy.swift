import Foundation

/// What the daemon knows about the machine when it takes a decision.
public struct PowerContext: Equatable, Sendable {
    public var onPowerAdapter: Bool
    /// nil on a Mac without battery or when it cannot be read.
    public var batteryPercent: Int?
    /// `ProcessInfo.thermalState` is serious or critical.
    public var thermalPressure: Bool
    /// A screen other than the built-in one is connected.
    public var externalDisplay: Bool
    /// Local day and time, for the rules (filled in by `PowerController`).
    public var time: LocalTime?

    public init(onPowerAdapter: Bool = true, batteryPercent: Int? = nil, thermalPressure: Bool = false,
                externalDisplay: Bool = false, time: LocalTime? = nil) {
        self.onPowerAdapter = onPowerAdapter
        self.batteryPercent = batteryPercent
        self.thermalPressure = thermalPressure
        self.externalDisplay = externalDisplay
        self.time = time
    }
}

/// What to do when the lid closes (or when re-evaluating while the lid is closed).
public enum LidDecision: Equatable, Sendable {
    /// Leave the Mac alone: ClamStop is off on this power source.
    case leaveAlone(reason: String)
    /// Stay awake: an AI agent is working, a "Stay awake" session runs or a rule asks for it.
    case keepAwake
    /// Sleep, then hibernate after this many seconds (0 = hibernate now, nil = never).
    case sleep(hibernateAfter: TimeInterval?, reason: String)

    public var summary: String {
        switch self {
        case .leaveAlone(let reason): "left alone: \(reason)"
        case .keepAwake: "kept awake: agents working, session or rule"
        case .sleep(let after, let reason):
            "sleep (\(reason)), hibernate " + (after.map { $0 == 0 ? "now" : "after \(Int($0)) s" } ?? "never")
        }
    }
}

public enum SleepPolicy {
    /// - Parameters:
    ///   - agentsWorking: an agent session holds a lease.
    ///   - sessionActive: a "Stay awake" session from the menu runs (spec C1, C2).
    ///   - agentTimeUp: the longest time to stay awake (`maxAwakeHours`) has passed.
    ///   - mayStayAwake: false when the Mac is going to sleep anyway: only the delay is wanted.
    public static func decide(settings: ClamStopSettings, context: PowerContext, agentsWorking: Bool,
                              sessionActive: Bool = false, agentTimeUp: Bool = false,
                              mayStayAwake: Bool = true) -> LidDecision {
        guard settings.enabled else { return .leaveAlone(reason: "ClamStop off") }
        let plan = settings.lidPlan(for: context)
        guard plan.action != .macOS else {
            if plan.rule != nil { return .leaveAlone(reason: "rule: do what macOS does") }
            return .leaveAlone(reason: context.onPowerAdapter ? "off on power adapter" : "off on battery")
        }
        // Protecting the battery comes first.
        if settings.lowBatteryHibernation, !context.onPowerAdapter, let percent = context.batteryPercent,
           percent <= settings.lowBatteryPercent {
            return .sleep(hibernateAfter: 0, reason: "battery at \(percent) %")
        }
        let wanted = (settings.keepAwakeForAgents && agentsWorking) || sessionActive || plan.action == .stayAwake
        if mayStayAwake, wanted {
            // Safety guards (spec section E).
            if agentTimeUp {
                return .sleep(hibernateAfter: plan.hibernateDelay, reason: "time limit reached")
            }
            if settings.heatGuard, context.thermalPressure {
                return .sleep(hibernateAfter: plan.hibernateDelay, reason: "Mac too hot")
            }
            if !context.onPowerAdapter {
                if settings.onlyWhileCharging {
                    return .sleep(hibernateAfter: plan.hibernateDelay, reason: "on battery")
                }
                if let percent = context.batteryPercent, percent < settings.batteryFloorPercent {
                    return .sleep(hibernateAfter: plan.hibernateDelay,
                                  reason: "battery below \(settings.batteryFloorPercent) %")
                }
            }
            return .keepAwake
        }
        return .sleep(hibernateAfter: plan.hibernateDelay, reason: "lid closed")
    }
}
