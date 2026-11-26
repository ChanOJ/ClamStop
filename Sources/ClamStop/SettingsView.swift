import SwiftUI
import ClamStopShared

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(DefaultsKey.pauseAudio) private var pauseAudio = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Text("Sleep when the lid closes")
                    Button {
                        model.showLidHelp.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Why ClamStop?")
                    .accessibilityLabel("Why ClamStop?")
                    .popover(isPresented: $model.showLidHelp, arrowEdge: .bottom) {
                        LidHelpView()
                    }
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
                Toggle("Pause audio while the Mac sleeps", isOn: $pauseAudio)
                    .disabled(!model.enabled || model.delayMinutes == ClamStopSettings.never)
                    .help("Pauses playback when the lid closes and resumes it when the lid opens, so no sound plays during the short wake before hibernation.")
            } footer: {
                Text("Even with an external display connected, closing the lid puts the Mac to sleep. After the delay, it hibernates: memory is saved to disk and the battery is no longer used.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Show icon in the menu bar", isOn: $showMenuBarIcon)
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            } footer: {
                if !showMenuBarIcon {
                    Text("To change these settings later, open ClamStop again from the Applications folder.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Background service") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: model.statusIsOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.statusIsOK ? .green : .orange)
                    Text(model.statusLine)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                switch model.serviceState {
                case .requiresApproval:
                    Text("Allow ClamStop in System Settings > General > Login Items & Extensions: turn the ClamStop switch on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Copied into Contents/Resources by scripts/build-app.sh; absent outside the bundle.
                    if let image = NSImage(named: "allow-background-service") {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("The ClamStop switch to turn on in System Settings")
                    }
                    Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
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

struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.statusIsOK ? "laptopcomputer" : "laptopcomputer.slash")
            .accessibilityLabel("ClamStop")
    }
}
