import SwiftUI
import ClamStopShared

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some View {
        Form {
            Section {
                Toggle("Sleep when the lid closes", isOn: Binding(
                    get: { model.enabled },
                    set: { model.setEnabled($0) }
                ))
                Picker("Hibernate", selection: Binding(
                    get: { model.delayMinutes },
                    set: { model.setDelay(minutes: $0) }
                )) {
                    ForEach(delayChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? String(localized: "Never") : String(localized: "after \(AppModel.delayLabel(minutes))"))
                            .tag(minutes)
                    }
                }
                .disabled(!model.enabled)
            } footer: {
                Text("Even with an external display connected, closing the lid puts the Mac to sleep. After the delay, it hibernates: memory is saved to disk and the battery is no longer used.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.serviceState != .running)

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
                    Text("Allow ClamStop in System Settings > General > Login Items & Extensions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
                case .notRegistered:
                    Button("Install Background Service") { model.installService() }
                case .notResponding:
                    Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
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

    /// The standard choices, plus the current value if it was set some other way.
    private var delayChoices: [Int] {
        var choices = AppModel.delayChoices
        if !choices.contains(model.delayMinutes) {
            choices.append(model.delayMinutes)
            choices.sort()
        }
        return choices
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
