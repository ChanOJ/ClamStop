import AppKit
import Combine
import SwiftUI
import os
import ClamStopAppCore
import ClamStopShared

private let iconLogger = Logger(subsystem: ClamStopID.appBundleID, category: "icon")

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
    let badgeAnimator = BadgeAnimator()
    private let audioPauser = AudioPauser()
    private let lidMonitor = LidMonitor()
    private var screenObserver: AnyCancellable?
    private let notifier = Notifier()
    private var notifierObservers: [AnyCancellable] = []
    private var badgeObserver: AnyCancellable?
    private var menuBarIconObserver: AnyCancellable?
    private var settingsWindow: FittedWindow?
    private var welcomeWindow: FittedWindow?
    private var untilWindow: FittedWindow?
    private var journalWindow: NSWindow?
    private var awakeWindow: NSWindow?
    private var awakeTimer: Timer?
    private var notificationClicked = Date.distantPast
    private var lidLock = LidLock()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tooltips (such as "Why ClamStop?") after 1 s instead of the system's ~2 s.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1000])
        model.onShowJournal = { [weak self] in self?.showJournal() }
        model.onShowAwake = { [weak self] in self?.showAwake() }
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
        startScreenDimming()
        startNotifications()
        // Status refresh, or a setting changed (animation, time left, icon style). After a short
        // delay, so that the menu bar label has its new layout.
        badgeObserver = model.$status.map { _ in () }
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () })
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let self else { return }
                    let style = MenuBarIconStyle(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.menuBarIconStyle) ?? "") ?? .laptop
                    self.badgeAnimator.update(self.model.iconState, style: style)
                }
            }

        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: DefaultsKey.hasLaunchedBefore)
        // Not from snapshots (development aid): they share the installed app's preferences.
        if !CommandLine.arguments.contains("--snapshot") {
            defaults.set(true, forKey: DefaultsKey.hasLaunchedBefore)
        }
        // For support: the icon can disappear without the app quitting (setting, ⌘-drag, macOS).
        menuBarIconObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in () }
            .prepend(())
            .receive(on: RunLoop.main)
            .map { defaults.object(forKey: DefaultsKey.showMenuBarIcon) as? Bool ?? true }
            .removeDuplicates()
            .sink { iconLogger.info("menu bar icon \($0 ? "shown" : "hidden", privacy: .public)") }
        let iconHidden = defaults.object(forKey: DefaultsKey.showMenuBarIcon) as? Bool == false
        // Without an icon the settings window is the only way in, except at login (stay quiet).
        if firstLaunch, !CommandLine.arguments.contains("--snapshot") {
            showWelcome()
        } else if iconHidden && !launchedAsLoginItem(notification) {
            showSettings()
        }
        snapshotIfRequested()
    }

    /// The built-in screen goes off while the Mac stays awake with the lid closed, and comes back
    /// when it opens.
    private func startScreenDimming() {
        guard !AppModel.previewSettings, !AppModel.previewApproval,
              !CommandLine.arguments.contains("--snapshot") else { return }
        model.screenDimmer.start(lidClosed: LidMonitor.isLidClosed)
        screenObserver = model.$status.sink { [weak self, model] status in
            guard let status else { return }
            // The lid as it is now: a reply can be older than the last notification.
            let closed = LidMonitor.isLidClosed
            let keptAwake = closed && status.lidClosed && status.keepingAwake == true
            model.screenDimmer.lidChanged(closed: closed)
            model.screenDimmer.update(keptAwake: keptAwake)
            self?.lockIfAsked(lidClosed: closed, keptAwake: keptAwake)
        }
        lidMonitor.onChange = { [weak self, weak model] closed in
            MainActor.assumeIsolated {
                guard let model else { return }
                model.screenDimmer.lidChanged(closed: closed)
                guard closed else {
                    self?.lockIfAsked(lidClosed: false, keptAwake: false)
                    model.checkSleepReport()
                    return
                }
                // Ask the service once it has decided, without waiting for the next poll.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.refresh() }
            }
        }
        lidMonitor.start()
    }

    /// "Lock the screen when the lid closes" (spec F2).
    private func lockIfAsked(lidClosed: Bool, keptAwake: Bool) {
        if lidLock.update(lidClosed: lidClosed, keptAwake: keptAwake,
                          externalDisplay: DaemonClient.externalDisplayConnected,
                          enabled: UserDefaults.standard.bool(forKey: DefaultsKey.lockOnLidClose)) {
            ScreenLocker.lock()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.screenDimmer.restore()
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) while it runs: show the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        iconLogger.notice("reopen")
        // macOS also asks for this when a notification is clicked: the click says what to show.
        guard Date().timeIntervalSince(notificationClicked) > 2 else { return false }
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
            settingsWindow?.onCommandDigit = { [model] digit in
                guard SettingsTab.allCases.indices.contains(digit - 1) else { return false }
                let tab = SettingsTab.allCases[digit - 1]
                model.settingsTab = tab
                VoiceOver.say(String(localized: "\(tab.spokenTitle) tab"))
                return true
            }
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
        notifier.onOpenJournal = { [weak self] in self?.showJournalFromNotification() }
        notifier.onClick = { [weak self] in self?.notificationClicked = Date() }
        notifier.onExtendSession = { [model] in model.extendSession() }
        model.onSleepReport = { [notifier] in notifier.sleepEnded($0) }
        notifier.start()
        model.onApprovalReminder = { [notifier] in notifier.serviceStillNeedsApproval() }
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

    /// The sleep journal (spec H3).
    func showJournal() {
        if journalWindow == nil {
            journalWindow = resizableWindow(title: String(localized: "Sleep Journal"),
                                            rootView: JournalView(model: model))
        }
        model.loadSleepLog()
        journalWindow?.showInFront()
    }

    /// The sleep report was clicked. macOS activates the app around the click, which can bring
    /// another of its windows in front of the journal (the settings, seen 2026-11-28): bring the
    /// journal forward again once that is over.
    private func showJournalFromNotification() {
        showJournal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.journalWindow?.showInFront()
        }
    }

    /// "What keeps my Mac awake?" (spec H2): read again every few seconds while it is open.
    func showAwake() {
        if awakeWindow == nil {
            let window = resizableWindow(title: String(localized: "What Keeps My Mac Awake?"),
                                         rootView: AwakeView(model: model))
            awakeWindow = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.awakeTimer?.invalidate()
                    self?.awakeTimer = nil
                }
            }
        }
        model.awakeList = nil
        Task { await model.loadAwakeList() }
        if awakeTimer == nil {
            awakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [model] _ in
                Task { @MainActor in await model.loadAwakeList() }
            }
            awakeTimer?.tolerance = 1
        }
        awakeWindow?.showInFront()
    }

    /// A list in a window of its own: resizable, unlike the other windows.
    private func resizableWindow<Content: View>(title: String, rootView: Content) -> NSWindow {
        let controller = NSHostingController(rootView: rootView)
        controller.sizingOptions = []
        let window = SettingsWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 560))
        window.contentMinSize = NSSize(width: 420, height: 300)
        window.center()
        return window
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
