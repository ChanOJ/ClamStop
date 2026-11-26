import Darwin
import Foundation

/// Process facts through libproc (no `ps`, no shell): used by the agent hook to find its agent
/// process, and by the daemon to check that it is alive and how much CPU its tree uses.
public enum ProcessTable {
    public struct Entry: Equatable, Sendable {
        public var pid: Int32
        public var parent: Int32
        /// Start time, microseconds since 1970.
        public var startMicros: UInt64
        public var path: String
    }

    public static func entry(_ pid: Int32) -> Entry? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        return Entry(pid: pid, parent: Int32(info.pbi_ppid),
                     startMicros: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec),
                     path: path)
    }

    /// Executable names of the supported agents (Claude Code's native binary, Codex's).
    public static func agentKind(ofExecutable path: String) -> AgentKind? {
        switch (path as NSString).lastPathComponent {
        case "claude": .claude
        case "codex": .codex
        default: nil
        }
    }

    /// Walk up from `pid` to the nearest agent process of the given kind (the hook runs under a
    /// shell started by the agent). The nearest one, not the outermost: the Claude desktop app
    /// ("Claude") hosts Claude Code sessions and must not be taken for one.
    public static func agentAncestor(of pid: Int32, kind: AgentKind) -> Entry? {
        var current = pid
        for _ in 0..<20 {
            guard let e = entry(current), e.pid > 1 else { return nil }
            if agentKind(ofExecutable: e.path) == kind { return e }
            current = e.parent
        }
        return nil
    }

    /// The process exists and is the same one (not a reused PID).
    public static func isAlive(pid: Int32, startMicros: UInt64?) -> Bool {
        guard let e = entry(pid) else { return false }
        guard let startMicros else { return true }
        return e.startMicros == startMicros
    }

    public static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(0, filled)))).filter { $0 > 0 }
    }

    /// CPU seconds (user + system) used by one process; nil if it cannot be read.
    public static func cpuSeconds(_ pid: Int32) -> Double? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        // Mach absolute time units (not nanoseconds on Apple Silicon).
        return Double(usage.ri_user_time + usage.ri_system_time) * timebase / 1_000_000_000
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }()

    /// Total CPU seconds of `root` and all its descendants.
    public static func treeCPUSeconds(root: Int32) -> Double? {
        guard let rootCPU = cpuSeconds(root) else { return nil }
        var children: [Int32: [Int32]] = [:]
        for pid in allPIDs() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            children[Int32(info.pbi_ppid), default: []].append(pid)
        }
        var total = rootCPU
        var stack = children[root] ?? []
        var seen: Set<Int32> = [root]
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            total += cpuSeconds(pid) ?? 0
            stack.append(contentsOf: children[pid] ?? [])
        }
        return total
    }

    /// Newest modification date of a Claude Code transcript and of its subagent transcripts,
    /// which live in a folder named after the session next to it (`<session>.jsonl` and
    /// `<session>/`). At most `budget` files are checked.
    public static func newestActivity(transcript: String, budget: Int = 400) -> Date? {
        let fm = FileManager.default
        var newest: Date?
        func consider(_ path: String) {
            guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        consider(transcript)
        guard transcript.hasSuffix(".jsonl") else { return newest }
        let folder = String(transcript.dropLast(".jsonl".count))
        guard let walker = fm.enumerator(atPath: folder) else { return newest }
        var remaining = budget
        while let relative = walker.nextObject() as? String, remaining > 0 {
            remaining -= 1
            consider((folder as NSString).appendingPathComponent(relative))
        }
        return newest
    }
}
