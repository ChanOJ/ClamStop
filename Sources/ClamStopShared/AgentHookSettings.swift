import Foundation

/// The JSON side of installing ClamStop's hook in an agent's settings (`hooks` > event >
/// [{matcher, hooks: [{type, command}]}], the layout of Claude Code and Codex). Pure functions,
/// tested; the app does the file reading and writing.
public enum AgentHookSettings {
    public enum State: Equatable, Sendable {
        /// The agent is not installed (no settings folder).
        case notFound
        case notInstalled
        case installed
        /// Installed, but pointing to another copy of ClamStop.
        case outdated
    }

    public static func isOurs(_ command: Any?) -> Bool {
        guard let command = command as? String else { return false }
        return command.contains("ClamStop") && command.contains("--agent-hook")
    }

    public static func merging(into settings: [String: Any], command: String, events: [String]) -> [String: Any] {
        var next = removing(from: settings)  // replaces a hook pointing to another copy
        var hooks = next["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append(["matcher": "", "hooks": [["type": "command", "command": command]]])
            hooks[event] = entries
        }
        next["hooks"] = hooks
        return next
    }

    public static func removing(from settings: [String: Any]) -> [String: Any] {
        var next = settings
        guard var hooks = next["hooks"] as? [String: Any] else { return next }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = entries.compactMap { entry in
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

    public static func state(of settings: [String: Any], command: String, events: [String]) -> State {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var ours = 0
        var current = 0
        for event in events {
            let commands = (hooks[event] as? [[String: Any]] ?? [])
                .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }
            if commands.contains(where: isOurs) { ours += 1 }
            if commands.contains(command) { current += 1 }
        }
        if current == events.count { return .installed }
        return ours > 0 ? .outdated : .notInstalled
    }
}
