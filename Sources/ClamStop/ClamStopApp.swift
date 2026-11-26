import AppKit
import SwiftUI
import ClamStopShared

@main
struct ClamStopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuContent(model: delegate.model) { delegate.showSettings() }
        } label: {
            MenuBarIcon(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app (LSUIElement in the bundle); also when run outside a bundle during development.
        NSApp.setActivationPolicy(.accessory)
        model.start()

        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: DefaultsKey.hasLaunchedBefore)
        defaults.set(true, forKey: DefaultsKey.hasLaunchedBefore)
        let iconHidden = defaults.object(forKey: DefaultsKey.showMenuBarIcon) as? Bool == false
        // Without an icon the settings window is the only way in, except at login (stay quiet).
        if firstLaunch || (iconHidden && !launchedAsLoginItem(notification)) {
            showSettings()
        }
        snapshotIfRequested()
    }

    /// Development aid: `ClamStop --snapshot /path/to/file.png` renders the settings window to a
    /// PNG (no Screen Recording permission needed), for docs and reviews.
    private func snapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        showSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let view = self?.settingsWindow?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) while it runs: show the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.title = String(localized: "ClamStop Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        model.refresh()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func launchedAsLoginItem(_ notification: Notification) -> Bool {
        if let launchEvent = NSAppleEventManager.shared().currentAppleEvent,
           launchEvent.eventID == kAEOpenApplication,
           launchEvent.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return false
    }
}
