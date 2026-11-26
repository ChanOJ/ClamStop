import Foundation
import ClamStopShared

/// Feeds `AgentTracker` with hook messages and, only while a lease exists, probes the agent
/// processes every `AgentTracker.tickInterval` seconds (libproc and file dates: no `ps`, no
/// shell). With no agent session, nothing runs. Main queue only.
final class AgentMonitor {
    let tracker: AgentTracker
    /// Called after each message or tick with `tracker.isWorking`.
    var onChange: (Bool) -> Void = { _ in }
    private var timer: DispatchSourceTimer?

    init() {
        tracker = AgentTracker(log: Log.info)
    }

    func handle(_ message: AgentHookMessage) {
        var message = message
        // The hook found the agent process; check it from here too (the hook could be anyone
        // allowed to connect, but only the ClamStop app passes the XPC code signing check).
        if let pid = message.agentPID, !ProcessTable.isAlive(pid: pid, startMicros: message.agentStartMicros) {
            message.agentPID = nil
            message.agentStartMicros = nil
        }
        tracker.handle(message, now: Date())
        updateTimer()
        onChange(tracker.isWorking)
    }

    func tick() {
        tracker.tick(now: Date()) { lease in
            AgentProbe(
                alive: lease.pid.map { ProcessTable.isAlive(pid: $0, startMicros: lease.pidStartMicros) },
                newestActivity: lease.transcriptPath.flatMap { ProcessTable.newestActivity(transcript: $0) },
                cpuSeconds: lease.pid.flatMap { ProcessTable.treeCPUSeconds(root: $0) })
        }
        updateTimer()
        onChange(tracker.isWorking)
    }

    /// Forget every session (ClamStop turned off, uninstall).
    func reset() {
        tracker.removeAll()
        updateTimer()
    }

    private func updateTimer() {
        if tracker.isWorking, timer == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + AgentTracker.tickInterval, repeating: AgentTracker.tickInterval,
                       leeway: .seconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        } else if !tracker.isWorking, let t = timer {
            t.cancel()
            timer = nil
        }
    }
}
