import Foundation
import IOKit.pwr_mgt
import ClamStopDiagnostics
import ClamStopShared

/// macOS's power assertions and the processes behind them (spec H2). No root needed.
enum AssertionReader {
    static func read() -> (assertions: [PowerAssertion], processes: [Int32: ProcessIdentity]) {
        var copy: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copy) == kIOReturnSuccess,
              let byProcess = copy?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return ([], [:]) }
        var assertions: [PowerAssertion] = []
        var processes: [Int32: ProcessIdentity] = [:]

        /// nil when the process is gone or unreadable and macOS gave no name for it.
        func identify(_ pid: Int32, name: String?) -> Bool {
            if processes[pid] != nil { return true }
            let path = ProcessTable.entry(pid)?.path
            if let path, !path.isEmpty {
                processes[pid] = ProcessIdentity(name: (path as NSString).lastPathComponent, path: path)
            } else if let name {
                processes[pid] = ProcessIdentity(name: name, path: nil)
            }
            return processes[pid] != nil
        }

        for (holder, list) in byProcess {
            for entry in list {
                // Level 0: the assertion exists but is off.
                guard (entry["AssertLevel"] as? Int ?? 255) != 0,
                      let type = (entry["AssertionTrueType"] ?? entry[kIOPMAssertionTypeKey]) as? String,
                      let since = entry["AssertStartWhen"] as? Date else { continue }
                // For another process (sound played for an app): count it as that one's.
                var pid = (entry["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? 0
                if pid <= 0 || !identify(pid, name: nil) {
                    pid = holder.int32Value
                    guard identify(pid, name: entry["Process Name"] as? String ?? "pid \(pid)") else { continue }
                }
                assertions.append(PowerAssertion(pid: pid, type: type,
                                                 name: entry[kIOPMAssertionNameKey] as? String ?? "", since: since))
            }
        }
        return (assertions, processes)
    }

    static func awakeList(status: DaemonStatus?, sleepDisabled: Bool?) -> AwakeList {
        let (assertions, processes) = read()
        return AwakeList(assertions: assertions, status: status, sleepDisabled: sleepDisabled) {
            processes[$0] ?? ProcessIdentity(name: "pid \($0)", path: nil)
        }
    }
}
