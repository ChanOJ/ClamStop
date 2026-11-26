import SwiftUI
import ClamStopShared

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(DefaultsKey.menuBarIconStyle) private var menuBarIconStyle = MenuBarIconStyle.laptop
    @AppStorage(DefaultsKey.pauseAudio) private var pauseAudio = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Text("Sleep when the lid closes")
                        .accessibilityHidden(true)  // the switch carries the same label
                    HelpButton("Why ClamStop?", isPresented: $model.showLidHelp) { LidHelpView() }
                    Spacer()
                    Toggle("Sleep when the lid closes", isOn: Binding(
                        get: { model.enabled },
                        set: { model.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.serviceState != .running)
                }
                Picker("Hibernate", selection: Binding(
                    get: { model.delayMinutes },
                    set: { model.setDelay(minutes: $0) }
                )) {
                    ForEach(delayChoices, id: \.self) { minutes in
                        Text(pickerLabel(minutes)).tag(minutes)
                    }
                }
                .disabled(!model.enabled || model.serviceState != .running)
                HStack(spacing: 6) {
                    Text("Pause audio while the Mac sleeps")
                        .accessibilityHidden(true)  // the switch carries the same label
                    HelpButton("Why pause audio?", isPresented: $model.showAudioHelp) { AudioHelpView() }
                    Spacer()
                    Toggle("Pause audio while the Mac sleeps", isOn: $pauseAudio)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!model.enabled || model.delayMinutes == ClamStopSettings.never)
                }
            } footer: {
                Footnote("Even with an external display connected, closing the lid puts the Mac to sleep. After the delay, it hibernates: memory is saved to disk and the battery is no longer used.")
            }

            Section {
                Toggle("Show icon in the menu bar", isOn: $showMenuBarIcon)
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
            } footer: {
                if !showMenuBarIcon {
                    Footnote("To change these settings later, open ClamStop again from the Applications folder.")
                }
            }

            Section("Background service") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: model.statusIsOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.statusIsOK ? .green : .orange)
                        .accessibilityHidden(true)  // the text says the same
                    Text(model.statusLine)
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
            }

            Section {
                HStack {
                    Spacer()
                    Button("Uninstall ClamStop…", role: .destructive) { model.confirmUninstall = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Uninstall ClamStop?", isPresented: $model.confirmUninstall) {
            Button("Uninstall", role: .destructive) { model.uninstall() }
        } message: {
            Text("ClamStop restores the default sleep settings, removes its background service and login item, then quits. To finish, move ClamStop from the Applications folder to the Trash.")
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

    /// The standard choices, plus the current value if it was set some other way; "Never" last.
    private var delayChoices: [Int] {
        var choices = AppModel.delayChoices
        if !choices.contains(model.delayMinutes) {
            choices.insert(model.delayMinutes, at: choices.firstIndex { $0 > model.delayMinutes } ?? choices.count - 1)
        }
        return choices
    }

    private func pickerLabel(_ minutes: Int) -> String {
        if minutes < 0 { return String(localized: "Never") }
        if minutes == 0 { return String(localized: "Immediately") }
        return String(localized: "after \(AppModel.delayLabel(minutes))")
    }
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

/// Help popover next to "Pause audio while the Mac sleeps".
struct AudioHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why pause audio?")
                .font(.headline)
            Text("To hibernate after the delay, the Mac wakes up for a moment and goes straight back to sleep. During that wake, music that was playing when the lid closed can be heard for about half a second.")
            Text("With this option, ClamStop pauses playback when the lid closes and resumes it when you open the lid.")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320, alignment: .leading)
        .padding(16)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void

    var body: some View {
        Text(model.statusLine)
        Divider()
        Toggle("Sleep When the Lid Closes", isOn: Binding(
            get: { model.enabled },
            set: { model.setEnabled($0) }
        ))
        .disabled(model.serviceState != .running)
        Divider()
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Button("Quit ClamStop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
