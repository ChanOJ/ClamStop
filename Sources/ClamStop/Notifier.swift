import AppKit
import Foundation
import UserNotifications
import ClamStopAppCore
import ClamStopShared
import os

private let logger = Logger(subsystem: ClamStopID.appBundleID, category: "notifications")

/// Notifications (spec H5): a "Stay awake" session ended, a safety guard let the Mac sleep,
/// the background service needs approval. The daemon runs as root and cannot post them: it keeps
/// recent `Notice`s in its status, and the app posts the ones it has not shown yet.
/// Users turn them off in System Settings > Notifications, like any app.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called when a notification is clicked.
    var onOpen: () -> Void = {}
    /// Called when the sleep report is clicked.
    var onOpenJournal: () -> Void = {}
    /// Called when any notification or one of its buttons is clicked, before the rest.
    var onClick: () -> Void = {}
    /// Called by "+30 min" on the reminder that a session ends.
    var onExtendSession: () -> Void = {}
    private nonisolated static let sleepReportID = "sleep-report"
    private nonisolated static let sessionEndingID = "session-ending"
    private nonisolated static let extendActionID = "extend"
    /// The end of the session already reminded of.
    private var remindedEnd: Date?

    /// Only from a ClamStop.app bundle: `current()` raises an exception outside one (`swift run`).
    private var center: UNUserNotificationCenter { .current() }
    private var available: Bool { Bundle.main.bundleIdentifier != nil }
    /// Date of the newest notice already handled; older ones are never shown again.
    private var lastNoticeDate: Date {
        get { UserDefaults.standard.object(forKey: DefaultsKey.lastNoticeDate) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.lastNoticeDate) }
    }
    private var approvalNotified = false
    /// Notices older than this when the app first sees them are dropped (the app was not running).
    static let maxAge: TimeInterval = 12 * 3600

    func start() {
        guard available else { return }
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.sessionEndingID,
            actions: [UNNotificationAction(identifier: Self.extendActionID, title: String(localized: "+30 min"))],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { logger.error("notifications: \(error.localizedDescription, privacy: .public)") }
            logger.info("notifications allowed: \(granted)")
        }
    }

    /// New status from the daemon: post the notices not shown yet.
    func process(_ status: DaemonStatus) {
        remindOfSessionEnd(status.session)
        let last = lastNoticeDate
        let now = Date()
        let fresh = (status.notices ?? []).filter { $0.date > last && now.timeIntervalSince($0.date) < Self.maxAge }
        guard let newest = status.notices?.map(\.date).max(), newest > last else { return }
        lastNoticeDate = newest
        for notice in fresh {
            post(id: notice.id.uuidString, title: Self.title(notice), body: Self.body(notice))
        }
    }

    /// A few minutes before a "Stay awake" session ends (spec C4), with a "+30 min" button. The
    /// reminder goes once the session is over or its end has moved.
    private func remindOfSessionEnd(_ session: StayAwakeSession?) {
        if let reminded = remindedEnd, session?.until.map({ abs($0.timeIntervalSince(reminded)) >= 1 }) ?? true {
            remindedEnd = nil
            if available { center.removeDeliveredNotifications(withIdentifiers: [Self.sessionEndingID]) }
        }
        guard let session, let until = session.until,
              SessionEnd.reminderIsDue(session, now: Date(), reminded: remindedEnd) else { return }
        remindedEnd = until
        let time = until.formatted(date: .omitted, time: .shortened)
        post(id: Self.sessionEndingID, title: String(localized: "Stay Awake ends at \(time)"),
             body: String(localized: "After that, your Mac can sleep again."), category: Self.sessionEndingID)
    }

    /// The service is waiting for approval: say so once per launch.
    func serviceNeedsApproval() {
        guard !approvalNotified else { return }
        approvalNotified = true
        postApproval(id: Self.approvalID)
    }

    /// The switch is still off a while later: the same notification again, as a new one so that
    /// macOS shows it.
    func serviceStillNeedsApproval() {
        guard available else { return }
        center.removeDeliveredNotifications(withIdentifiers: [Self.approvalID])
        postApproval(id: Self.reminderID)
    }

    private static let approvalID = "approval"
    private static let reminderID = "approval-reminder"

    private func postApproval(id: String) {
        post(id: id,
             title: String(localized: "ClamStop needs your approval"),
             body: String(localized: "Turn ClamStop on in System Settings > General > Login Items & Extensions, so that it can work."))
    }

    func serviceApproved() {
        approvalNotified = false
        guard available else { return }
        center.removeDeliveredNotifications(withIdentifiers: [Self.approvalID, Self.reminderID])
    }

    /// "Sleep report" (spec B5): the newest one replaces the one before.
    func sleepEnded(_ report: SleepReport) {
        post(id: Self.sleepReportID, title: SleepReport.title, body: report.body)
    }

    private func post(id: String, title: String, body: String, category: String? = nil) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { logger.error("notification not posted: \(error.localizedDescription, privacy: .public)") }
        }
        logger.info("notification: \(title, privacy: .public)")
    }

    static func title(_ notice: Notice) -> String {
        switch notice.kind {
        case .sessionEnded: String(localized: "Stay Awake ended")
        case .safetyStop: String(localized: "Your Mac went to sleep")
        }
    }

    static func body(_ notice: Notice) -> String {
        let value = notice.value ?? 0
        switch notice.reason {
        case .timeUp:
            return String(localized: "Your Mac can sleep again.")
        case .maxDuration:
            return String(localized: "It stayed awake with the lid closed for the longest time set in Safety (\(value) h).")
        case .heat:
            return String(localized: "It was getting too hot with the lid closed.")
        case .unplugged:
            return String(localized: "The power adapter was disconnected while the lid was closed.")
        case .batteryFloor:
            return String(localized: "The battery fell below \(value) %.")
        case .lowBattery:
            return String(localized: "The battery fell to \(value) %, so your Mac hibernated.")
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            logger.notice("notification clicked: \(id, privacy: .public), \(action, privacy: .public)")
            self.onClick()
            switch id {
            case Self.sleepReportID:
                self.onOpenJournal()
            case Self.sessionEndingID:
                if action == Self.extendActionID { self.onExtendSession() }
            default:
                self.onOpen()
            }
            completionHandler()
        }
    }
}
