import Foundation
import ClamStopAppCore
import ClamStopShared
import os

private let logger = Logger(subsystem: ClamStopID.appBundleID, category: "report")

/// "Sleep report" (spec B5): a notification after a long sleep, when the user asked for it.
extension AppModel {
    /// The Mac woke or its lid opened. The service needs a moment to record the end of the sleep,
    /// so look twice. A sleep is reported once, whichever of the two events sees it first.
    func checkSleepReport() {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.sleepReport) else { return }
        Task {
            for delay in [5, 30] {
                try? await Task.sleep(for: .seconds(delay))
                if await reportSleep() { return }
            }
        }
    }

    private func reportSleep() async -> Bool {
        guard serviceRunning, let events = try? await client.sleepLog() else { return false }
        let defaults = UserDefaults.standard
        // Development aid, to try it without sleeping for hours:
        // `defaults write io.github.chanoj.clamstop sleepReportMinimumMinutes -int 2`.
        let minutes = defaults.double(forKey: DefaultsKey.sleepReportMinimumMinutes)
        // No suspension from here to the date saved below: two checks cannot both report.
        guard let report = SleepReport.latest(
            events: events, now: Date(), lastReported: defaults.object(forKey: DefaultsKey.lastSleepReport) as? Date,
            minimumSleep: minutes > 0 ? minutes * 60 : SleepReport.minimumSleep) else { return false }
        defaults.set(report.end, forKey: DefaultsKey.lastSleepReport)
        logger.notice("sleep report: \(report.body, privacy: .public)")
        onSleepReport(report)
        return true
    }
}
