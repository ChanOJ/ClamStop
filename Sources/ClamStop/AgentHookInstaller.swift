import Foundation
import ClamStopShared

/// Adds ClamStop's hook to the AI agents' settings, and removes it. Approach adapted from
/// clamshut (https://github.com/IshaanChamoli/clamshut, MIT, see THIRD_PARTY_NOTICES.md): merge,
/// never replace; keep a backup; idempotent; absolute paths; other hooks are left untouched.
/// Which files and events: `AgentHookTarget.all`.
enum AgentHookInstaller {
    typealias State = AgentHookSettings.State

    private static var executable: String { Bundle.main.executablePath ?? "" }

    private static func url(_ path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
    }

    // MARK: Files

    static func state(_ target: AgentHookTarget) -> State {
        guard target.isFound(exists: { FileManager.default.fileExists(atPath: url($0).path) }) else { return .notFound }
        guard let settings = read(url(target.file)) else { return .notInstalled }
        return AgentHookSettings.state(of: settings, layout: target.layout, events: target.events) {
            target.command(executable: executable, event: $0)
        }
    }

    static func install(_ target: AgentHookTarget) throws {
        let file = url(target.file)
        let settings = read(file) ?? [:]
        try backUp(file)
        try write(AgentHookSettings.merging(into: settings, layout: target.layout, events: target.events) {
            target.command(executable: executable, event: $0)
        }, to: file)
    }

    static func uninstall(_ target: AgentHookTarget) throws {
        let file = url(target.file)
        guard let settings = read(file) else { return }
        let cleaned = AgentHookSettings.removing(from: settings, layout: target.layout)
        guard !NSDictionary(dictionary: cleaned).isEqual(to: settings) else { return }
        if target.layout == .ownFile, AgentHookSettings.isEmpty(cleaned) {
            try FileManager.default.removeItem(at: file)
        } else {
            try write(cleaned, to: file)
        }
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
