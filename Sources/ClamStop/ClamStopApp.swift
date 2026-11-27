import AppKit
import Combine
import SwiftUI
import ClamStopShared

/// Started by `Main` (not `@main`, so that `--agent-hook` runs without any UI).
struct ClamStopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuContent(model: delegate.model,
                        openSettings: { delegate.showSettings() },
                        openUntil: { delegate.showSessionUntil() })
        } label: {
            MenuBarIcon(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let audioPauser = AudioPauser()
    private let notifier = Notifier()
    private var notifierObservers: [AnyCancellable] = []
    private var settingsWindow: FittedWindow?
    private var welcomeWindow: FittedWindow?
    private var untilWindow: FittedWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tooltips (such as "Why ClamStop?") after 1 s instead of the system's ~2 s.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1000])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app (LSUIElement in the bundle); also when run outside a bundle during development.
        NSApp.setActivationPolicy(.accessory)
        if runDevelopmentCommands() { return }
        model.start()
        UpdaterModel.shared.start()
        // Development aid: `--check-for-updates` (testing an appcast).
        if CommandLine.arguments.contains("--check-for-updates") { UpdaterModel.shared.checkForUpdates() }
        // Automatic and hidden (spec F1): only to avoid the half second of sound during the
        // wake that leads to hibernation.
        audioPauser.shouldPause = { [model] in
            model.serviceState == .running && model.enabled && model.delayMinutes != ClamStopSettings.never
        }
        audioPauser.start()
        startNotifications()

        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: DefaultsKey.hasLaunchedBefore)
        defaults.set(true, forKey: DefaultsKey.hasLaunchedBefore)
        let iconHidden = defaults.object(forKey: DefaultsKey.showMenuBarIcon) as? Bool == false
        // Without an icon the settings window is the only way in, except at login (stay quiet).
        if firstLaunch, !CommandLine.arguments.contains("--snapshot") {
            showWelcome()
        } else if iconHidden && !launchedAsLoginItem(notification) {
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
        if let directory = Self.argument(after: "--mockups") {
            if let icon = Self.argument(after: "--icon"), let image = NSImage(contentsOfFile: icon) {
                NSApp.applicationIconImage = image  // when run outside the app bundle
            }
            MockupRenderer.run(outputDirectory: URL(fileURLWithPath: directory))
            return true
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

    /// Development aid: `ClamStop --snapshot /path/to/file.png [--tab name]
    /// [--show-help [agent|history]] [--welcome step] [--until]` renders the visible windows to
    /// PNG files (no Screen Recording permission needed), for docs and reviews.
    private func snapshotIfRequested() {
        guard let path = Self.argument(after: "--snapshot") else { return }
        let args = CommandLine.arguments
        let url = URL(fileURLWithPath: path)
        if let step = Self.argument(after: "--welcome").flatMap(Int.init) {
            model.firstRunStep = step
            if args.contains("agents") { model.firstRunChoice = .agents }
            showWelcome()
        } else if args.contains("--until") {
            showSessionUntil()
        } else {
            showSettings()
        }
        if args.contains("--show-help") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if args.contains("agent") {
                    self.model.showAgentHelp = true
                } else if args.contains("history") {
                    self.model.showSleepLog = true
                } else {
                    self.model.showLidHelp = true
                }
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
            settingsWindow = FittedWindow(title: String(localized: "ClamStop Settings"), model: model,
                                          rootView: SettingsRootView(model: model))
        }
        model.refresh()
        settingsWindow?.show()
    }

    /// First-run assistant (first launch only).
    func showWelcome() {
        if welcomeWindow == nil {
            welcomeWindow = FittedWindow(title: String(localized: "Welcome to ClamStop"), model: model,
                                         rootView: WelcomeView(model: model) { [weak self] in
                                             self?.welcomeWindow?.close()
                                         })
        }
        welcomeWindow?.show()
    }

    /// Notifications (spec H5) from the daemon's notices and the service state.
    private func startNotifications() {
        // Not from previews and snapshots (development aids).
        guard !AppModel.previewSettings, !AppModel.previewApproval,
              !CommandLine.arguments.contains("--snapshot") else { return }
        notifier.onOpen = { [weak self] in self?.showSettings() }
        notifier.start()
        notifierObservers.append(model.$status.sink { [notifier] status in
            if let status { notifier.process(status) }
        })
        notifierObservers.append(model.$serviceState.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            switch state {
            case .requiresApproval where self.welcomeWindow?.isVisible != true:
                self.notifier.serviceNeedsApproval()
            case .running:
                self.notifier.serviceApproved()
            default:
                break
            }
        })
    }

    /// "Stay Awake > Until…" from the menu: pick an end time.
    func showSessionUntil() {
        if untilWindow == nil {
            untilWindow = FittedWindow(title: String(localized: "Stay Awake"), model: model,
                                       rootView: SessionUntilView(model: model) { [weak self] in
                                           self?.untilWindow?.close()
                                       })
        }
        model.sessionUntil = AppModel.nextFullHour()
        untilWindow?.show()
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

/// A window sized by hand to its SwiftUI content. No constraint-driven window sizing: with a
/// grouped Form it can loop forever ("update constraints" exception, seen on first launch).
@MainActor
final class FittedWindow {
    private let window: SettingsWindow
    private let measure: (NSSize) -> NSSize
    private var observer: AnyCancellable?

    init<Content: View>(title: String, model: AppModel, rootView: Content) {
        let controller = NSHostingController(rootView: rootView)
        controller.sizingOptions = []
        window = SettingsWindow(contentViewController: controller)
        // Not `view.fittingSize`: it stays zero for these windows (seen on macOS 27.2).
        measure = { [unowned controller] in controller.sizeThatFits(in: $0) }
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        fit()
        window.center()
        observer = model.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.fit() }
    }

    func show() {
        fit()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    var isVisible: Bool { window.isVisible }

    /// Resize the window to the SwiftUI content's ideal height, keeping its top edge in place.
    private func fit() {
        let size = measure(NSSize(width: 2000, height: 5000))
        guard size.width > 0, size.height > 0,
              abs(window.contentLayoutRect.height - size.height) > 0.5
                || abs(window.contentLayoutRect.width - size.width) > 0.5 else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
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
