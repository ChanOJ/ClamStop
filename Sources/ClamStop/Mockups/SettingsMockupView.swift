import SwiftUI

/// Settings window of the spec (section 5 "Main window"): a live sentence, the simple settings,
/// then "More options" with Pro badges on locked controls and one "Unlock Pro" button.
struct SettingsMockupView: View {
    @ObservedObject var model: MockupModel

    private var full: Bool { model.edition.hasBackgroundService }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(model: model)
            Divider()
            Form {
                switch model.settingsTab {
                case .general:
                    summarySection
                    simpleSettings
                    proSection
                    if full { serviceSection }
                case .sessions: sessionsSection
                case .rules: rulesSection
                case .safety: safetySection
                case .actions: actionsSection
                case .automation: automationSection
                case .journal: journalSection
                }
                if model.settingsTab != .general && model.settingsTab != .safety && !model.isPro {
                    unlockFooter
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 580)
    }

    // MARK: Always visible

    private var summarySection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(model.summary)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
    }

    private var simpleSettings: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Picker("When I close the lid", selection: $model.lidAction) {
                    ForEach(LidAction.allCases) { action in
                        Text(pickerTitle(action.title(edition: model.edition), pro: action.isPro))
                            .tag(action)
                    }
                }
                Footnote(LocalizedStringKey(model.lidAction.explanation(edition: model.edition)))
            }
            if full {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Hibernate", selection: $model.hibernateDelay) {
                        ForEach(HibernateDelay.allCases) { delay in
                            Text(pickerTitle(delay.title, pro: delay.isPro)).tag(delay)
                        }
                    }
                    Footnote("After this time asleep, your Mac saves its memory to disk and stops using the battery completely (hibernation).")
                }
            }
            Toggle("Show in the menu bar", isOn: $model.showInMenuBar)
                .toggleStyle(.switch)
            Toggle("Open at login", isOn: $model.openAtLogin)
                .toggleStyle(.switch)
        }
    }

    // MARK: Other tabs

    private var proSection: some View {
        Section {
            if model.isPro {
                Label("ClamStop Pro is unlocked. Thank you for supporting ClamStop!", systemImage: "checkmark.seal.fill")
                if full {
                    Button("Manage License…") {}
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("ClamStop Pro")
                                .font(.headline)
                            ProBadge()
                        }
                        Text("Unlock every option marked Pro. Sleep on lid close and the safety options stay free.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Unlock Pro…") {}
                        .keyboardShortcut(.defaultAction)
                }
                HStack(spacing: 16) {
                    Link("See all Pro features", destination: model.edition.proFeaturesURL)
                    Button {} label: {
                        full ? Text("Enter License Key…") : Text("Restore Purchase")
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var sessionsSection: some View {
        Section {
            OptionRow(title: "Stay awake by default",
                      note: "Used when you click Stay Awake or the menu bar icon.") {
                Picker("Stay awake by default", selection: $model.options.defaultDuration) {
                    Text("Until I turn it off").tag(0)
                    Text("For 1 hour").tag(60)
                    Text("For 2 hours").tag(120)
                }
                .labelsHidden()
                .fixedSize()
            }
            ToggleRow(title: "Click the icon to stay awake",
                      note: "Click starts or stops staying awake; Control-click opens the menu.",
                      isOn: $model.options.clickToToggle)
            if full {
                ToggleRow(title: "Stay awake with the lid closed on battery too",
                          note: "Without this, closing the lid on battery puts your Mac to sleep, even while you stay awake.",
                          pro: true, locked: model.locked(true), isOn: $model.options.sessionsOnBattery)
            }
            OptionRow(title: "Screens while staying awake",
                      note: "With the lid closed, the built-in screen always turns off.",
                      pro: true, locked: model.locked(true)) {
                Picker("Screens while staying awake", selection: $model.options.screenPolicy) {
                    Text("Let them sleep").tag(0)
                    Text("Keep them on").tag(1)
                }
                .labelsHidden()
                .fixedSize()
            }
            ToggleRow(title: "Remind me 5 minutes before the end",
                      note: "With a button to add 30 minutes.",
                      pro: true, locked: model.locked(true), isOn: $model.options.endReminder)
            ToggleRow(title: "Stay awake while AI agents work",
                      note: "Claude Code, Codex and others. Your Mac sleeps when they are all done.",
                      pro: true, locked: model.locked(true), isOn: $model.options.agentsAwake)
            OptionRow(title: "Stay awake while these apps are open",
                      note: "For example HandBrake, Final Cut Pro, Blender, Xcode or Ollama.",
                      pro: true, locked: model.locked(true)) {
                Button("Choose Apps…") {}
            }
            ToggleRow(title: "Only while they are busy",
                      note: "Your Mac sleeps once the app stops using the processor, even if it stays open.",
                      pro: true, locked: model.locked(true), isOn: $model.options.busyOnly)
        }
    }

    private var rulesSection: some View {
        Section {
            OptionRow(title: "Presets",
                      note: "Ready-made rules in one click. Desk with a screen is free.") {
                Menu("Add Preset") {
                    Button("Desk with a screen") {}
                    Button("Overnight work on power (Pro)") {}
                    Button("AI agents (Pro)") {}
                    Button("Home server (Pro)") {}
                }
                .fixedSize()
            }
            ToggleRow(title: "Different settings on battery",
                      note: "Choose another lid action and hibernation delay when unplugged.",
                      pro: true, locked: model.locked(true), isOn: $model.options.separateOnBattery)
            ToggleRow(title: "Do not force sleep during calls and presentations",
                      note: "Lets macOS decide while a call, a presentation or a chosen app runs.",
                      pro: true, locked: model.locked(true), isOn: $model.options.noSleepDuringCalls)
            OptionRow(title: "Rules",
                      note: "When conditions are true (power, screen, Wi-Fi, app, time), use other settings.",
                      pro: true, locked: model.locked(true)) {
                Button("Add Rule…") {}
            }
            if full {
                OptionRow(title: "Schedule",
                          note: "Sleep or wake your Mac at set times.",
                          pro: true, locked: model.locked(true)) {
                    Button("Edit Schedule…") {}
                }
            }
        }
    }

    private var safetySection: some View {
        Section {
            OptionRow(title: "Sleep when the battery falls below",
                      note: "Ends staying awake to keep enough battery.") {
                Picker("Sleep when the battery falls below", selection: $model.options.batteryFloor) {
                    ForEach([5, 10, 20, 30, 50], id: \.self) { Text(verbatim: "\($0) %").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            ToggleRow(title: "Sleep when the Mac gets hot",
                      note: "With the lid closed, a warm Mac goes to sleep to cool down.",
                      isOn: $model.options.heatGuard)
            ToggleRow(title: "Sleep when the power adapter is unplugged",
                      note: "Only while staying awake with the lid closed.",
                      isOn: $model.options.onlyWhileCharging)
            OptionRow(title: "Longest time to stay awake",
                      note: "Ends any session after this time.") {
                Picker("Longest time to stay awake", selection: $model.options.maxSessionHours) {
                    Text("No limit").tag(0)
                    Text("4 hours").tag(4)
                    Text("12 hours").tag(12)
                }
                .labelsHidden()
                .fixedSize()
            }
        } footer: {
            Footnote("Safety options are free and on by default.")
        }
    }

    private var actionsSection: some View {
        Section {
            ToggleRow(title: "Lock the screen when the lid closes",
                      note: "While staying awake with the lid closed.",
                      pro: true, locked: model.locked(true), isOn: $model.options.lockOnClose)
            OptionRow(title: "Run a shortcut",
                      note: "When the lid opens or closes, or when the Mac sleeps or wakes.",
                      pro: true, locked: model.locked(true)) {
                Button("Choose…") {}
            }
            if full {
                ToggleRow(title: "Hibernate when the battery is low",
                          note: "Below 10 %, your Mac stops using the battery completely while asleep.",
                          pro: true, locked: model.locked(true), isOn: $model.options.hibernateOnLowBattery)
                ToggleRow(title: "Use Low Power Mode with the lid closed",
                          note: "While staying awake; restored when you open the lid.",
                          pro: true, locked: model.locked(true), isOn: $model.options.lowPowerMode)
            }
        }
    }

    private var automationSection: some View {
        Section {
            OptionRow(title: "Keyboard shortcut to stay awake",
                      note: "Starts or stops staying awake from any app.",
                      pro: true, locked: model.locked(true)) {
                Button("Record Shortcut") {}
            }
            OptionRow(title: "Keyboard shortcut to sleep now",
                      pro: true, locked: model.locked(true)) {
                Button("Record Shortcut") {}
            }
            OptionRow(title: "Shortcuts app and Siri",
                      note: "Actions to stay awake, stop and sleep now.",
                      pro: true, locked: model.locked(true)) {
                Button("Open Shortcuts") {}
            }
            if full {
                OptionRow(title: "AI agent hooks",
                          note: "Adds ClamStop to Claude Code, Codex and others. You see the change first.",
                          pro: true, locked: model.locked(true)) {
                    Button("Install Hooks…") {}
                }
                OptionRow(title: "Command line",
                          note: "The clamstop command for Terminal and scripts.",
                          pro: true, locked: model.locked(true)) {
                    Button("Install…") {}
                }
            }
        }
    }

    private var journalSection: some View {
        Section {
            ToggleRow(title: "Keep a sleep journal",
                      note: "When the lid closed, when your Mac slept, woke and hibernated. Kept for 30 days, on this Mac only.",
                      pro: true, locked: model.locked(true), isOn: $model.options.keepJournal)
            OptionRow(title: "Journal file",
                      note: "~/Library/Logs/ClamStop/Journal.csv",
                      pro: true, locked: model.locked(true)) {
                HStack {
                    Button("Open") {}
                    Button("Change…") {}
                }
            }
            ToggleRow(title: "Morning report",
                      note: "Battery used overnight and how long your Mac slept.",
                      pro: true, locked: model.locked(true), isOn: $model.options.morningReport)
            OptionRow(title: "What keeps my Mac awake?",
                      note: "Apps that prevent sleep right now.",
                      pro: true, locked: model.locked(true)) {
                Button("Show…") {}
            }
            OptionRow(title: "Diagnostics",
                      note: "Copies the service state and recent events, for support.") {
                Button("Copy Diagnostics") {}
            }
        }
    }

    private var serviceSection: some View {
        Section {
            Label {
                Text("Background service running")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                Spacer()
                Button("Uninstall ClamStop…", role: .destructive) {}
            }
        }
    }

    /// At the bottom of tabs with locked options; the same single action as on General.
    private var unlockFooter: some View {
        Section {
            HStack {
                Text("Options marked Pro need ClamStop Pro.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Unlock Pro…") {}
            }
        }
    }

    // MARK: Helpers

    private func pickerTitle(_ title: String, pro: Bool) -> String {
        model.locked(pro) ? String(localized: "\(title) (Pro)") : title
    }
}

/// Tab bar at the top of the settings window, in the style of macOS settings toolbars.
/// The real window will use an NSToolbar (or a SwiftUI TabView) with the same tabs.
private struct SettingsTabBar: View {
    @ObservedObject var model: MockupModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = model.settingsTab == tab
                Button {
                    model.settingsTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.title2)
                            .frame(height: 24)
                        Text(tab.title)
                            .font(.caption)
                    }
                    .frame(width: 74, height: 50)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.primary.opacity(0.1) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}
