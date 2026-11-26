import AppKit
import Combine
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
    private let audioPauser = AudioPauser()
    private var settingsWindow: NSWindow?
    private var hostingController: NSHostingController<SettingsView>?
    private var modelObserver: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tooltips (such as "Why ClamStop?") after 1 s instead of the system's ~2 s.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1000, DefaultsKey.pauseAudio: true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app (LSUIElement in the bundle); also when run outside a bundle during development.
        NSApp.setActivationPolicy(.accessory)
        if runDevelopmentCommands() { return }
        model.start()
        audioPauser.shouldPause = { [model] in
            UserDefaults.standard.bool(forKey: DefaultsKey.pauseAudio)
                && model.serviceState == .running && model.enabled
                && model.delayMinutes != ClamStopSettings.never
        }
        audioPauser.start()

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

    /// Development aids, for docs and reviews (no Screen Recording permission needed):
    /// - `--appearance light|dark`: force the appearance;
    /// - `--export-illustration file.png`: write `ApprovalIllustration` to a PNG and quit
    ///   (README images); returns true then.
    private func runDevelopmentCommands() -> Bool {
        switch Self.argument(after: "--appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        guard let path = Self.argument(after: "--export-illustration") else { return false }
        do {
            try ApprovalIllustration.export(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("cannot write \(path): \(error)\n".utf8))
        }
        NSApp.terminate(nil)
        return true
    }

    private static func argument(after name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Development aid: `ClamStop --snapshot /path/to/file.png [--show-help [audio]]` renders the visible windows to
    /// PNG files (no Screen Recording permission needed), for docs and reviews.
    private func snapshotIfRequested() {
        guard let path = Self.argument(after: "--snapshot") else { return }
        let args = CommandLine.arguments
        let url = URL(fileURLWithPath: path)
        showSettings()
        if args.contains("--show-help") {
            let audio = args.contains("audio")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if audio { self.model.showAudioHelp = true } else { self.model.showLidHelp = true }
            }
        }
        // Each visible window (settings, popover) to file.png, file.1.png, …
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 50 }
            for (index, window) in windows.enumerated() {
                guard let view = window.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let target = index == 0 ? url : url.deletingPathExtension()
                    .appendingPathExtension("\(index)").appendingPathExtension("png")
                try? rep.representation(using: .png, properties: [:])?.write(to: target)
            }
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
            // No constraint-driven window sizing: with a grouped Form it can loop forever
            // ("update constraints" exception, seen on first launch). Size the window by hand.
            controller.sizingOptions = []
            hostingController = controller
            let window = SettingsWindow(contentViewController: controller)
            window.title = String(localized: "ClamStop Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
            fitSettingsWindow()
            window.center()
            modelObserver = model.objectWillChange
                .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.fitSettingsWindow() }
        }
        model.refresh()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Resize the window to the SwiftUI content's ideal height, keeping its top edge in place.
    private func fitSettingsWindow() {
        guard let window = settingsWindow, let view = hostingController?.view else { return }
        let size = view.fittingSize
        guard size.width > 0, size.height > 0,
              abs(window.contentLayoutRect.height - size.height) > 0.5 else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
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

/// The settings window of an agent app has no menu bar, hence no File > Close item:
/// handle ⌘W here (HIG: every window closes with ⌘W).
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
