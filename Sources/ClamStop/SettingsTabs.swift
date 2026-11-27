import SwiftUI
import ClamStopShared

// The settings tabs after General (spec section 5, mockup `SettingsMockupView`). Each tab only
// shows settings that already work; the others arrive with their features.

/// Binding to one setting, sent to the daemon on change.
@MainActor
func setting<Value>(_ model: AppModel, _ keyPath: WritableKeyPath<ClamStopSettings, Value>) -> Binding<Value> {
    Binding(get: { model.settings[keyPath: keyPath] },
            set: { value in model.changeSettings { $0[keyPath: keyPath] = value } })
}

/// Stay Awake: AI agents (spec C7).
struct StayAwakeTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                OptionRow(title: "Stay awake while AI agents work",
                          note: "Claude Code and Codex. Your Mac sleeps when they are all done.") {
                    HStack(spacing: 6) {
                        HelpButton("About AI agents", isPresented: $model.showAgentHelp) { AgentHelpView() }
                        Toggle("Stay awake while AI agents work", isOn: setting(model, \.keepAwakeForAgents))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .disabled(!model.serviceRunning)
                if model.settings.keepAwakeForAgents {
                    if model.agentsFound.isEmpty {
                        Footnote("Neither Claude Code nor Codex was found on this Mac.")
                    } else if !model.agentHooksInstalled {
                        OptionRow(title: "AI agent hooks are not installed",
                                  note: "The agents need them to tell ClamStop when they work.") {
                            Button("Install Hooks…") { model.confirmAgentHooks = true }
                        }
                    } else if let line = agentActivityLine {
                        Label(line, systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Footnote("With the lid closed, your Mac can get hot. Keep it out in the open while agents work: the Safety tab puts it to sleep if it gets too hot.")
            }
        }
    }

    private var agentActivityLine: String? {
        guard let sessions = model.status?.agents, !sessions.isEmpty else { return nil }
        let names = Set(sessions.map(\.agent.displayName)).sorted().formatted(.list(type: .and))
        if model.status?.keepingAwakeForAgents == true {
            return String(localized: "Lid closed, staying awake for \(names)")
        }
        return String(localized: "Working now: \(names)")
    }
}

/// Safety: guards that end staying awake with the lid closed (spec E1, E2, E3, E5).
struct SafetyTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                OptionRow(title: "Sleep when the battery falls below",
                          note: "Ends staying awake to keep enough battery.") {
                    Picker("Sleep when the battery falls below", selection: setting(model, \.batteryFloorPercent)) {
                        ForEach(ClamStopSettings.batteryFloorChoices, id: \.self) { Text(verbatim: "\($0) %").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                ToggleRow(title: "Sleep when the Mac gets hot",
                          note: "With the lid closed, a warm Mac goes to sleep to cool down.",
                          isOn: setting(model, \.heatGuard))
                ToggleRow(title: "Sleep when the power adapter is unplugged",
                          note: "Only while staying awake with the lid closed.",
                          isOn: setting(model, \.onlyWhileCharging))
                OptionRow(title: "Longest time to stay awake",
                          note: "Ends staying awake with the lid closed after this time.") {
                    Picker("Longest time to stay awake", selection: setting(model, \.maxAwakeHours)) {
                        ForEach(ClamStopSettings.maxAwakeHourChoices, id: \.self) { hours in
                            Text(hoursTitle(hours)).tag(hours)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } footer: {
                Footnote("These guards are on by default.")
            }
            .disabled(!model.serviceRunning)
        }
    }

    private func hoursTitle(_ hours: Int) -> String {
        switch hours {
        case 0: String(localized: "No limit")
        case 1: String(localized: "1 hour")
        default: String(localized: "\(hours) hours")
        }
    }
}

/// Actions: hibernate when the battery is low (spec B3).
struct ActionsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                OptionRow(title: "Hibernate when the battery is low",
                          note: "On battery, at this level or below, your Mac stops using the battery completely when you close the lid.") {
                    HStack {
                        Picker("Battery level for hibernation", selection: setting(model, \.lowBatteryPercent)) {
                            ForEach([5, 10, 15, 20, 25, 30], id: \.self) { Text(verbatim: "\($0) %").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!model.settings.lowBatteryHibernation)
                        Toggle("Hibernate when the battery is low", isOn: setting(model, \.lowBatteryHibernation))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }
            .disabled(!model.serviceRunning || !model.settings.enabled)
        }
    }
}

/// Automation: AI agent hooks (spec I5).
struct AutomationTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                OptionRow(title: "AI agent hooks", note: note) {
                    if model.agentHooksInstalled {
                        Button("Remove Hooks") { model.setAgentHooks(installed: false) }
                    } else {
                        Button("Install Hooks…") { model.confirmAgentHooks = true }
                            .disabled(model.agentsFound.isEmpty)
                    }
                }
            }
        }
    }

    private var note: LocalizedStringKey {
        if model.agentsFound.isEmpty { return "Claude Code and Codex were not found on this Mac." }
        if model.agentHooksInstalled { return "Installed: Claude Code and Codex tell ClamStop when they work." }
        return "Adds ClamStop to Claude Code and Codex. You see the change first."
    }
}

/// Journal: recent sleeps (spec H3).
struct JournalTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                OptionRow(title: "Sleep journal",
                          note: "When your Mac slept, woke and hibernated, and the battery used. Kept for 30 days, on this Mac only.") {
                    Button("Show…") {
                        model.loadSleepLog()
                        model.showSleepLog = true
                    }
                    .disabled(!model.serviceRunning)
                    .popover(isPresented: $model.showSleepLog, arrowEdge: .bottom) {
                        SleepHistoryView(sessions: SleepLog.sessions(from: model.sleepLog))
                    }
                }
            }
        }
    }
}

/// Help popover next to "Stay awake while AI agents work".
struct AgentHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About AI agents")
                .font(.headline)
            Text("Close the lid while Claude Code or Codex is working: your Mac stays awake until the task ends, then goes to sleep as usual.")
            Text("ClamStop adds a small hook to the agents’ settings (~/.claude/settings.json, ~/.codex/hooks.json): the agent tells ClamStop when a task starts and ends. ClamStop also checks that the agent process is still running and still busy, so a crashed agent does not keep your Mac awake.")
            Text("The guards of the Safety tab still apply: low battery, heat, power adapter unplugged, longest time.")
            Text("Based on ideas from clamshut by Ishaan Chamoli (MIT license).")
                .foregroundStyle(.secondary)
            Link("github.com/IshaanChamoli/clamshut", destination: URL(string: "https://github.com/IshaanChamoli/clamshut")!)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320, alignment: .leading)
        .padding(16)
    }
}

/// Recent sleeps: when, how long, battery used, hibernation.
struct SleepHistoryView: View {
    let sessions: [SleepSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sleep journal")
                .font(.headline)
            if sessions.isEmpty {
                Text("No sleep recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Start")
                        Text("Duration")
                        Text("Battery")
                        Text("")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(sessions.prefix(15)) { session in
                        GridRow {
                            Text(session.start.formatted(date: .abbreviated, time: .shortened))
                            Text(duration(session))
                                .monospacedDigit()
                            Text(session.batteryUsed.map { String(localized: "−\($0) %") } ?? "–")
                                .monospacedDigit()
                            Text(session.hibernated ? String(localized: "Hibernated") : "")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .fixedSize()
        .padding(16)
    }

    private func duration(_ session: SleepSession) -> String {
        guard let end = session.end else { return String(localized: "Asleep") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: end.timeIntervalSince(session.start)) ?? "–"
    }
}

/// "Stay Awake > Until…" (spec C1): stay awake until a time of day.
struct SessionUntilView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void

    /// The chosen time today, or tomorrow when it has already passed.
    private var endDate: Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: model.sessionUntil)
        let now = Date()
        let today = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keep your Mac awake until:")
            DatePicker("Time", selection: $model.sessionUntil, displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .labelsHidden()
            Text(Calendar.current.isDateInToday(endDate) ? "Today" : "Tomorrow")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Stay Awake") {
                    model.startSession(until: endDate)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}
