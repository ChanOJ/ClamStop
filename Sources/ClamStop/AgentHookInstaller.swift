import Foundation
import ClamStopAppCore
import ClamStopShared

/// Adds ClamStop's hook to the AI agents' settings, and removes it. Approach adapted from
/// clamshut (https://github.com/IshaanChamoli/clamshut, MIT, see THIRD_PARTY_NOTICES.md): merge,
/// never replace; keep a backup; idempotent; absolute paths; other hooks are left untouched.
/// Which files and events: `AgentHookTarget.all`; the file handling: `AgentHookFile`.
enum AgentHookInstaller {
    typealias State = AgentHookSettings.State

    private static var executable: String { Bundle.main.executablePath ?? "" }

    private static func url(_ path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
    }

    // MARK: Files

    static func state(_ target: AgentHookTarget) -> State {
        guard target.isFound(exists: { FileManager.default.fileExists(atPath: url($0).path) }) else { return .notFound }
        guard let settings = AgentHookFile.read(url(target.file)) else { return .notInstalled }
        return AgentHookSettings.state(of: settings, layout: target.layout, events: target.events) {
            target.command(executable: executable, event: $0)
        }
    }

    static func install(_ target: AgentHookTarget) throws {
        try AgentHookFile.install(target, at: url(target.file), executable: executable)
    }

    static func uninstall(_ target: AgentHookTarget) throws {
        try AgentHookFile.uninstall(target, at: url(target.file))
    }
}
