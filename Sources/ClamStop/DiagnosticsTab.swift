import SwiftUI
import ClamStopAppCore
import ClamStopShared

/// Diagnostics: the health check (spec H4), what keeps the Mac awake (H2), the sleep journal (H3)
/// and problem reports.
struct DiagnosticsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                OptionRow(title: "Health check",
                          note: "What could stop ClamStop from working on this Mac.") {
                    Button("Check Again") { model.checkAgain() }
                        .disabled(model.revealedChecks != nil)
                }
                ForEach(Array(model.healthChecks.enumerated()), id: \.element.id) { index, check in
                    HealthRow(model: model, check: check,
                              pending: index >= model.revealedChecks ?? .max)
                }
            }
            JournalSection(model: model)
            ReportSection(model: model)
        }
        .task { await model.readHealthFacts() }
        .onChange(of: model.serviceState) { Task { await model.readHealthFacts() } }
        // Back from System Settings or Terminal.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.readHealthFacts() }
        }
    }
}

/// What keeps the Mac awake (spec H2) and the sleep journal (H3), each in its own window.
private struct JournalSection: View {
    @ObservedObject var model: AppModel
    @AppStorage(DefaultsKey.sleepReport) private var sleepReport = false

    var body: some View {
        Section {
            OptionRow(title: "What keeps my Mac awake?",
                      note: "The apps and services that stop your Mac from sleeping on its own, and since when.") {
                Button("Show…") { model.onShowAwake() }
                    .accessibilityLabel("Show what keeps my Mac awake")
            }
            OptionRow(title: "Sleep journal",
                      note: "When the lid closed and opened, when your Mac slept, woke and hibernated, and the battery used. Kept for 30 days, on this Mac only.") {
                Button("Show…") { model.onShowJournal() }
                    .accessibilityLabel("Show the sleep journal")
                    .disabled(!model.serviceRunning)
            }
            VStack(alignment: .leading, spacing: 6) {
                ToggleRow(title: "Sleep report",
                          note: "After a sleep of 4 hours or more, a notification says how long it lasted and the battery used.",
                          isOn: $sleepReport)
                if sleepReport, model.notificationAccess == .denied {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Warning")
                            Text("ClamStop’s notifications are turned off.")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                        Button("Open Notification Settings…") { model.openNotificationSettings() }
                    }
                    .font(.footnote)
                }
            }
        }
    }
}

private struct ReportSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Report a problem")
                    .accessibilityAddTraits(.isHeader)
                Footnote("The diagnostics hold your settings (with the names of watched apps and commands), the checks above, the apps keeping your Mac awake, the sleep journal and ClamStop’s log of the last hour. ClamStop sends nothing by itself: you read the report and send it.")
                if Edition.current == .full {
                    Footnote("GitHub needs an account, and its issues are public.")
                }
                HStack {
                    if Edition.current == .full {
                        Button("Report on GitHub…") { model.reportOnGitHub() }
                    }
                    Button("Report by Email…") { model.reportByEmail() }
                    Spacer()
                    if model.preparingReport {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Collecting the diagnostics")
                    }
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                }
                .disabled(model.preparingReport)
                if let message = model.reportMessage {
                    // Under "Copy Diagnostics", where the eye is.
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

/// One check: what was found, and for a problem, what to do.
private struct HealthRow: View {
    @ObservedObject var model: AppModel
    let check: HealthCheck
    /// Unticked for a moment by "Check Again". What follows the title keeps its room, so that the
    /// window does not change size.
    let pending: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // One element for VoiceOver: the level, then what was found.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: pending ? "circle" : symbol)
                    .foregroundStyle(pending ? Color.secondary : color)
                    .frame(width: 18)
                    .accessibilityLabel(pending ? Text("Checking") : spokenLevel)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if check.level != .ok, let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(pending ? 0 : 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            if check.level != .ok {
                fix
                    .opacity(pending ? 0 : 1)
                    .disabled(pending)
            }
        }
    }

    private var symbol: String {
        switch check.level {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch check.level {
        case .ok: .green
        case .info: .secondary
        case .warning: .orange
        case .problem: .red
        }
    }

    private var spokenLevel: Text {
        switch check.level {
        case .ok: Text("OK")
        case .info: Text("Note")
        case .warning: Text("Warning")
        case .problem: Text("Problem")
        }
    }

    private var title: String {
        let ok = check.level == .ok
        switch check.kind {
        case .appLocation:
            return ok ? String(localized: "ClamStop is in the Applications folder")
                : String(localized: "ClamStop is not in the Applications folder")
        case .service:
            return ok ? String(localized: "Background service running") : model.statusLine
        case .appSeen:
            return ok ? String(localized: "The background service sees the app")
                : String(localized: "The background service does not see the app")
        case .sleepDisabled:
            return ok ? String(localized: "No leftover setting blocks sleep")
                : String(localized: "A setting stops your Mac from sleeping")
        case .hibernateMode:
            return ok ? String(localized: "Hibernation mode as expected")
                : String(localized: "Hibernation mode is not the macOS default")
        case .scheduledWake:
            return ok ? String(localized: "No leftover wake-up")
                : String(localized: "A wake-up planned by ClamStop is left over")
        case .notifications:
            switch check.level {
            case .ok: return String(localized: "Notifications allowed")
            case .info: return String(localized: "Notifications not allowed yet")
            default: return String(localized: "Notifications are turned off")
            }
        case .agentHooks:
            return ok ? String(localized: "No AI agent is missing its hook")
                : String(localized: "AI agents without ClamStop’s hook")
        case .openAtLogin:
            return ok ? String(localized: "ClamStop opens at login")
                : String(localized: "ClamStop does not open at login")
        case .menuBarIcon:
            return ok ? String(localized: "Menu bar icon shown")
                : String(localized: "Menu bar icon hidden")
        }
    }

    private var detail: String? {
        switch check.kind {
        case .appLocation:
            return String(localized: "Move it there, then open it again.")
        case .service:
            switch model.serviceState {
            case .requiresApproval:
                return String(localized: "Turn ClamStop on in System Settings > General > Login Items & Extensions.")
            case .notRegistered, .notResponding:
                return String(localized: "Installing it again often helps.")
            default:
                return nil
            }
        case .appSeen:
            return String(localized: "ClamStop does nothing until it does. Quit ClamStop, then open it again.")
        case .sleepDisabled:
            return String(localized: "“disablesleep” is on: closing the lid cannot put your Mac to sleep. If no other tool needs it, turn it off in Terminal: \(Self.enableSleepCommand)")
        case .hibernateMode:
            return String(localized: "If you did not choose this “hibernatemode”, restore it in Terminal: \(Self.hibernateCommand)")
        case .scheduledWake:
            return String(localized: "The background service removes it when it starts.")
        case .notifications:
            return String(localized: "Without them, you are not told when a safety guard lets your Mac sleep.")
        case .agentHooks:
            let names = model.healthFacts.agentsMissingHooks.formatted(.list(type: .and))
            return String(localized: "ClamStop cannot know when these work: \(names).")
        case .openAtLogin:
            return String(localized: "ClamStop only works while it runs.")
        case .menuBarIcon:
            return String(localized: "To open the settings, open ClamStop from the Applications folder.")
        }
    }

    private static let enableSleepCommand = "sudo pmset -a disablesleep 0"
    private static let hibernateCommand = "sudo pmset -a hibernatemode \(HibernateMode.default)"

    @ViewBuilder private var fix: some View {
        switch check.kind {
        case .service where model.serviceState == .requiresApproval:
            Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
        case .service where model.serviceState == .notRegistered || model.serviceState == .notResponding:
            Button("Reinstall Background Service") { model.reinstallService() }
        case .scheduledWake:
            Button("Reinstall Background Service") { model.reinstallService() }
        case .sleepDisabled:
            copyButton(Self.enableSleepCommand)
        case .hibernateMode:
            copyButton(Self.hibernateCommand)
        case .notifications:
            Button("Open Notification Settings…") { model.openNotificationSettings() }
        case .agentHooks:
            Button("Install Hooks…") { model.confirmAgentHooks = true }
        case .openAtLogin:
            Button("Open at Login") { model.setLaunchAtLogin(true) }
        default:
            EmptyView()
        }
    }

    private func copyButton(_ command: String) -> some View {
        Button("Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            VoiceOver.say(String(localized: "Command copied"))
        }
    }
}
