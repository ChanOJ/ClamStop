import Foundation

/// Something the daemon did that the user should hear about (spec H5). The daemon keeps the
/// last few in `DaemonStatus.notices`; the app turns new ones into notifications (a root daemon
/// cannot post notifications itself).
public struct Notice: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A "Stay awake" session ended on its own (time up, battery floor with the lid open).
        case sessionEnded
        /// A safety guard ended staying awake with the lid closed: the Mac went to sleep.
        case safetyStop
    }

    /// Why staying awake ended.
    public enum Reason: String, Codable, Sendable {
        case timeUp
        case maxDuration
        case heat
        case unplugged
        case batteryFloor
        case lowBattery

        /// The reason of a `LidDecision.sleep` that a safety guard took (see `SleepPolicy`).
        /// nil for an ordinary sleep ("lid closed").
        public init?(decisionReason reason: String) {
            switch reason {
            case "time limit reached": self = .maxDuration
            case "Mac too hot": self = .heat
            case "on battery": self = .unplugged
            case let r where r.hasPrefix("battery below"): self = .batteryFloor
            case let r where r.hasPrefix("battery at"): self = .lowBattery
            default: return nil
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var reason: Reason
    /// The level for the battery reasons, the hours for `maxDuration`.
    public var value: Int?

    public init(id: UUID = UUID(), date: Date, kind: Kind, reason: Reason, value: Int? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.reason = reason
        self.value = value
    }

    /// How many notices the daemon keeps.
    public static let limit = 10
}
