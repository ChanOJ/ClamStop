// Stay awake while a chosen app or command works (spec C5). A watched app works while it (or one
// of its subprocesses) keeps the Mac awake on its own with a power assertion, or uses the
// processor; the Mac then stays awake until neither has been true for a grace period.

import Foundation

/// An app or command chosen by the user.
public struct WatchedApp: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Shown in the settings and the menu ("HandBrake", "ffmpeg").
    public var name: String
    /// The app bundle, for an app: every process inside it belongs to it.
    public var bundlePath: String?
    /// Executable names, for commands (and an app's command line tools).
    public var executables: [String]

    public init(id: UUID = UUID(), name: String, bundlePath: String? = nil, executables: [String] = []) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.executables = executables
    }

    /// Same app or commands, whatever the identifier and the name.
    public func watchesTheSame(as other: WatchedApp) -> Bool {
        bundlePath == other.bundlePath && Set(executables) == Set(other.executables)
    }

    /// The process with this executable path is one of the app's own.
    public func matches(executablePath path: String) -> Bool {
        if let bundlePath, !bundlePath.isEmpty, path.hasPrefix(bundlePath + "/") { return true }
        return executables.contains((path as NSString).lastPathComponent)
    }

    /// Also a command written in a script language, seen as its interpreter (`aider` runs as
    /// Python).
    public func matches(_ process: ProcessTable.Entry) -> Bool {
        if matches(executablePath: process.path) { return true }
        guard let script = process.script else { return false }
        let name = (script as NSString).lastPathComponent
        return executables.contains(name) || executables.contains((name as NSString).deletingPathExtension)
    }
}

/// State of one watched app, shown in the app.
public struct WatchedAppActivity: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case notRunning
        case idle
        case working
        /// Stopped working, kept a little longer in case it starts again (next file, next step).
        case finishing
    }

    public var id: UUID
    public var name: String
    public var state: State

    public var holdsTheMac: Bool { state == .working || state == .finishing }

    public init(id: UUID, name: String, state: State) {
        self.id = id
        self.name = name
        self.state = state
    }
}

/// Which watched apps work. Pure logic, fed with the process list at each probe. Not
/// thread-safe: call from one serial queue.
public final class AppTracker {
    /// Kept after the last sign of work.
    public static let gracePeriod: TimeInterval = 90
    /// Share of one processor core, between two probes, that counts as work (spec C5, to tune).
    public static let busyCPUShare = 0.05
    /// Seconds between probes while apps are watched.
    public static let tickInterval: TimeInterval = 15

    private struct ProcessKey: Hashable {
        var pid: Int32
        var startMicros: UInt64
    }

    private struct Record {
        /// CPU seconds of each of the app's processes at the previous probe.
        var cpu: [ProcessKey: Double] = [:]
        var probedAt: Date?
        var lastWork: Date?
        var state = WatchedAppActivity.State.notRunning
    }

    public private(set) var apps: [WatchedApp] = []
    private var records: [UUID: Record] = [:]
    private let log: (String) -> Void

    public init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    public var activity: [WatchedAppActivity] {
        apps.map { WatchedAppActivity(id: $0.id, name: $0.name, state: records[$0.id]?.state ?? .notRunning) }
    }

    public var isWorking: Bool { activity.contains(where: \.holdsTheMac) }

    /// The watched apps; what is known about those still watched is kept.
    public func watch(_ newApps: [WatchedApp]) {
        apps = newApps
        let ids = Set(newApps.map(\.id))
        records = records.filter { ids.contains($0.key) }
    }

    public func reset() {
        records.removeAll()
    }

    /// - Parameters:
    ///   - processes: every running process.
    ///   - asserting: processes keeping the Mac from sleeping with a power assertion.
    ///   - cpuSeconds: total CPU time of a process so far.
    public func tick(now: Date, processes: [ProcessTable.Entry], asserting: Set<Int32>,
                     cpuSeconds: (Int32) -> Double?) {
        var children: [Int32: [ProcessTable.Entry]] = [:]
        for process in processes { children[process.parent, default: []].append(process) }

        for app in apps {
            var record = records[app.id] ?? Record()
            // The app's own processes and everything they started.
            var stack = processes.filter { app.matches($0) }
            var members: [ProcessTable.Entry] = []
            var seen: Set<Int32> = []
            while let process = stack.popLast() {
                guard seen.insert(process.pid).inserted else { continue }
                members.append(process)
                stack.append(contentsOf: children[process.pid] ?? [])
            }

            var cpu: [ProcessKey: Double] = [:]
            var used = 0.0
            for process in members {
                guard let seconds = cpuSeconds(process.pid) else { continue }
                let key = ProcessKey(pid: process.pid, startMicros: process.startMicros)
                cpu[key] = seconds
                if let before = record.cpu[key] {
                    used += max(0, seconds - before)
                } else if let last = record.probedAt,
                          Double(process.startMicros) / 1_000_000 >= last.timeIntervalSince1970 {
                    used += seconds  // started since the previous probe
                }
            }
            let elapsed = record.probedAt.map { now.timeIntervalSince($0) } ?? 0
            let share = elapsed > 0 ? used / elapsed : 0
            let holds = members.contains { asserting.contains($0.pid) }
            record.cpu = cpu
            record.probedAt = now

            let before = record.state
            if !members.isEmpty, holds || share > Self.busyCPUShare {
                record.lastWork = now
                record.state = .working
                if before != .working && before != .finishing {
                    log("\(app.name): working (" + (holds ? "keeps the Mac awake"
                        : String(format: "processor %.0f %%", share * 100)) + ")")
                }
            } else if let lastWork = record.lastWork, now.timeIntervalSince(lastWork) < Self.gracePeriod {
                record.state = .finishing
            } else {
                record.state = members.isEmpty ? .notRunning : .idle
                if before == .working || before == .finishing { log("\(app.name): done") }
                record.lastWork = nil
            }
            records[app.id] = record
        }
    }
}
