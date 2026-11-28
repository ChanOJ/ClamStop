import ClamStopShared
import Foundation

/// The JSON side of installing ClamStop's hook in an agent's settings. Pure functions, tested;
/// the app does the file reading and writing.
public enum AgentHookSettings {
    public enum State: Equatable, Sendable {
        /// The agent is not installed (no settings folder).
        case notFound
        case notInstalled
        case installed
        /// Installed, but pointing to another copy of ClamStop.
        case outdated
    }

    /// Where an agent expects its hooks in the settings file.
    public enum Layout: Equatable, Sendable {
        /// `hooks` > event > [{matcher, hooks: [{type, command}]}] (Claude Code, Codex, Gemini CLI).
        case grouped
        /// `hooks` > event > [{command}], with a version (Cursor).
        case flat
        /// A file of ClamStop's own: `hooks` > event > [{type, bash, timeoutSec}], with a
        /// version (GitHub Copilot CLI).
        case ownFile
        /// A hook named "clamstop" at the top level: event > [{type, command, timeout}]
        /// (Antigravity).
        case named
    }

    public static let hookName = "clamstop"
    private static let timeoutSeconds = 5

    public static func isOurs(_ command: Any?) -> Bool {
        guard let command = command as? String else { return false }
        return command.contains("ClamStop") && command.contains("--agent-hook")
    }

    /// - Parameter command: the command to run for an event.
    public static func merging(into settings: [String: Any], layout: Layout = .grouped, events: [String],
                               command: (String) -> String) -> [String: Any] {
        var next = removing(from: settings, layout: layout)  // replaces a hook pointing to another copy
        if layout == .named {
            var hook: [String: Any] = [:]
            for event in events {
                hook[event] = [["type": "command", "command": command(event), "timeout": timeoutSeconds] as [String: Any]]
            }
            next[hookName] = hook
            return next
        }
        var hooks = next["hooks"] as? [String: Any] ?? [:]
        for event in events {
            let entry: [String: Any] = switch layout {
            case .grouped: ["matcher": "", "hooks": [["type": "command", "command": command(event)]]]
            case .flat, .named: ["command": command(event)]
            case .ownFile: ["type": "command", "bash": command(event), "timeoutSec": timeoutSeconds]
            }
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [entry]
        }
        next["hooks"] = hooks
        if layout != .grouped, next["version"] == nil { next["version"] = 1 }
        return next
    }

    public static func removing(from settings: [String: Any], layout: Layout = .grouped) -> [String: Any] {
        var next = settings
        if layout == .named {
            if let hook = next[hookName] as? [String: Any], hook.keys.contains(where: { event in
                commands(in: settings, layout: layout, event: event).contains(where: isOurs)
            }) {
                next[hookName] = nil
            }
            return next
        }
        guard var hooks = next["hooks"] as? [String: Any] else { return next }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = entries.compactMap { entry in
                if layout != .grouped {
                    return isOurs(entry[layout == .ownFile ? "bash" : "command"]) ? nil : entry
                }
                guard let list = entry["hooks"] as? [[String: Any]] else { return entry }
                let filtered = list.filter { !isOurs($0["command"]) }
                if filtered.isEmpty { return nil }
                var copy = entry
                copy["hooks"] = filtered
                return copy
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        next["hooks"] = hooks.isEmpty ? nil : hooks
        return next
    }

    /// Nothing but a version number is left: a file of ClamStop's own can be deleted.
    public static func isEmpty(_ settings: [String: Any]) -> Bool {
        settings.keys.allSatisfy { $0 == "version" }
    }

    public static func state(of settings: [String: Any], layout: Layout = .grouped, events: [String],
                             command: (String) -> String) -> State {
        var ours = 0
        var current = 0
        for event in events {
            let found = commands(in: settings, layout: layout, event: event)
            if found.contains(where: isOurs) { ours += 1 }
            if found.contains(command(event)) { current += 1 }
        }
        if current == events.count { return .installed }
        return ours > 0 ? .outdated : .notInstalled
    }

    /// Every command the settings run for an event.
    static func commands(in settings: [String: Any], layout: Layout, event: String) -> [String] {
        let parent = settings[layout == .named ? hookName : "hooks"] as? [String: Any] ?? [:]
        var entries = parent[event] as? [[String: Any]] ?? []
        if layout == .grouped { entries = entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] } }
        return entries.compactMap { $0[layout == .ownFile ? "bash" : "command"] as? String }
    }
}

/// One agent's hooks: the settings file, the events to follow and the command to run.
public struct AgentHookTarget: Sendable {
    public let agent: AgentKind
    /// Settings file, relative to the home folder.
    public let file: String
    /// Any of these (relative to the home folder) shows that the agent is on this Mac.
    public let markers: [String]
    public let layout: AgentHookSettings.Layout
    public let events: [String]
    /// The agent does not write the event name on standard input: it goes on the command line.
    public var passesEvent = false

    public func command(executable: String, event: String) -> String {
        // The shell reads these four even between double quotes.
        let quoted = executable.reduce(into: "") { result, character in
            if "\\\"$`".contains(character) { result.append("\\") }
            result.append(character)
        }
        return "\"\(quoted)\" --agent-hook \(agent.rawValue)" + (passesEvent ? " \(event)" : "")
    }

    /// Whether this copy of the app may repoint hooks on its own: only an installed one, not one
    /// run from a disk image, a download or a build folder.
    public static func mayRepointHooks(toAppAt path: String, home: String) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// - Parameter exists: whether a path relative to the home folder exists.
    public func isFound(exists: (String) -> Bool) -> Bool {
        if markers.contains(where: exists) { return true }
        // Gemini CLI and Antigravity share `~/.gemini`: without any sign of Antigravity, the
        // folder is Gemini CLI's.
        return agent == .gemini && exists(".gemini") && !Self.antigravity.markers.contains(where: exists)
    }

    private static let antigravity = AgentHookTarget(
        agent: .antigravity, file: ".gemini/config/hooks.json",
        markers: [".gemini/config", ".gemini/antigravity", ".gemini/antigravity-cli"],
        layout: .named, events: ["PreInvocation", "Stop"], passesEvent: true)

    /// - Claude Code: also used by the Claude desktop app's Code sessions.
    /// - Antigravity: the command line tool and the app read the same file.
    public static let all: [AgentHookTarget] = [
        AgentHookTarget(agent: .claude, file: ".claude/settings.json", markers: [".claude"], layout: .grouped,
                        events: ["UserPromptSubmit", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "SessionEnd"]),
        AgentHookTarget(agent: .codex, file: ".codex/hooks.json", markers: [".codex"], layout: .grouped,
                        events: ["UserPromptSubmit", "Stop", "SubagentStart", "SubagentStop", "SessionEnd"]),
        AgentHookTarget(agent: .gemini, file: ".gemini/settings.json", markers: [".gemini/settings.json"],
                        layout: .grouped, events: ["BeforeAgent", "AfterAgent", "SessionEnd"]),
        antigravity,
        // No subagent events: `subagentStart` asks for a permission, and a wrong reply blocks it.
        AgentHookTarget(agent: .cursor, file: ".cursor/hooks.json", markers: [".cursor"], layout: .flat,
                        events: ["beforeSubmitPrompt", "stop", "sessionEnd"]),
        AgentHookTarget(agent: .copilot, file: ".copilot/hooks/clamstop.json", markers: [".copilot"],
                        layout: .ownFile, events: ["userPromptSubmitted", "agentStop", "sessionEnd"], passesEvent: true),
    ]
}
