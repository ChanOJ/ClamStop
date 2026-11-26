import Foundation
import ClamStopShared

/// Adds ClamStop's hook to the AI agents' settings, and removes it. Approach adapted from
/// clamshut (https://github.com/IshaanChamoli/clamshut, MIT, see THIRD_PARTY_NOTICES.md): merge,
/// never replace; keep a backup; idempotent; absolute paths; other hooks are left untouched.
///
/// - Claude Code: `~/.claude/settings.json` (applies to the CLI and to the Claude desktop app's
///   Code sessions).
/// - Codex: `~/.codex/hooks.json` (same layout).
enum AgentHookInstaller {
    static let claudeEvents = ["UserPromptSubmit", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "SessionEnd"]
    static let codexEvents = ["UserPromptSubmit", "Stop", "SubagentStart", "SubagentStop", "SessionEnd"]

    struct Target {
        let agent: AgentKind
        let folder: URL
        let file: URL
        let events: [String]
    }

    static func targets(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Target] {
        [
            Target(agent: .claude, folder: home.appendingPathComponent(".claude"),
                   file: home.appendingPathComponent(".claude/settings.json"), events: claudeEvents),
            Target(agent: .codex, folder: home.appendingPathComponent(".codex"),
                   file: home.appendingPathComponent(".codex/hooks.json"), events: codexEvents),
        ]
    }

    typealias State = AgentHookSettings.State

    static func command(agent: AgentKind, executable: String = Bundle.main.executablePath ?? "") -> String {
        "\"\(executable)\" --agent-hook \(agent.rawValue)"
    }

    // MARK: Files

    static func state(_ target: Target) -> State {
        guard FileManager.default.fileExists(atPath: target.folder.path) else { return .notFound }
        guard let settings = read(target.file) else { return .notInstalled }
        return AgentHookSettings.state(of: settings, command: command(agent: target.agent), events: target.events)
    }

    static func install(_ target: Target) throws {
        let settings = read(target.file) ?? [:]
        try backUp(target.file)
        try write(AgentHookSettings.merging(into: settings, command: command(agent: target.agent), events: target.events), to: target.file)
    }

    static func uninstall(_ target: Target) throws {
        guard let settings = read(target.file) else { return }
        let cleaned = AgentHookSettings.removing(from: settings)
        guard !NSDictionary(dictionary: cleaned).isEqual(to: settings) else { return }
        try write(cleaned, to: target.file)
    }

    /// nil when missing; throws nothing on a malformed file but returns nil, and `install`
    /// then refuses to overwrite it (see `write`).
    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func backUp(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("clamstop-backup")
        try? fm.removeItem(at: backup)
        try fm.copyItem(at: url, to: backup)
    }

    private static func write(_ settings: [String: Any], to url: URL) throws {
        // A settings file that exists but does not parse is never overwritten.
        if FileManager.default.fileExists(atPath: url.path), read(url) == nil {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}
