import ClamStopShared
import Foundation

/// An agent's settings file on disk (the JSON itself is `AgentHookSettings`). Writes through
/// symbolic links (settings kept in a dotfiles folder), never overwrites a file it cannot read,
/// and keeps a backup next to it only while the hook is installed.
public enum AgentHookFile {
    public static let backupExtension = "clamstop-backup"

    /// nil when missing or not a JSON object.
    public static func read(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func install(_ target: AgentHookTarget, at file: URL, executable: String) throws {
        let real = resolved(file)
        let exists = FileManager.default.fileExists(atPath: real.path)
        let settings = read(real)
        if exists, settings == nil {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
        }
        if exists { try backUp(real, to: backup(of: file)) }
        try write(AgentHookSettings.merging(into: settings ?? [:], layout: target.layout, events: target.events) {
            target.command(executable: executable, event: $0)
        }, to: real)
    }

    /// An unreadable file is left as it is, with its backup.
    public static func uninstall(_ target: AgentHookTarget, at file: URL) throws {
        let real = resolved(file)
        guard let settings = read(real) else { return }
        let cleaned = AgentHookSettings.removing(from: settings, layout: target.layout)
        if !NSDictionary(dictionary: cleaned).isEqual(to: settings) {
            if target.layout == .ownFile, AgentHookSettings.isEmpty(cleaned) {
                try FileManager.default.removeItem(at: file)
            } else {
                try write(cleaned, to: real)
            }
        }
        // The copy of the settings (they can hold keys) does not outlive the hook.
        let copy = backup(of: file)
        if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
    }

    static func backup(of file: URL) -> URL {
        file.appendingPathExtension(backupExtension)
    }

    /// The file a path leads to, following symbolic links (also one to a file not there yet).
    static func resolved(_ file: URL) -> URL {
        if let real = realpath(file.path, nil) {
            defer { free(real) }
            return URL(fileURLWithPath: String(cString: real))
        }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path) else {
            return file
        }
        return URL(fileURLWithPath: destination, relativeTo: file.deletingLastPathComponent()).absoluteURL
    }

    private static func backUp(_ file: URL, to copy: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: file, to: copy)
    }

    private static func write(_ settings: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }
}
