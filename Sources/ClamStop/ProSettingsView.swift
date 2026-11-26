import SwiftUI
import ClamStopShared

/// The "Pro" tab of the settings window. Every control goes through `Entitlement.isUnlocked`
/// (the daemon checks again before acting).
struct ProSettingsView: View {
    @ObservedObject var model: AppModel

    private var settings: ClamStopSettings { model.settings }
    private var running: Bool { model.serviceState == .running && model.enabled }

    var body: some View {
        Form {
            agentSection
            powerSourceSection
            lowBatterySection
            exceptionsSection
            historySection
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: AI agents

    private var agentSection: some View {
        Section {
            HStack(spacing: 6) {
                Text("Stay awake while AI agents work")
                    .accessibilityHidden(true)  // the switch carries the same label
                HelpButton("About AI agents", isPresented: $model.showAgentHelp) { AgentHelpView() }
                Spacer()
                Toggle("Stay awake while AI agents work", isOn: Binding(
                    get: { settings.keepAwakeForAgents && model.agentHooksInstalled },
                    set: { on in
                        model.setAgentHooks(installed: on)
                        model.changeSettings { $0.keepAwakeForAgents = on }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!running || model.agentsFound.isEmpty || !model.isUnlocked(.agentKeepAwake))
            }
            if settings.keepAwakeForAgents && model.agentHooksInstalled {
                Picker("Stay awake at most", selection: Binding(
                    get: { settings.agentMaxHours },
                    set: { hours in model.changeSettings { $0.agentMaxHours = hours } }
                )) {
                    ForEach(ClamStopSettings.agentMaxHourChoices, id: \.self) { hours in
                        Text(hours == 0 ? String(localized: "No limit") : AppModel.delayLabel(hours * 60)).tag(hours)
                    }
                }
                .disabled(!running || !model.isUnlocked(.agentKeepAwake))
                if let line = agentActivityLine {
                    Text(line)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            SectionHeader("AI agents", feature: .agentKeepAwake)
        } footer: {
            if model.agentsFound.isEmpty {
                Footnote("Works with Claude Code and Codex. Neither was found on this Mac.")
            } else {
                Footnote("With the lid closed, the Mac stays awake until \(agentNames) finishes, then sleeps. On battery, it sleeps below 20 %.")
            }
        }
    }

    private var agentNames: String {
        model.agentsFound.map(\.displayName).formatted(.list(type: .or))
    }

    private var agentActivityLine: String? {
        guard let sessions = model.status?.agents, !sessions.isEmpty else { return nil }
        let names = Set(sessions.map(\.agent.displayName)).sorted().formatted(.list(type: .and))
        if model.status?.keepingAwakeForAgents == true {
            return String(localized: "Lid closed, staying awake for \(names)")
        }
        return String(localized: "Working now: \(names)")
    }

    // MARK: Power source, battery, exceptions

    private var powerSourceSection: some View {
        Section {
            proToggle("Separate settings on battery", feature: .powerSourceSettings,
                      isOn: settings.separateBatterySettings) { on in
                model.changeSettings { $0.separateBatterySettings = on }
            }
            if settings.separateBatterySettings {
                Toggle("Sleep when the lid closes on power adapter", isOn: Binding(
                    get: { settings.onPowerAdapterEnabled },
                    set: { on in model.changeSettings { $0.onPowerAdapterEnabled = on } }
                ))
                .disabled(!running)
                Toggle("Sleep when the lid closes on battery", isOn: Binding(
                    get: { settings.battery.enabled },
                    set: { on in model.changeSettings { $0.battery.enabled = on } }
                ))
                .disabled(!running)
                Picker("Hibernate on battery", selection: Binding(
                    get: { settings.battery.hibernateDelayMinutes },
                    set: { minutes in model.changeSettings { $0.battery.hibernateDelayMinutes = minutes } }
                )) {
                    ForEach(AppModel.delayChoices, id: \.self) { minutes in
                        Text(delayPickerLabel(minutes)).tag(minutes)
                    }
                }
                .disabled(!running || !settings.battery.enabled)
            }
        } header: {
            SectionHeader("Power source", feature: .powerSourceSettings)
        } footer: {
            if settings.separateBatterySettings {
                Footnote("On power adapter, the Hibernate setting of the General tab applies.")
            }
        }
    }

    private var lowBatterySection: some View {
        Section {
            HStack {
                Text("Hibernate at once at")
                    .accessibilityHidden(true)
                Picker("Battery level for immediate hibernation", selection: Binding(
                    get: { settings.lowBatteryPercent },
                    set: { percent in model.changeSettings { $0.lowBatteryPercent = percent } }
                )) {
                    ForEach([5, 10, 15, 20, 25, 30], id: \.self) { percent in
                        Text("\(percent) %").tag(percent)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!running || !model.isUnlocked(.lowBatteryHibernation))
                Text("battery or less")
                    .accessibilityHidden(true)
                Spacer()
                proToggle("Hibernate at once when the battery is low", feature: .lowBatteryHibernation,
                          isOn: settings.lowBatteryHibernation) { on in
                    model.changeSettings { $0.lowBatteryHibernation = on }
                }
                .labelsHidden()
                .toggleStyle(.switch)
            }
        } header: {
            SectionHeader("Low battery", feature: .lowBatteryHibernation)
        }
    }

    private var exceptionsSection: some View {
        Section {
            HStack {
                Text("Don’t force sleep from")
                    .accessibilityHidden(true)
                timePicker("Start of the time without forced sleep", minutes: settings.timeRange.startMinutes) { m in
                    model.changeSettings { $0.timeRange.startMinutes = m }
                }
                Text("to")
                    .accessibilityHidden(true)
                timePicker("End of the time without forced sleep", minutes: settings.timeRange.endMinutes) { m in
                    model.changeSettings { $0.timeRange.endMinutes = m }
                }
                Spacer()
                proToggle("Don’t force sleep during set hours", feature: .schedules,
                          isOn: settings.timeRange.enabled) { on in
                    model.changeSettings { $0.timeRange.enabled = on }
                }
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if settings.timeRange.enabled {
                Toggle("Monday to Friday only", isOn: Binding(
                    get: { settings.timeRange.weekdaysOnly },
                    set: { on in model.changeSettings { $0.timeRange.weekdaysOnly = on } }
                ))
                .disabled(!running)
                Toggle("Only on power adapter", isOn: Binding(
                    get: { settings.timeRange.onPowerAdapterOnly },
                    set: { on in model.changeSettings { $0.timeRange.onPowerAdapterOnly = on } }
                ))
                .disabled(!running)
            }

            ForEach(displayChoices, id: \.self) { name in
                proToggle("Don’t force sleep while \(name) is connected", feature: .schedules,
                          isOn: settings.displayExceptions.contains(name)) { on in
                    model.changeSettings { s in
                        s.displayExceptions.removeAll { $0 == name }
                        if on { s.displayExceptions.append(name) }
                    }
                }
            }
        } header: {
            SectionHeader("Exceptions", feature: .schedules)
        } footer: {
            Footnote("During an exception, closing the lid does what macOS does on its own: with an external display, the Mac stays awake.")
        }
    }

    /// Connected external displays, plus the ones already chosen (even when unplugged).
    private var displayChoices: [String] {
        let connected = model.status?.connectedDisplays ?? []
        return (connected + settings.displayExceptions.filter { !connected.contains($0) })
    }

    // MARK: Sleep history

    private var historySection: some View {
        Section {
            HStack {
                Text("Sleeps, wakes and battery used")
                Spacer()
                Button("Show…") {
                    model.loadSleepLog()
                    model.showSleepLog = true
                }
                .disabled(model.serviceState != .running || !model.isUnlocked(.sleepLog))
                .popover(isPresented: $model.showSleepLog, arrowEdge: .bottom) {
                    SleepHistoryView(sessions: SleepLog.sessions(from: model.sleepLog))
                }
            }
        } header: {
            SectionHeader("Sleep history", feature: .sleepLog)
        }
    }

    // MARK: Helpers

    private func proToggle(_ title: LocalizedStringKey, feature: ProFeature, isOn: Bool,
                           set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: set))
            .disabled(!running || !model.isUnlocked(feature))
    }

    private func timePicker(_ label: LocalizedStringKey, minutes: Int, set: @escaping (Int) -> Void) -> some View {
        DatePicker(label, selection: Binding(
            get: {
                Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .disabled(!running || !model.isUnlocked(.schedules))
    }

    private func delayPickerLabel(_ minutes: Int) -> String {
        if minutes < 0 { return String(localized: "Never") }
        if minutes == 0 { return String(localized: "Immediately") }
        return String(localized: "after \(AppModel.delayLabel(minutes))")
    }
}

/// Section title with a lock while the feature is locked.
struct SectionHeader: View {
    let title: LocalizedStringKey
    let feature: ProFeature

    init(_ title: LocalizedStringKey, feature: ProFeature) {
        self.title = title
        self.feature = feature
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if !Entitlement.isUnlocked(feature) {
                ProBadge(feature: feature)
            }
        }
    }
}

/// "Pro" capsule, with a lock while the feature is locked.
struct ProBadge: View {
    let feature: ProFeature

    var body: some View {
        let locked = !Entitlement.isUnlocked(feature)
        HStack(spacing: 2) {
            if locked {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
            }
            Text("Pro")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(locked ? Text("Pro feature, locked") : Text("Pro feature"))
    }
}

/// Help popover next to "Stay awake while AI agents work".
struct AgentHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About AI agents")
                .font(.headline)
            Text("Close the lid while Claude Code or Codex is working: the Mac stays awake until the task ends, then goes to sleep and hibernates as usual.")
            Text("ClamStop adds a small hook to the agents’ settings (~/.claude/settings.json, ~/.codex/hooks.json): the agent tells ClamStop when a task starts and ends. ClamStop also checks that the agent process is still running and still busy, so a crashed agent does not keep the Mac awake.")
            Text("For safety, the Mac sleeps anyway after the time limit, below 20 % battery, or when it gets too hot.")
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
            Text("Sleep history")
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
