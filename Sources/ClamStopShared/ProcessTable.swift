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
        /// For an interpreter (node, python...), the script or module it runs.
        public var script: String?

        public init(pid: Int32, parent: Int32, startMicros: UInt64, path: String, script: String? = nil) {
            self.pid = pid
            self.parent = parent
            self.startMicros = startMicros
            self.path = path
            self.script = script
        }
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
                     path: path,
                     script: isInterpreter(path) ? arguments(pid).flatMap(script(inArguments:)) : nil)
    }

    /// The agent a process is, from its executable's name or from the script an interpreter runs
    /// (agents installed with npm run as `node`).
    public static func agentKind(ofExecutable path: String, script: String? = nil) -> AgentKind? {
        if let kind = agentKind(named: (path as NSString).lastPathComponent) { return kind }
        guard let script else { return nil }
        let name = ((script as NSString).lastPathComponent as NSString).deletingPathExtension
        if let kind = agentKind(named: name) { return kind }
        let packages: [(String, AgentKind)] = [
            ("/@anthropic-ai/claude-code/", .claude), ("/@openai/codex/", .codex),
            ("/@google/gemini-cli/", .gemini), ("/@github/copilot/", .copilot), ("/cursor-agent/", .cursor),
        ]
        return packages.first { script.contains($0.0) }?.1
    }

    /// Command line tools only: the Cursor and Antigravity apps are always busy, so their
    /// sessions are followed without a process.
    private static func agentKind(named name: String) -> AgentKind? {
        switch name {
        case "claude": .claude
        case "codex": .codex
        case "gemini": .gemini
        case "agy": .antigravity
        case "cursor-agent": .cursor
        case "copilot": .copilot
        default: nil
        }
    }

    public static func isInterpreter(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return ["node", "bun", "deno"].contains(name) || name.hasPrefix("python")
    }

    /// The script (or Python module) in an interpreter's arguments, the first one being the
    /// interpreter itself; nil for inline code or an interactive session.
    public static func script(inArguments arguments: [String]) -> String? {
        var rest = arguments.dropFirst()
        while let argument = rest.popFirst() {
            switch argument {
            case "-m": return rest.first
            case "-c", "-e", "--eval", "-p", "--print": return nil
            case "-r", "--require", "--import", "--loader", "-W", "-X": _ = rest.popFirst()
            case "run": continue  // `deno run`, `bun run`
            default:
                if !argument.hasPrefix("-") { return argument }
            }
        }
        return nil
    }

    /// A process's arguments (`KERN_PROCARGS2`); nil for another user's process (except as root).
    public static func arguments(_ pid: Int32) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseArguments(Array(buffer.prefix(size)))
    }

    /// Layout: argument count, executable path, padding zeros, then each argument, zero-ended
    /// (the environment follows).
    static func parseArguments(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count > 4 else { return nil }
        let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < count, index < buffer.count {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.count
            result.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return result
    }

    /// Walk up from `pid` to the nearest agent process of the given kind (the hook runs under a
    /// shell started by the agent). The nearest one, not the outermost: the Claude desktop app
    /// ("Claude") hosts Claude Code sessions and must not be taken for one.
    public static func agentAncestor(of pid: Int32, kind: AgentKind) -> Entry? {
        var current = pid
        for _ in 0..<20 {
            guard let e = entry(current), e.pid > 1 else { return nil }
            if agentKind(ofExecutable: e.path, script: e.script) == kind { return e }
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
    /// - Parameter includeRoot: false = only the descendants (the tools and builds an agent runs).
    public static func treeCPUSeconds(root: Int32, includeRoot: Bool = true) -> Double? {
        guard let rootCPU = cpuSeconds(root) else { return nil }
        var children: [Int32: [Int32]] = [:]
        for pid in allPIDs() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            children[Int32(info.pbi_ppid), default: []].append(pid)
        }
        var total = includeRoot ? rootCPU : 0
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
