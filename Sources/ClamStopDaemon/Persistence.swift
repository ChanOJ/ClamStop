import Foundation
import ClamStopShared

/// JSON files in a root-owned folder: settings and the state needed to clean up after a restart.
final class FileStore: StateStore {
    static let defaultDirectory = URL(fileURLWithPath: "/Library/Application Support/ClamStop", isDirectory: true)

    let directory: URL
    /// Set after `removeAll()`: no more writes, so uninstall leaves nothing behind.
    private var removed = false
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    private var sleepLogURL: URL { directory.appendingPathComponent("sleep-log.json") }

    init(directory: URL = FileStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
    }

    func load() -> PersistedState {
        read(PersistedState.self, from: stateURL) ?? PersistedState()
    }

    func save(_ state: PersistedState) {
        write(state, to: stateURL)
    }

    func loadSettings() -> ClamStopSettings {
        read(ClamStopSettings.self, from: settingsURL) ?? ClamStopSettings()
    }

    func saveSettings(_ settings: ClamStopSettings) {
        write(settings, to: settingsURL)
    }

    func loadSleepLog() -> [SleepEvent] {
        read([SleepEvent].self, from: sleepLogURL) ?? []
    }

    func saveSleepLog(_ events: [SleepEvent]) {
        write(events, to: sleepLogURL)
    }

    /// Uninstall: forget everything.
    func removeAll() {
        removed = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch {
            Log.error("cannot decode \(url.path): \(error)")
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard !removed else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            Log.error("cannot write \(url.path): \(error)")
        }
    }
}
