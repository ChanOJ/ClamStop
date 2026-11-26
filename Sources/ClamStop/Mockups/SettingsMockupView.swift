import SwiftUI

/// Settings window of the spec (section 5 "Main window"): a live sentence, the simple settings,
/// then the other options in tabs. Full edition: a discreet donation link at the bottom of General.
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
                    if full { serviceSection }
                case .sessions: sessionsSection
                case .rules: rulesSection
                case .safety: safetySection
                case .actions: actionsSection
                case .automation: automationSection
                case .journal: journalSection
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
                        Text(action.title(edition: model.edition))
                            .tag(action)
                    }
                }
                Footnote(LocalizedStringKey(model.lidAction.explanation(edition: model.edition)))
            }
            if full {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Hibernate", selection: $model.hibernateDelay) {
                        ForEach(HibernateDelay.allCases) { delay in
                            Text(delay.title).tag(delay)
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
                      note: "A click starts or stops staying awake; Control-click or right-click opens the menu.",
                      isOn: $model.options.clickToToggle)
            if full {
                ToggleRow(title: "Stay awake with the lid closed on battery too",
                          note: "Without this, closing the lid on battery puts your Mac to sleep, even while you stay awake.", isOn: $model.options.sessionsOnBattery)
            }
            OptionRow(title: "Screens while staying awake",
                      note: "With the lid closed, the built-in screen always turns off.") {
                Picker("Screens while staying awake", selection: $model.options.screenPolicy) {
                    Text("Let them sleep").tag(0)
                    Text("Keep them on").tag(1)
                }
                .labelsHidden()
                .fixedSize()
            }
            ToggleRow(title: "Remind me 5 minutes before the end",
                      note: "With a button to add 30 minutes.", isOn: $model.options.endReminder)
            ToggleRow(title: "Stay awake while AI agents work",
                      note: "Claude Code, Codex and others. Your Mac sleeps when they are all done.", isOn: $model.options.agentsAwake)
            OptionRow(title: "Stay awake while these apps work",
                      note: "For example HandBrake, Final Cut Pro, Blender or Ollama. While one of them is busy, your Mac stays awake, even with the lid closed.") {
                Button("Choose Apps…") {}
            }
        }
    }

    private var rulesSection: some View {
        Section {
            OptionRow(title: "Presets",
                      note: "Ready-made rules in one click.") {
                Menu("Add Preset") {
                    Button("Desk with a screen") {}
                    Button("Overnight work on power") {}
                    Button("AI agents") {}
                    Button("Home server") {}
                }
                .fixedSize()
            }
            ToggleRow(title: "Different settings on battery",
                      note: "Choose another lid action and hibernation delay when unplugged.", isOn: $model.options.separateOnBattery)
            OptionRow(title: "Rules",
                      note: "When conditions are true (power, screen, Wi-Fi, app, time), use other settings.") {
                Button("Add Rule…") {}
            }
            if full {
                OptionRow(title: "Schedule",
                          note: "Sleep or wake your Mac at set times.") {
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
                      note: "While staying awake with the lid closed.", isOn: $model.options.lockOnClose)
            OptionRow(title: "Run a shortcut",
                      note: "When the lid opens or closes, or when the Mac sleeps or wakes.") {
                Button("Choose…") {}
            }
            if full {
                ToggleRow(title: "Hibernate when the battery is low",
                          note: "Below 10 %, your Mac stops using the battery completely while asleep.", isOn: $model.options.hibernateOnLowBattery)
                ToggleRow(title: "Use Low Power Mode with the lid closed",
                          note: "While staying awake; restored when you open the lid.", isOn: $model.options.lowPowerMode)
            }
        }
    }

    private var automationSection: some View {
        Section {
            OptionRow(title: "Keyboard shortcut to stay awake",
                      note: "Starts or stops staying awake from any app.") {
                Button("Record Shortcut") {}
            }
            OptionRow(title: "Keyboard shortcut to sleep now") {
                Button("Record Shortcut") {}
            }
            OptionRow(title: "Shortcuts app and Siri",
                      note: "Actions to stay awake, stop and sleep now.") {
                Button("Open Shortcuts") {}
            }
            if full {
                OptionRow(title: "AI agent hooks",
                          note: "Adds ClamStop to Claude Code, Codex and others. You see the change first.") {
                    Button("Install Hooks…") {}
                }
                OptionRow(title: "Command line",
                          note: "The clamstop command for Terminal and scripts.") {
                    Button("Install…") {}
                }
            }
        }
    }

    private var journalSection: some View {
        Section {
            ToggleRow(title: "Keep a sleep journal",
                      note: "When the lid closed, when your Mac slept, woke and hibernated. Kept for 30 days, on this Mac only.", isOn: $model.options.keepJournal)
            OptionRow(title: "Journal file",
                      note: "~/Library/Logs/ClamStop/Journal.csv") {
                HStack {
                    Button("Open") {}
                    Button("Change…") {}
                }
            }
            ToggleRow(title: "Morning report",
                      note: "Battery used overnight and how long your Mac slept.", isOn: $model.options.morningReport)
            OptionRow(title: "What keeps my Mac awake?",
                      note: "Apps that prevent sleep right now.") {
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
        } footer: {
            donationLink
        }
    }

    /// Discreet "Buy me a coffee" link (full edition only, spec J6). Never a pop-up or a reminder.
    private var donationLink: some View {
        VStack(spacing: 4) {
            Text("ClamStop is free. A coffee helps pay for the developer account and the time spent designing and building it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Link("Buy me a coffee", destination: Links.donation)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
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
