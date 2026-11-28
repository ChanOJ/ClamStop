import Foundation
import IOKit.pwr_mgt
import ClamStopAppCore
import ClamStopShared

/// What the health check and the diagnostics read from macOS, without root (spec H4).
enum SystemProbe {
    static func sleepState() async -> SystemSleepState {
        let output = await run("/usr/bin/pmset", ["-g"], timeout: 10)
        let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] ?? []
        let wakes = events.filter { $0["scheduledby"] as? String == ClamStopID.daemonLabel }
            .compactMap { $0["time"] as? Date }
        return SystemSleepState(pmsetOutput: (try? output.get()) ?? "", scheduledWakes: wakes)
    }

    /// ClamStop's lines of the unified log. Only administrator accounts can read it.
    static func recentLog() async -> Result<String, DiagnosticsReport.LogUnavailable> {
        await run("/usr/bin/log", ["show", "--last", "1h", "--style", "compact",
                                   "--predicate", "subsystem == \"\(ClamStopID.appBundleID)\""], timeout: 30)
    }

    /// "Mac17,1".
    static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// "27.2.1 (Build 25C101)".
    static var macOSVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")
    }

    /// Standard output of a command, stopped after `timeout`.
    private static func run(_ path: String, _ arguments: [String],
                            timeout: TimeInterval) async -> Result<String, DiagnosticsReport.LogUnavailable> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(.init(error.localizedDescription)))
                    return
                }
                let stop = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
                // Read before waiting: a full pipe would block the command. Errors are short.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stop.cancel()
                if process.terminationReason == .exit, process.terminationStatus == 0 {
                    continuation.resume(returning: .success(String(decoding: data, as: UTF8.self)))
                } else {
                    let first = String(decoding: message, as: UTF8.self).split(separator: "\n").first.map(String.init)
                    let reason = process.terminationReason == .exit
                        ? first ?? "exit status \(process.terminationStatus)" : "stopped after \(Int(timeout)) s"
                    continuation.resume(returning: .failure(.init(reason)))
                }
            }
        }
    }
}
