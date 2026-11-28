import AppKit
import SwiftUI
import ClamStopDiagnostics

/// "What keeps my Mac awake?" (spec H2): ClamStop's reasons, the apps that hold sleep off, and
/// macOS's own services folded away.
struct AwakeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Text("These stop your Mac from sleeping on its own. Closing the lid still follows your ClamStop settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if let list = model.awakeList {
                if list.isEmpty {
                    Text("Nothing keeps your Mac awake.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content(list)
                }
            } else {
                ProgressView()
                    .accessibilityLabel("Reading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private func content(_ list: AwakeList) -> some View {
        // Not a `List`, nor `Section` headers: see `JournalView`.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !list.clamStop.isEmpty {
                    heading("ClamStop")
                    ForEach(Array(list.clamStop.enumerated()), id: \.offset) { _, reason in
                        clamStopRow(reason)
                    }
                }
                if list.sleepDisabledElsewhere {
                    heading("macOS setting")
                    AwakeRow(icon: .symbol("exclamationmark.triangle.fill", .orange),
                             title: String(localized: "Sleep is turned off (“disablesleep”)"),
                             note: String(localized: "See the health check in the Diagnostics tab."),
                             since: nil)
                }
                if !list.apps.isEmpty {
                    heading("Apps")
                    ForEach(list.apps) { holderRow($0) }
                }
                if !list.system.isEmpty {
                    DisclosureGroup(isExpanded: $model.showSystemHolders) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(list.system) { holderRow($0) }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("macOS (\(list.system.count))")
                                .font(.subheadline.weight(.semibold))
                            if !model.showSystemHolders {
                                Text(list.system.map(\.name).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func clamStopRow(_ reason: AwakeList.ClamStopReason) -> AwakeRow {
        let icon = AwakeRow.Icon.symbol("cup.and.saucer.fill", .accentColor)
        switch reason {
        case .session(let since, let until):
            let note = until.map { String(localized: "Until \($0.formatted(date: .omitted, time: .shortened))") }
                ?? String(localized: "Until you turn it off")
            return AwakeRow(icon: icon, title: String(localized: "Stay Awake from the menu"), note: note, since: since)
        case .agents(let names, let since):
            return AwakeRow(icon: icon, title: String(localized: "AI agents working"),
                            note: names.formatted(.list(type: .and)), since: since)
        case .apps(let names):
            return AwakeRow(icon: icon, title: String(localized: "Watched apps working"),
                            note: names.formatted(.list(type: .and)), since: nil)
        case .rule:
            return AwakeRow(icon: icon, title: String(localized: "A rule says to stay awake"), note: nil, since: nil)
        }
    }

    private func holderRow(_ holder: AwakeList.Holder) -> AwakeRow {
        let effect = switch (holder.keepsMac, holder.keepsScreen) {
        case (true, true): String(localized: "Keeps the Mac and the screen awake")
        case (false, true): String(localized: "Keeps the screen on")
        default: String(localized: "Keeps the Mac awake")
        }
        let icon: AwakeRow.Icon = holder.appBundlePath.map { .app($0) } ?? .symbol("gearshape", .secondary)
        return AwakeRow(icon: icon, title: holder.name,
                        note: ([effect] + holder.details.prefix(2)).joined(separator: " · "), since: holder.since)
    }
}

private struct AwakeRow: View {
    enum Icon {
        case app(String)
        case symbol(String, Color)
    }

    let icon: Icon
    let title: String
    let note: String?
    let since: Date?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                switch icon {
                case .app(let path):
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                case .symbol(let name, let color):
                    Image(systemName: name)
                        .foregroundStyle(color)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                if let note {
                    Text(verbatim: note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(note)
                }
            }
            Spacer(minLength: 8)
            if let since {
                Text(Self.age(since))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private static func age(_ since: Date) -> String {
        let seconds = Date().timeIntervalSince(since)
        guard seconds >= 60 else { return String(localized: "just now") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return String(localized: "for \(formatter.string(from: seconds) ?? "–")")
    }
}
