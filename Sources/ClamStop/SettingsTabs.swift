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

/// Stay Awake: the screens (spec C3), AI agents and their hooks (C7, I5), the watched apps (C5).
struct StayAwakeTab: View {
    @ObservedObject var model: AppModel
    @AppStorage(DefaultsKey.lockOnLidClose) private var lockOnLidClose = false

    var body: some View {
        Form {
            Section {
                OptionRow(title: "Screens while staying awake",
                          note: "For Stay Awake from the menu. With the lid closed, the built-in screen always turns off.") {
                    Picker("Screens while staying awake", selection: setting(model, \.keepScreensOn)) {
                        Text("Let them sleep").tag(false)
                        Text("Keep them on").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!model.serviceRunning)
                if Edition.current == .full {
                    ToggleRow(title: "Lock the screen when the lid closes",
                              note: "While ClamStop keeps your Mac awake with the lid closed. Not with an external screen: you may be working on it.",
                              isOn: $lockOnLidClose)
                }
            }
            Section {
                OptionRow(title: "Stay awake while AI agents work",
                          note: "Claude Code, Codex, Cursor and others. Your Mac sleeps about \(Int(AgentTracker.gracePeriod)) seconds after they are all done, in case one starts again.") {
                    HStack(spacing: 6) {
                        HelpButton("About AI agents", isPresented: $model.showAgentHelp) { AgentHelpView() }
                        Toggle("Stay awake while AI agents work", isOn: setting(model, \.keepAwakeForAgents))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .disabled(!model.serviceRunning)
                // Always there, so the hooks can be removed with the switch off too (spec I5).
                OptionRow(title: "AI agent hooks", note: hooksNote) {
                    HStack {
                        if model.agentHooksInstalled {
                            Button("Remove Hooks") { model.setAgentHooks(installed: false) }
                        }
                        if !model.agentHooksInstalled || !model.agentsMissingHooks.isEmpty {
                            Button("Install Hooks…") { model.confirmAgentHooks = true }
                                .disabled(model.agentsFound.isEmpty)
                        }
                    }
                }
                ForEach(model.agentsFound, id: \.self) { agent in
                    LabeledContent {
                        Text(model.agentHookStates[agent] == .installed ? "Hook installed" : "No hook")
                    } label: {
                        Text(verbatim: agent.displayName)
                    }
                }
                if model.settings.keepAwakeForAgents, model.agentHooksInstalled, let line = agentActivityLine {
                    Label(line, systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Footnote("With the lid closed, your Mac can get hot. Keep it out in the open while agents work: the Safety tab puts it to sleep if it gets too hot.")
            }
            WatchedAppsSection(model: model)
        }
    }

    private var hooksNote: LocalizedStringKey {
        if model.agentsFound.isEmpty { return "No supported AI agent was found on this Mac." }
        if model.agentsMissingHooks.isEmpty { return "Installed: your AI agents tell ClamStop when they work." }
        return "The agents need them to tell ClamStop when they work. You see the change first."
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

/// Safety: guards that end staying awake with the lid closed (spec E1, E2, E3, E5), then
/// hibernation on a low battery.
struct SafetyTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    ToggleRow(title: "Sleep when the Mac gets hot",
                              note: "With the lid closed, a very hot Mac goes to sleep to cool down.",
                              recommended: true,
                              isOn: setting(model, \.heatGuard))
                    if !model.settings.heatGuard {
                        HeatGuardWarning()
                    }
                }
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
            BatteryLevelSection(model: model)
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

/// Shown while the heat guard is off.
private struct HeatGuardWarning: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Warning")
            Text("With this off, your Mac stays awake with the lid closed even when it gets too hot.")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .onAppear { VoiceOver.say(String(localized: "Warning: the heat guard is off")) }
    }
}

/// Battery levels: end staying awake (spec E1), hibernate when low (spec B3).
private struct BatteryLevelSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            OptionRow(title: "Sleep when the battery falls below",
                      note: "Ends staying awake to keep enough battery.",
                      recommended: true) {
                Picker("Sleep when the battery falls below", selection: setting(model, \.batteryFloorPercent)) {
                    Text("Disabled").tag(ClamStopSettings.noBatteryFloor)
                    ForEach(ClamStopSettings.batteryFloorChoices, id: \.self) { Text(verbatim: "\($0) %").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!model.serviceRunning)
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
            .disabled(!model.serviceRunning || !model.settings.enabled)
        }
    }
}

/// Help popover next to "Stay awake while AI agents work".
struct AgentHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About AI agents")
                .font(.headline)
            Text("Close the lid while an AI agent is working: your Mac stays awake until the task ends, then goes to sleep as usual.")
            Text("Supported: \(AgentKind.allCases.map(\.displayName).formatted(.list(type: .and))).")
            Text("With your agreement, ClamStop adds a small hook to each agent’s settings: the agent tells ClamStop when a task starts and ends. ClamStop also checks that the agent is still busy, so a crashed agent does not keep your Mac awake.")
            Text("For Aider, add it under “Stay awake while these apps work”.")
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
