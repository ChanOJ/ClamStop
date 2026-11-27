import Foundation
import ClamStopShared

/// Feeds `AppTracker` (spec C5) every `AppTracker.tickInterval` seconds while apps are watched
/// and ClamStop is active: process list through libproc, power assertions through IOKit. With
/// nothing to watch, nothing runs. Main queue only.
final class AppMonitor {
    let tracker: AppTracker
    /// Called after each probe, and when watching stops, with `tracker.isWorking`.
    var onChange: (Bool) -> Void = { _ in }
    private var timer: DispatchSourceTimer?

    init() {
        tracker = AppTracker(log: Log.info)
    }

    func update(watched: [WatchedApp], active: Bool) {
        tracker.watch(watched)
        if active, !watched.isEmpty {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: AppTracker.tickInterval, leeway: .seconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            Log.info("watching \(watched.map(\.name).joined(separator: ", "))")
        } else if timer != nil {
            timer?.cancel()
            timer = nil
            tracker.reset()
            Log.info("no longer watching apps")
            onChange(false)
        }
    }

    private func tick() {
        tracker.tick(now: Date(), processes: ProcessTable.allPIDs().compactMap(ProcessTable.entry),
                     asserting: SystemPower.processesPreventingSleep(), cpuSeconds: ProcessTable.cpuSeconds)
        onChange(tracker.isWorking)
    }
}
