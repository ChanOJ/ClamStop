import SwiftUI
import ClamStopShared

/// Content of the settings window: a tab bar over seven tabs (spec section 5, mockup
/// `SettingsMockupView`). Only settings with real behavior behind them are shown.
struct SettingsRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $model.settingsTab)
            Divider()
            Group {
                switch model.settingsTab {
                case .general: GeneralTab(model: model)
                case .sessions: StayAwakeTab(model: model)
                case .rules: RulesTab(model: model)
                case .safety: SafetyTab(model: model)
                case .actions: ActionsTab(model: model)
                case .automation: AutomationTab(model: model)
                case .journal: JournalTab(model: model)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 580)
        .confirmationDialog("Uninstall ClamStop?", isPresented: $model.confirmUninstall) {
            Button("Uninstall", role: .destructive) { model.uninstall() }
        } message: {
            Text("ClamStop restores the default sleep settings, removes its background service and login item, then quits. To finish, move ClamStop from the Applications folder to the Trash.")
        }
        .confirmationDialog("Install the AI agent hooks?", isPresented: $model.confirmAgentHooks) {
            Button("Install Hooks") { model.setAgentHooks(installed: true) }
        } message: {
            Text("ClamStop adds one hook to \(model.agentHookFiles.formatted(.list(type: .and))), so the agents tell it when a task starts and ends. Your other settings stay as they are, and a backup copy is kept next to each file.")
        }
        .alert("ClamStop", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { model.refresh() }
    }
}

/// Tabs of the settings window (also used by the mockups).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case sessions
    case rules
    case safety
    case actions
    case automation
    case journal

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .sessions: "Stay Awake"
        case .rules: "Rules"
        case .safety: "Safety"
        case .actions: "Actions"
        case .automation: "Automation"
        case .journal: "Journal"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sessions: "cup.and.saucer"
        case .rules: "list.bullet.rectangle"
        case .safety: "checkmark.shield"
        case .actions: "bolt"
        case .automation: "keyboard"
        case .journal: "book"
        }
    }

    /// `--tab <name>` (previews and snapshots), otherwise General.
    static var initial: SettingsTab {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--tab"), i + 1 < args.count else { return .general }
        return SettingsTab(rawValue: args[i + 1]) ?? .general
    }
}

/// Tab bar at the top of the settings window, in the style of macOS settings toolbars.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = selection == tab
                Button {
                    selection = tab
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
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}

/// General: the live sentence, the simple settings, the background service, the donation link.
struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(DefaultsKey.menuBarIconStyle) private var menuBarIconStyle = MenuBarIconStyle.laptop

    private var settings: ClamStopSettings { model.settings }

    var body: some View {
        Form {
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

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Picker("When I close the lid", selection: Binding(
                            get: { settings.enabled },
                            set: { model.setEnabled($0) }
                        )) {
                            Text("Sleep, even with a screen plugged in").tag(true)
                            Text("Do what macOS does").tag(false)
                        }
                        HelpButton("Why ClamStop?", isPresented: $model.showLidHelp) { LidHelpView() }
                    }
                    Footnote(settings.enabled
                             ? "Like a MacBook with nothing connected: close the lid and it sleeps."
                             : "ClamStop does nothing when you close the lid.")
                }
                .disabled(!model.serviceRunning)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Hibernate", selection: Binding(
                        get: { model.delayMinutes },
                        set: { model.setDelay(minutes: $0) }
                    )) {
                        ForEach(delayChoices(current: model.delayMinutes), id: \.self) { minutes in
                            Text(AppModel.delayTitle(minutes)).tag(minutes)
                        }
                    }
                    Footnote("After this time asleep, your Mac saves its memory to disk and stops using the battery completely (hibernation).")
                }
                .disabled(!model.serviceRunning || !settings.enabled)
                Toggle("Show in the menu bar", isOn: $showMenuBarIcon)
                    .toggleStyle(.switch)
                Picker("Menu bar icon", selection: $menuBarIconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Label {
                            Text(style.title)
                        } icon: {
                            Image(nsImage: style.image(active: true))
                        }
                        .tag(style)
                    }
                }
                .disabled(!showMenuBarIcon)
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
            } footer: {
                if !showMenuBarIcon {
                    Footnote("To change these settings later, open ClamStop again from the Applications folder.")
                }
            }

            UpdatesSettingsView(updater: .shared)

            ServiceSection(model: model)
        }
    }
}

/// Background service state and approval, uninstall, and the donation link (full edition).
private struct ServiceSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: model.statusIsOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.statusIsOK ? .green : .orange)
                    .accessibilityHidden(true)  // the text says the same
                Text(model.serviceRunning ? String(localized: "Background service running") : model.statusLine)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            switch model.serviceState {
            case .requiresApproval:
                Footnote("Allow ClamStop in System Settings > General > Login Items & Extensions: turn the ClamStop switch on.")
                ApprovalIllustration()
                HStack {
                    Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
                    Button("Reinstall Background Service") { model.reinstallService() }
                }
                Footnote("Already turned on? After an update, use Reinstall Background Service, then turn ClamStop on again if asked.")
            case .notRegistered:
                Button("Install Background Service") { model.installService() }
            case .notResponding:
                HStack {
                    Button("Reinstall Background Service") { model.reinstallService() }
                    Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
                }
            default:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Uninstall ClamStop…", role: .destructive) { model.confirmUninstall = true }
            }
        } footer: {
            if Edition.current == .full {
                DonationLink(text: "ClamStop is free. A coffee helps pay for the developer account and the time spent designing and building it.")
                    .padding(.top, 4)
            }
        }
    }
}

/// Discreet "Buy me a coffee" link (full edition only, spec J6): never a pop-up or a reminder.
struct DonationLink: View {
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 4) {
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Link("Buy me a coffee", destination: Links.donation)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
    }
}

/// Hibernation delays offered, plus the current value if it was set some other way; "Never" last.
func delayChoices(current: Int) -> [Int] {
    var choices = ClamStopSettings.delayChoices
    if !choices.contains(current) {
        choices.insert(current, at: choices.firstIndex { $0 > current } ?? choices.count - 1)
    }
    return choices
}

/// Secondary text under a setting, wrapping and leading-aligned (grouped form footers are
/// trailing-aligned by default).
struct Footnote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ⓘ button that opens a help popover; its title is the tooltip and the VoiceOver label.
struct HelpButton<Content: View>: View {
    let title: LocalizedStringKey
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _isPresented = isPresented
        self.content = content
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom, content: content)
    }
}

/// Help popover next to "Sleep when the lid closes".
/// Keep this text identical to the opening paragraphs of README.md (see CLAUDE.md).
struct LidHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why ClamStop?")
                .font(.headline)
            Text("When a MacBook is connected to an external display, macOS keeps it awake after the lid closes (clamshell mode). Since macOS 26 Tahoe, there is no longer a setting to turn this off.")
            Text("With ClamStop, closing the lid always puts the Mac to sleep, as it does when nothing is connected. Open the lid or press a key to wake it.")
            Text("After the chosen delay, the Mac hibernates: the content of its memory is saved to disk and it stops drawing power, which spares the battery. Waking up then takes a few seconds longer.")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320, alignment: .leading)
        .padding(16)
    }
}

/// Menu bar menu (spec section 5 "Menu bar menu").
struct MenuContent: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let openAbout: () -> Void

    var body: some View {
        Text(model.statusLine)
        if let detail = model.menuDetail {
            Text(detail)
        }
        Divider()
        Button { model.sleepNow() } label: { Label("Sleep Now", systemImage: "moon") }
            .disabled(!model.serviceRunning)
        if Edition.current.hasBackgroundService {
            Button { model.hibernateNow() } label: { Label("Hibernate Now", systemImage: "snowflake") }
                .disabled(!model.serviceRunning)
        }
        Divider()
        Button { openAbout() } label: { Label("About ClamStop", systemImage: "info.circle") }
        Button { openSettings() } label: { Label("Settings…", systemImage: "gearshape") }
            .keyboardShortcut(",")
        CheckForUpdatesMenuItem(updater: .shared)
        Button { NSApp.terminate(nil) } label: { Label("Quit ClamStop", systemImage: "door.left.hand.open") }
            .keyboardShortcut("q")
    }
}
