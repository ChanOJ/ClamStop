import SwiftUI

/// Settings window of the spec (section 5 "Main window"): a live sentence, the simple settings,
/// then "More options" with Pro badges on locked controls and one "Unlock Pro" button.
struct SettingsMockupView: View {
    @ObservedObject var model: MockupModel

    private var full: Bool { model.edition.hasBackgroundService }

    var body: some View {
        Form {
            summarySection
            simpleSettings
            moreOptionsToggle
            if model.showMoreOptions {
                proSection
                sessionsSection
                rulesSection
                safetySection
                actionsSection
                automationSection
                journalSection
                if full { serviceSection }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
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
                    Footnote("After this time asleep, your Mac saves everything to disk and stops using the battery.")
                }
            }
            Toggle("Show in the menu bar", isOn: $model.showInMenuBar)
                .toggleStyle(.switch)
            Toggle("Open at login", isOn: $model.openAtLogin)
                .toggleStyle(.switch)
        }
    }

    private var moreOptionsToggle: some View {
        Section {
            Button {
                model.showMoreOptions.toggle()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("More options")
                        Text("Sessions, rules, safety, actions, automation, journal")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(model.showMoreOptions ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.showMoreOptions ? Text("Expanded") : Text("Collapsed"))
        }
    }

    // MARK: More options

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
                        Text("Unlock every option marked Pro. Sleep on lid close and the safety guards stay free.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Unlock Pro…") {}
                        .keyboardShortcut(.defaultAction)
                }
                Button {} label: {
                    full ? Text("Enter License Key…") : Text("Restore Purchase")
                }
                .buttonStyle(.link)
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
                ToggleRow(title: "Keep working with the lid closed on battery",
                          note: "While you stay awake. On power, this is always allowed.",
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
            OptionRow(title: "Stay awake while these apps run",
                      note: "HandBrake, Final Cut Pro, Blender, Xcode, Ollama…",
                      pro: true, locked: model.locked(true)) {
                Button("Choose Apps…") {}
            }
        } header: {
            SectionHeader(title: "Sessions", symbol: "cup.and.saucer")
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
        } header: {
            SectionHeader(title: "Rules and presets", symbol: "list.bullet.rectangle")
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
            ToggleRow(title: "Warn me if my Mac seems to be in a bag",
                      note: "Lid closed, no screen, not charging: a notification, then sleep.",
                      isOn: $model.options.bagWarning)
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
        } header: {
            SectionHeader(title: "Safety", symbol: "checkmark.shield")
        } footer: {
            Footnote("Safety options are free and on by default.")
        }
    }

    private var actionsSection: some View {
        Section {
            ToggleRow(title: "Pause audio and video while the Mac sleeps",
                      note: "Playback resumes when you open the lid.",
                      pro: true, locked: model.locked(true), isOn: $model.options.pauseAudio)
            ToggleRow(title: "Lock the screen when the lid closes",
                      note: "While staying awake with the lid closed.",
                      pro: true, locked: model.locked(true), isOn: $model.options.lockOnClose)
            OptionRow(title: "Run a shortcut",
                      note: "When the lid opens or closes, or when the Mac sleeps or wakes.",
                      pro: true, locked: model.locked(true)) {
                Button("Choose…") {}
            }
            if full {
                ToggleRow(title: "Save to disk when the battery is low",
                          note: "Below 10 %, your Mac hibernates while asleep.",
                          pro: true, locked: model.locked(true), isOn: $model.options.hibernateOnLowBattery)
                ToggleRow(title: "Use Low Power Mode with the lid closed",
                          note: "While staying awake; restored when you open the lid.",
                          pro: true, locked: model.locked(true), isOn: $model.options.lowPowerMode)
            }
        } header: {
            SectionHeader(title: "Actions", symbol: "bolt")
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
        } header: {
            SectionHeader(title: "Shortcuts and automation", symbol: "keyboard")
        }
    }

    private var journalSection: some View {
        Section {
            ToggleRow(title: "Keep a sleep journal",
                      note: "When the lid closed, when your Mac slept, woke and saved to disk. Stays on this Mac.",
                      pro: true, locked: model.locked(true), isOn: $model.options.keepJournal)
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
        } header: {
            SectionHeader(title: "Journal", symbol: "book")
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
        } header: {
            SectionHeader(title: "Background service", symbol: "gearshape.2")
        }
    }

    // MARK: Helpers

    private func pickerTitle(_ title: String, pro: Bool) -> String {
        model.locked(pro) ? String(localized: "\(title) (Pro)") : title
    }
}
