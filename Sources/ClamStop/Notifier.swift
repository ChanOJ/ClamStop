import AppKit
import Foundation
import UserNotifications
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

    private let center = UNUserNotificationCenter.current()
    /// Date of the newest notice already handled; older ones are never shown again.
    private var lastNoticeDate: Date {
        get { UserDefaults.standard.object(forKey: DefaultsKey.lastNoticeDate) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.lastNoticeDate) }
    }
    private var approvalNotified = false
    /// Notices older than this when the app first sees them are dropped (the app was not running).
    static let maxAge: TimeInterval = 12 * 3600

    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { logger.error("notifications: \(error.localizedDescription, privacy: .public)") }
            logger.info("notifications allowed: \(granted)")
        }
    }

    /// New status from the daemon: post the notices not shown yet.
    func process(_ status: DaemonStatus) {
        let last = lastNoticeDate
        let now = Date()
        let fresh = (status.notices ?? []).filter { $0.date > last && now.timeIntervalSince($0.date) < Self.maxAge }
        guard let newest = status.notices?.map(\.date).max(), newest > last else { return }
        lastNoticeDate = newest
        for notice in fresh {
            post(id: notice.id.uuidString, title: Self.title(notice), body: Self.body(notice))
        }
    }

    /// The service is waiting for approval: say so once per launch.
    func serviceNeedsApproval() {
        guard !approvalNotified else { return }
        approvalNotified = true
        post(id: "approval",
             title: String(localized: "ClamStop needs your approval"),
             body: String(localized: "Turn ClamStop on in System Settings > General > Login Items & Extensions, so that it can work."))
    }

    func serviceApproved() {
        approvalNotified = false
        center.removeDeliveredNotifications(withIdentifiers: ["approval"])
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
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
        Task { @MainActor in
            self.onOpen()
            completionHandler()
        }
    }
}
