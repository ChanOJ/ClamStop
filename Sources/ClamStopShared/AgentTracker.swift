// Which AI coding agents are working. Ideas and lease rules adapted from clamshut
// (https://github.com/IshaanChamoli/clamshut, MIT, Copyright (c) 2026 Ishaan Chamoli; see
// THIRD_PARTY_NOTICES.md): each agent session holds a lease, opened and closed by the agent's
// own lifecycle hooks, kept alive by independent evidence of work (live subagents, transcript
// writes, CPU used by the agent's process tree) and dropped on positive evidence that nothing
// runs (process gone, grace period over after a turn, no activity for a long time).

import Foundation

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// What a hook reports, sent by `ClamStop --agent-hook <agent>` to the daemon over XPC.
public struct AgentHookMessage: Codable, Equatable, Sendable {
    public var agent: AgentKind
    /// `hook_event_name` from the agent (UserPromptSubmit, Stop, SubagentStart, ...).
    public var event: String
    public var sessionID: String
    public var transcriptPath: String?
    /// The agent process (found by walking up from the hook), for liveness and CPU checks.
    public var agentPID: Int32?
    /// Its start time (microseconds since 1970), to detect a reused PID.
    public var agentStartMicros: UInt64?

    public init(agent: AgentKind, event: String, sessionID: String, transcriptPath: String? = nil,
                agentPID: Int32? = nil, agentStartMicros: UInt64? = nil) {
        self.agent = agent
        self.event = event
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.agentPID = agentPID
        self.agentStartMicros = agentStartMicros
    }

    /// Parse the JSON an agent writes on the hook's standard input.
    public static func fromHookInput(_ data: Data, agent: AgentKind) -> AgentHookMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["hook_event_name"] as? String,
              let session = object["session_id"] as? String, !session.isEmpty else { return nil }
        return AgentHookMessage(agent: agent, event: event, sessionID: session,
                                transcriptPath: object["transcript_path"] as? String)
    }
}

/// Summary of one working session, shown in the app.
public struct AgentSessionInfo: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var since: Date
    /// Turn ended, kept a little longer in case another one starts.
    public var finishing: Bool
    public var subagents: Int

    public init(agent: AgentKind, since: Date, finishing: Bool, subagents: Int) {
        self.agent = agent
        self.since = since
        self.finishing = finishing
        self.subagents = subagents
    }
}

public struct AgentLease: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// A turn is running.
        case active
        /// The turn ended; released after the grace period unless work shows up.
        case grace
    }

    public var agent: AgentKind
    public var sessionID: String
    public var pid: Int32?
    public var pidStartMicros: UInt64?
    public var transcriptPath: String?
    public var state: State
    public var acquiredAt: Date
    /// Last evidence of work; an active lease without any for `idleTimeout` is dropped.
    public var lastActivity: Date
    public var graceStarted: Date?
    public var subagents: Int
    /// CPU seconds of the agent's process tree at the previous tick.
    public var lastCPUSeconds: Double?

    public var key: String { "\(agent.rawValue)-\(sessionID)" }
}

/// Evidence gathered by the daemon for one lease (nil = unknown, which is not evidence of death).
public struct AgentProbe: Equatable, Sendable {
    public var alive: Bool?
    /// Newest modification of the transcript or of the subagent transcripts.
    public var newestActivity: Date?
    /// Total CPU seconds of the agent's descendant processes (not the agent process itself).
    public var cpuSeconds: Double?

    public init(alive: Bool? = nil, newestActivity: Date? = nil, cpuSeconds: Double? = nil) {
        self.alive = alive
        self.newestActivity = newestActivity
        self.cpuSeconds = cpuSeconds
    }
}

/// Agent sessions and their leases. Pure logic, driven by hook messages and periodic probes.
/// Not thread-safe: call from one serial queue.
public final class AgentTracker {
    /// Kept after a turn ends, so protection does not flap between turns.
    public static let gracePeriod: TimeInterval = 90
    /// An active lease with no sign of work for this long is waiting for a person: dropped.
    public static let idleTimeout: TimeInterval = 30 * 60
    /// A transcript written this recently counts as work.
    public static let transcriptFreshness: TimeInterval = 120
    /// CPU used by the agent's child processes (tools, builds, tests) between two ticks that
    /// counts as work. The agent process itself is left out: an idle Claude Code process used
    /// 0.05 s per 15 s in one session but 0.5 to 0.7 s in another (measured 2026-11-26 and
    /// 2026-11-27), which kept the Mac awake after the agent had finished.
    public static let busyCPUSeconds: Double = 0.5
    /// In grace, transcript writes this soon after the turn ended do not count: Claude Code
    /// still appends its last lines a few milliseconds after the Stop hook (seen 2026-11-26).
    public static let graceWriteMargin: TimeInterval = 10
    /// Seconds between probes while at least one lease exists.
    public static let tickInterval: TimeInterval = 15

    public private(set) var leases: [String: AgentLease] = [:]
    private let log: (String) -> Void

    public init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    public var isWorking: Bool { !leases.isEmpty }

    public var sessions: [AgentSessionInfo] {
        leases.values.sorted { $0.acquiredAt < $1.acquiredAt }.map {
            AgentSessionInfo(agent: $0.agent, since: $0.acquiredAt, finishing: $0.state == .grace,
                             subagents: $0.subagents)
        }
    }

    public func removeAll() {
        leases.removeAll()
    }

    public func handle(_ message: AgentHookMessage, now: Date) {
        let key = "\(message.agent.rawValue)-\(message.sessionID)"
        switch message.event {
        case "UserPromptSubmit":
            var lease = leases[key] ?? AgentLease(
                agent: message.agent, sessionID: message.sessionID, pid: nil, pidStartMicros: nil,
                transcriptPath: nil, state: .active, acquiredAt: now, lastActivity: now,
                graceStarted: nil, subagents: 0, lastCPUSeconds: nil)
            if leases[key] == nil { log("agent \(message.agent.rawValue) session \(message.sessionID): turn started") }
            lease.state = .active
            lease.graceStarted = nil
            lease.lastActivity = now
            // Refresh anchors: a resumed session may run in a new process.
            if let pid = message.agentPID {
                if pid != lease.pid { lease.lastCPUSeconds = nil }
                lease.pid = pid
                lease.pidStartMicros = message.agentStartMicros
            }
            lease.transcriptPath = message.transcriptPath ?? lease.transcriptPath
            leases[key] = lease
        case "SubagentStart":
            guard var lease = leases[key] else { return }
            lease.subagents += 1
            lease.state = .active  // a subagent starting proves the session is busy
            lease.graceStarted = nil
            lease.lastActivity = now
            leases[key] = lease
        case "SubagentStop":
            guard var lease = leases[key] else { return }
            lease.subagents = max(0, lease.subagents - 1)
            lease.lastActivity = now
            leases[key] = lease
        case "Stop", "StopFailure":
            guard var lease = leases[key], lease.state == .active else { return }
            lease.state = .grace
            lease.graceStarted = now
            leases[key] = lease
            log("agent \(message.agent.rawValue) session \(message.sessionID): turn ended, grace period")
        case "SessionEnd":
            if leases.removeValue(forKey: key) != nil {
                log("agent \(message.agent.rawValue) session \(message.sessionID): session ended")
            }
        default:
            break
        }
    }

    /// Apply probe results; drop leases that are positively done.
    public func tick(now: Date, probe: (AgentLease) -> AgentProbe) {
        for (key, lease) in leases {
            let p = probe(lease)
            var next = lease
            if p.alive == false {
                leases[key] = nil
                log("agent \(lease.agent.rawValue) session \(lease.sessionID): process gone")
                continue
            }
            let cpuDelta: Double
            if let cpu = p.cpuSeconds, let last = lease.lastCPUSeconds { cpuDelta = cpu - last } else { cpuDelta = 0 }
            if let cpu = p.cpuSeconds { next.lastCPUSeconds = cpu }

            // In grace, only activity newer than the end of the turn counts: the agent writes
            // its transcript when the turn ends.
            let floor = next.state == .grace
                ? (next.graceStarted ?? now).addingTimeInterval(Self.graceWriteMargin)
                : now.addingTimeInterval(-Self.transcriptFreshness)
            let wrote = p.newestActivity.map { $0 > floor } ?? false
            let busy = next.subagents > 0 || wrote || cpuDelta > Self.busyCPUSeconds

            switch next.state {
            case .active:
                if busy {
                    next.lastActivity = now
                } else if now.timeIntervalSince(next.lastActivity) > Self.idleTimeout {
                    leases[key] = nil
                    log("agent \(lease.agent.rawValue) session \(lease.sessionID): no activity for \(Int(Self.idleTimeout / 60)) min")
                    continue
                }
            case .grace:
                if busy {
                    // Background work outlived the turn (a build, tests).
                    let reason = next.subagents > 0 ? "subagents" : wrote ? "transcript written"
                        : String(format: "CPU %.1f s in %.0f s", cpuDelta, Self.tickInterval)
                    log("agent \(lease.agent.rawValue) session \(lease.sessionID): still working (\(reason))")
                    next.state = .active
                    next.graceStarted = nil
                    next.lastActivity = now
                } else if now.timeIntervalSince(next.graceStarted ?? now) > Self.gracePeriod {
                    leases[key] = nil
                    log("agent \(lease.agent.rawValue) session \(lease.sessionID): done")
                    continue
                }
            }
            leases[key] = next
        }
    }
}
