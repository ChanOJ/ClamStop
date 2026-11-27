import SwiftUI
import ClamStopShared

/// Rules: "when conditions are true, do this when the lid closes" (spec D1). The General tab
/// applies when no rule matches.
struct RulesTab: View {
    @ObservedObject var model: AppModel

    private var settings: ClamStopSettings { model.settings }

    var body: some View {
        Form {
            Section {
                OptionRow(title: "Rules",
                          note: "Other choices for a screen, the power source or a time of day. The first rule that matches applies.") {
                    Button("Add Rule…") { model.ruleDraft = Rule() }
                }
                ForEach(Array(settings.rules.enumerated()), id: \.element.id) { index, rule in
                    RuleRow(model: model, rule: rule, index: index, count: settings.rules.count)
                }
            } footer: {
                if !settings.enabled {
                    Footnote("The General tab is set to “Do what macOS does”: rules are not used.")
                } else {
                    Footnote("When no rule matches, the settings of the General tab apply.")
                }
            }
            .disabled(!model.serviceRunning || !settings.enabled)
        }
        .sheet(isPresented: Binding(get: { model.ruleDraft != nil },
                                    set: { if !$0 { model.ruleDraft = nil } })) {
            RuleEditor(model: model)
        }
    }
}

/// One rule: on or off, its conditions and action, order, edit and delete.
private struct RuleRow: View {
    @ObservedObject var model: AppModel
    let rule: Rule
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Use this rule", isOn: Binding(get: { rule.enabled },
                                                  set: { model.setRule(rule, enabled: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(RuleText.conditions(rule))
                    .fixedSize(horizontal: false, vertical: true)
                Text(RuleText.action(rule))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.status?.lidPlan?.rule?.id == rule.id {
                    Label("Applies now", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            iconButton("Move up", "chevron.up") { model.moveRule(rule, by: -1) }
                .disabled(index == 0)
            iconButton("Move down", "chevron.down") { model.moveRule(rule, by: 1) }
                .disabled(index == count - 1)
            Button("Edit…") { model.ruleDraft = rule }
            iconButton("Delete rule", "trash") { model.deleteRule(rule) }
        }
    }

    private func iconButton(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(title)
            .accessibilityLabel(title)
    }
}

/// Sheet to add or change a rule (`AppModel.ruleDraft`).
struct RuleEditor: View {
    @ObservedObject var model: AppModel

    private var draft: Rule { model.ruleDraft ?? Rule() }
    private var isNew: Bool { !model.settings.rules.contains { $0.id == draft.id } }

    private func field<Value>(_ keyPath: WritableKeyPath<Rule, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] },
                set: { value in model.ruleDraft?[keyPath: keyPath] = value })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Rule" : "Edit Rule")
                .font(.headline)
                .padding([.top, .horizontal], 20)
            Form {
                Section("When all of these are true") {
                    Picker("Power", selection: field(\.power)) {
                        Text("Does not matter").tag(Rule.Power?.none)
                        Text("Power adapter").tag(Rule.Power?.some(.adapter))
                        Text("Battery").tag(Rule.Power?.some(.battery))
                    }
                    Picker("External screen", selection: field(\.display)) {
                        Text("Does not matter").tag(Rule.Display?.none)
                        Text("Plugged in").tag(Rule.Display?.some(.connected))
                        Text("Not plugged in").tag(Rule.Display?.some(.notConnected))
                    }
                    Picker("Time", selection: Binding(
                        get: { draft.time != nil },
                        set: { model.ruleDraft?.time = $0 ? TimeWindow(start: 22 * 60, end: 7 * 60) : nil }
                    )) {
                        Text("Does not matter").tag(false)
                        Text("Between two times").tag(true)
                    }
                    if let window = draft.time {
                        timePicker("From", \.start)
                        timePicker("To", \.end)
                        LabeledContent("Days") { DayPicker(model: model) }
                        if window.end < window.start {
                            Footnote("Ends the next day. The days are those it starts on.")
                        } else if window.end == window.start {
                            Footnote("Same start and end: the whole day.")
                        }
                    }
                }
                Section("Then") {
                    Picker("When I close the lid", selection: field(\.action)) {
                        Text("Sleep, even with a screen plugged in").tag(Rule.Action.sleep)
                        Text("Stay awake").tag(Rule.Action.stayAwake)
                        Text("Do what macOS does").tag(Rule.Action.macOS)
                    }
                    if draft.action == .sleep {
                        Picker("Hibernate", selection: field(\.hibernateDelayMinutes)) {
                            ForEach(delayChoices(current: draft.hibernateDelayMinutes), id: \.self) { minutes in
                                Text(AppModel.delayTitle(minutes)).tag(minutes)
                            }
                        }
                    }
                    if draft.action == .stayAwake {
                        stayAwakeNotes
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !draft.isValid {
                    Text(draft.time?.days.isEmpty == true ? "Choose at least one day." : "Choose at least one condition.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.ruleDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.saveRuleDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
            .padding([.bottom, .horizontal], 20)
        }
        .frame(width: 480)
    }

    @ViewBuilder private var stayAwakeNotes: some View {
        Footnote("Your Mac stays awake with the lid closed. Do not put it in a bag. The guards of the Safety tab still apply.")
        let neverOnBattery = model.settings.onlyWhileCharging
        if neverOnBattery, draft.power != .adapter {
            warning("On battery, your Mac still goes to sleep: “Sleep when the power adapter is unplugged” is on in the Safety tab.")
        }
        // Nothing is held for a rule the guard stops anyway, nor with a screen and the adapter.
        if !(draft.power == .adapter && draft.display == .connected), !(neverOnBattery && draft.power == .battery) {
            warning("Without both a screen and the power adapter, your Mac does not go to sleep by itself while this rule applies, even with the lid open, and Apple menu > Sleep does nothing. Use Sleep Now in the ClamStop menu.")
        }
    }

    private func warning(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Warning")
            Footnote(text)
        }
    }

    private func timePicker(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<TimeWindow, Int>) -> some View {
        DatePicker(title, selection: Binding(
            get: { RuleText.date(minute: draft.time?[keyPath: keyPath] ?? 0) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.ruleDraft?.time?[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .datePickerStyle(.stepperField)
    }
}

/// One button per day of the week, in the user's week order.
private struct DayPicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RuleText.weekdays, id: \.self) { day in
                Toggle(RuleText.shortDay(day), isOn: Binding(
                    get: { model.ruleDraft?.time?.days.contains(day) == true },
                    set: { on in
                        if on {
                            model.ruleDraft?.time?.days.insert(day)
                        } else {
                            model.ruleDraft?.time?.days.remove(day)
                        }
                    }))
                    .toggleStyle(.button)
                    .accessibilityLabel(RuleText.fullDay(day))
            }
        }
        .controlSize(.small)
    }
}

/// Rules in plain words.
@MainActor
enum RuleText {
    /// English day names, like the rest of the interface.
    private static let english: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    /// 1...7 (1 = Sunday), starting on the user's first day of the week.
    static var weekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    static func shortDay(_ day: Int) -> String { english.shortWeekdaySymbols[day - 1] }
    static func fullDay(_ day: Int) -> String { english.weekdaySymbols[day - 1] }

    static func date(minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    static func time(_ minute: Int) -> String {
        date(minute: minute).formatted(date: .omitted, time: .shortened)
    }

    static func days(_ days: Set<Int>) -> String {
        switch days {
        case TimeWindow.everyDay: String(localized: "Every day")
        case [2, 3, 4, 5, 6]: String(localized: "Monday to Friday")
        case [1, 7]: String(localized: "Weekends")
        default: weekdays.filter(days.contains).map(shortDay).joined(separator: ", ")
        }
    }

    /// "External screen, on power adapter, every day 22:00–07:00".
    static func conditions(_ rule: Rule) -> String {
        var parts: [String] = []
        switch rule.display {
        case .connected: parts.append(String(localized: "With an external screen"))
        case .notConnected: parts.append(String(localized: "Without an external screen"))
        case nil: break
        }
        switch rule.power {
        case .adapter: parts.append(String(localized: "On power adapter"))
        case .battery: parts.append(String(localized: "On battery"))
        case nil: break
        }
        if let window = rule.time {
            let range = window.start == window.end
                ? String(localized: "all day")
                : "\(time(window.start))–\(time(window.end))"
            parts.append("\(days(window.days)) \(range)")
        }
        return parts.joined(separator: " · ")
    }

    static func action(_ rule: Rule) -> String {
        switch rule.action {
        case .stayAwake: return String(localized: "Stay awake")
        case .macOS: return String(localized: "Do what macOS does")
        case .sleep:
            switch rule.hibernateDelayMinutes {
            case ..<0: return String(localized: "Sleep, never hibernate")
            case 0: return String(localized: "Sleep and hibernate immediately")
            case let minutes:
                let delay = AppModel.delayTitle(minutes).lowercased()
                return String(localized: "Sleep, hibernate \(delay)")
            }
        }
    }
}
