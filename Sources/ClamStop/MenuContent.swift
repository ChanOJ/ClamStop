import SwiftUI
import ClamStopShared

/// Menu bar menu (spec section 5 "Menu bar menu").
struct MenuContent: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let openUntil: () -> Void

    var body: some View {
        // Status lines, the one that wins first: Stay Awake, AI agents, lid, hibernation.
        // A line overridden by one above is struck through.
        if let line = model.sessionLine {
            Text(line)
        }
        if let awake = model.awakeLine {
            Text(awake)
        }
        Text(model.statusLine)
            .strikethrough(model.lidLineOverridden)
        if let detail = model.menuDetail {
            Text(detail)
        }
        Divider()
        // Always available, so a running session can be changed in two clicks.
        // A disabled Menu still opens in a MenuBarExtra (seen on macOS 27.2): hide it instead.
        if model.serviceRunning {
            Menu {
                Button("Until I Turn It Off") { model.startSession(minutes: nil) }
                Divider()
                ForEach(AppModel.sessionDurations, id: \.self) { minutes in
                    Button(AppModel.durationTitle(minutes)) { model.startSession(minutes: minutes) }
                }
                Divider()
                Button("Until…") { openUntil() }
            } label: {
                Label("Stay Awake", systemImage: "cup.and.saucer")
            }
        }
        if model.sessionLine != nil {
            Button { model.stopSession() } label: { Label("Turn Off Stay Awake", systemImage: "cup.and.saucer.fill") }
        }
        if model.sessionLine != nil, model.status?.session?.until != nil {
            Button { model.extendSession() } label: { Label("Add 30 Minutes", systemImage: "plus.circle") }
        }
        Divider()
        Button { model.sleepNow() } label: { Label("Sleep Now", systemImage: "moon") }
            .disabled(!model.serviceRunning)
        if Edition.current.hasBackgroundService {
            Button { model.hibernateNow() } label: { Label("Hibernate Now", systemImage: "snowflake") }
                .disabled(!model.serviceRunning)
        }
        Divider()
        Button { model.onShowAwake() } label: { Label("What Keeps My Mac Awake…", systemImage: "eye") }
        Button { openSettings() } label: { Label("Settings…", systemImage: "gearshape") }
            .keyboardShortcut(",")
        if Edition.current == .full {
            Button { NSWorkspace.shared.open(Links.donation) } label: { Label("Donate…", systemImage: "heart") }
        }
        CheckForUpdatesMenuItem(updater: .shared)
        Button { model.quit() } label: { Label("Quit ClamStop", systemImage: "door.left.hand.open") }
            .keyboardShortcut("q")
    }
}
