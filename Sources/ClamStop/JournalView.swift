import AppKit
import SwiftUI
import ClamStopShared

/// The sleep journal (spec H3): what the Mac did, by day, newest first.
struct JournalView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            let days = SleepLog.journal(from: model.sleepLog)
            if days.isEmpty {
                Text("Nothing recorded yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Divider()
                // Not a `List`: VoiceOver stopped at the first day's name (reported 2026-11-28).
                ScrollView {
                    // Not `Section` headers: VoiceOver would read them after all the rows.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days) { day in
                            dayHeader(day.date)
                            ForEach(day.entries) { entry in
                                JournalRow(entry: entry)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 4)
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
            Divider()
            Text("Kept for 30 days, on this Mac only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(minWidth: 420, minHeight: 300)
        // The window stays open while the Mac sleeps: read again when coming back to it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.loadSleepLog()
        }
    }

    /// Names the columns of `JournalRow`, and stays in place while the list scrolls.
    private var header: some View {
        HStack(spacing: JournalRow.columnSpacing) {
            Text("Time")
                .frame(width: JournalRow.timeWidth, alignment: .leading)
            Text("Activity")
            Spacer(minLength: 8)
            Text("Battery")
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16)  // as the rows
        .padding(.vertical, 8)
        .accessibilityHidden(true)  // each row reads on its own
    }

    private func dayHeader(_ day: Date) -> some View {
        Text(title(day))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func title(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct JournalRow: View {
    static let columnSpacing: CGFloat = 12
    static let timeWidth: CGFloat = 64

    let entry: JournalEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.columnSpacing) {
            Text(entry.event.date.formatted(date: .omitted, time: .shortened))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.timeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let percent = entry.event.batteryPercent {
                Text(verbatim: "\(percent) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Battery \(percent) %"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch entry.event.kind {
        case .lidClosed: String(localized: "Lid closed")
        case .lidOpened: String(localized: "Lid opened")
        case .sleep: String(localized: "Went to sleep")
        case .hibernate: String(localized: "Hibernated")
        case .wake:
            entry.event.detail == SleepLog.wakeLidOpen ? String(localized: "Woke up")
                : String(localized: "Woke up with the lid closed")
        case .keptAwakeForAgents: String(localized: "Staying awake with the lid closed")
        case .agentsDone: String(localized: "Stopped staying awake")
        }
    }

    /// The reason, then how the sleep that just ended went.
    private var summary: String? {
        var parts: [String] = []
        let detail = entry.event.detail ?? ""
        switch entry.event.kind {
        case .wake:
            if let reason = entry.event.wakeReason.flatMap(WakeReason.init) { parts.append(text(reason)) }
        case .keptAwakeForAgents:
            if let reason = KeepAwakeReason(rawValue: detail) { parts.append(text(reason)) }
        case .agentsDone:
            if let reason = KeepAwakeEnd(rawValue: detail) { parts.append(text(reason)) }
        default:
            break
        }
        if let session = entry.asleep, let end = session.end {
            parts.append(String(localized: "asleep \(duration(from: session.start, to: end))"))
            if let used = session.batteryUsed, used > 0 { parts.append(String(localized: "battery −\(used) %")) }
            if session.hibernated { parts.append(String(localized: "hibernated")) }
        }
        guard let first = parts.first else { return nil }
        parts[0] = first.prefix(1).uppercased() + first.dropFirst()
        return parts.joined(separator: " · ")
    }

    private func text(_ reason: WakeReason) -> String {
        switch reason {
        case .lid: String(localized: "lid opened")
        case .keyboard: String(localized: "keyboard")
        case .trackpad: String(localized: "trackpad")
        case .powerAdapter: String(localized: "power adapter")
        case .network: String(localized: "network")
        case .scheduled: String(localized: "scheduled wake")
        case .user: String(localized: "user activity")
        case .other: String(localized: "other reason")
        }
    }

    private func text(_ reason: KeepAwakeReason) -> String {
        switch reason {
        case .session: String(localized: "Stay Awake from the menu")
        case .agents: String(localized: "AI agents working")
        case .apps: String(localized: "apps working")
        case .rule: String(localized: "rule")
        }
    }

    private func text(_ reason: KeepAwakeEnd) -> String {
        switch reason {
        case .finished: String(localized: "work finished")
        case .sessionEnded: String(localized: "Stay Awake ended")
        case .changed: String(localized: "settings or conditions changed")
        case .maxDuration: String(localized: "longest time reached")
        case .heat: String(localized: "Mac too hot")
        case .unplugged: String(localized: "power adapter unplugged")
        case .batteryFloor, .lowBattery: String(localized: "battery too low")
        case .appQuit: String(localized: "ClamStop quit")
        case .appUnresponsive: String(localized: "ClamStop stopped responding")
        }
    }

    private func duration(from start: Date, to end: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, end.timeIntervalSince(start))) ?? "–"
    }
}
