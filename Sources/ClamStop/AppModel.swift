import AppKit
import Foundation
import ServiceManagement
import ClamStopShared
import os

private let logger = Logger(subsystem: ClamStopID.appBundleID, category: "service")

/// State of the background service as seen by the app.
enum ServiceState: Equatable {
    case checking
    /// Registered and answering over XPC.
    case running
    /// Registered, waiting for approval in System Settings > General > Login Items.
    case requiresApproval
    case notRegistered
    /// The daemon plist is missing: the app does not run from a complete ClamStop.app bundle.
    case notFound
    /// Registered and approved but not answering.
    case notResponding
}

enum DefaultsKey {
    static let showMenuBarIcon = "showMenuBarIcon"
    static let hasLaunchedBefore = "hasLaunchedBefore"
    /// No longer a setting (audio pause is automatic, spec F1); listed so uninstall removes it.
    static let pauseAudio = "pauseAudioWhileAsleep"
    static let menuBarIconStyle = "menuBarIconStyle"
    /// Date of the newest daemon notice already turned into a notification.
    static let lastNoticeDate = "lastNoticeDate"
    static let skipQuitConfirmation = "skipQuitConfirmation"
    static let showTimeLeft = "showTimeLeftInMenuBar"
    static let animateBadge = "animateMenuBarBadge"
    /// Brightness of the built-in screen to put back, while ClamStop has it off.
    static let savedScreenBrightness = "savedScreenBrightness"

    /// Every key, removed on uninstall.
    static let all = [showMenuBarIcon, hasLaunchedBefore, pauseAudio, menuBarIconStyle, lastNoticeDate,
                      skipQuitConfirmation, showTimeLeft, animateBadge, savedScreenBrightness]
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var serviceState: ServiceState = .checking
    @Published private(set) var status: DaemonStatus?
    @Published private(set) var launchAtLogin = false
    @Published var errorMessage: String?
    // Kept here rather than in a view's @State: with the Command Line Tools alone, the SwiftUI
    // macro plugin behind @State is missing on recent SDKs, and plain `swift build` must work.
    @Published var confirmUninstall = false
    @Published var showLidHelp = false
    // Settings tabs, agents, journal (see AppModel+Settings.swift)
    @Published var settingsTab = SettingsTab.initial
    @Published var showAgentHelp = false
    @Published var showSleepLog = false
    @Published var confirmAgentHooks = false
    @Published var agentHookStates: [AgentKind: AgentHookSettings.State] = [:]
    @Published var sleepLog: [SleepEvent] = []
    /// End time chosen in the "Stay awake until…" window.
    @Published var sessionUntil = AppModel.nextFullHour()
    /// Rule being added or changed in the Rules tab (see RulesTab.swift).
    @Published var ruleDraft: Rule?
    /// Apps and commands offered by "Add App…" (see WatchedAppsView.swift).
    @Published var knownApps: [WatchedApp] = []
    // First run (see FirstRunView.swift)
    @Published var firstRunStep = 1
    @Published var firstRunChoice = FirstRunChoice.sleep
    @Published var firstRunDelay = ClamStopSettings.defaultDelayMinutes
    /// Choices made in the first-run assistant, sent once the background service answers.
    var pendingFirstRun: FirstRunResult?

    let client = DaemonClient()
    /// Switches the built-in screen off while the Mac stays awake with the lid closed (spec G2).
    let screenDimmer = ScreenDimmer(screen: BuiltInScreen(), store: DefaultsLevelStore()) { message in
        logger.info("\(message, privacy: .public)")
    }
    private let daemonService = SMAppService.daemon(plistName: ClamStopID.daemonPlistName)
    private var timer: Timer?
    /// register() was refused because the item is turned off in System Settings.
    private var registrationDenied = false
    private var lastRegistrationRetry = Date.distantPast
    /// Approved but not answering since then (see `repairIfStuck`).
    private var notRespondingSince: Date?
    private var repairAttempted = false

    var enabled: Bool { status?.settings.enabled ?? false }
    var delayMinutes: Int { status?.settings.hibernateDelayMinutes ?? ClamStopSettings.defaultDelayMinutes }

    /// Development aid (`--preview-approval`, with `--snapshot`): show the approval state
    /// without touching the real registration.
    static let previewApproval = CommandLine.arguments.contains("--preview-approval")

    func start() {
        if Self.previewSettings {
            startSettingsPreview()
            return
        }
        if Self.previewApproval {
            serviceState = .requiresApproval
            return
        }
        if CommandLine.arguments.contains("--reinstall-service") {
            // Development aid after replacing an ad-hoc signed build: fresh registration.
            reinstallService()
        } else {
            registerDaemonIfNeeded()
        }
        updateOutdatedAgentHooks()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // A screen plugged in or unplugged: tell the daemon at once (rules, spec D1).
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !Self.previewApproval, !Self.previewSettings else { return }
        refreshAgentHooks()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        // Turned on in System Settings while the app kept running (macOS does not always quit
        // it): nothing registers the daemon again, so retry while waiting (seen 2026-11-26).
        if registrationDenied, Date().timeIntervalSince(lastRegistrationRetry) >= 10 {
            lastRegistrationRetry = Date()
            retryRegistration()
        }
        switch daemonService.status {
        case .notRegistered:
            serviceState = registrationDenied ? .requiresApproval : .notRegistered
            status = nil
        case .requiresApproval:
            serviceState = .requiresApproval
            status = nil
        case .notFound:
            // Also what macOS reports for a daemon that was never registered (verified on 27.2).
            serviceState = Self.daemonPlistInBundle ? (registrationDenied ? .requiresApproval : .notRegistered) : .notFound
            status = nil
        case .enabled:
            Task {
                do {
                    self.status = try await client.status()
                    self.serviceState = .running
                    self.notRespondingSince = nil
                    self.applyPendingFirstRun()
                } catch {
                    self.status = nil
                    self.serviceState = .notResponding
                    self.repairIfStuck()
                }
            }
        @unknown default:
            serviceState = .notResponding
        }
    }

    /// Previews only (`--preview-settings`): show this status as if the service answered.
    func setPreviewStatus(_ status: DaemonStatus) {
        self.status = status
        serviceState = .running
    }

    // MARK: Daemon settings

    func setEnabled(_ enabled: Bool) {
        update { try await $0.setEnabled(enabled) }
    }

    func setDelay(minutes: Int) {
        update { try await $0.setHibernateDelay(minutes: minutes) }
    }

    func update(_ body: @escaping (DaemonClient) async throws -> DaemonStatus) {
        Task {
            do {
                status = try await body(client)
                serviceState = .running
            } catch {
                errorMessage = String(localized: "ClamStop’s background service is not responding.")
                refresh()
            }
        }
    }

    // MARK: Registration

    private func registerDaemonIfNeeded() {
        switch daemonService.status {
        case .notRegistered:
            installService()
        case .notFound where Self.daemonPlistInBundle:
            installService()
        default:
            break
        }
    }

    /// The LaunchDaemon plist ships inside the app bundle (false when run outside ClamStop.app).
    static var daemonPlistInBundle: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(ClamStopID.daemonPlistName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func installService() {
        do {
            try daemonService.register()
            registrationDenied = false
        } catch let error as NSError where error.code == Int(EPERM) || error.code == kSMErrorLaunchDeniedByUser {
            // Verified on macOS 27.2: after a reinstall the item stays turned off in System
            // Settings and register() fails with EPERM until it is turned on again.
            registrationDenied = true
        } catch {
            // requiresApproval is reported as an error on first registration; the status tells the rest.
            if daemonService.status != .requiresApproval {
                errorMessage = String(localized: "The background service could not be installed: \(error.localizedDescription)")
            }
        }
        refresh()
    }

    /// Quiet retry: no error shown, no refresh (called from `refresh`).
    private func retryRegistration() {
        guard (try? daemonService.register()) != nil else { return }
        registrationDenied = false
    }

    /// Unregister then register again. Needed after replacing an ad-hoc signed ClamStop.app:
    /// launchd pins the daemon's code signature at registration and refuses the new binary
    /// (exit reason OS_REASON_CODESIGNING, verified on macOS 27.2).
    func reinstallService() {
        Task {
            try? await daemonService.unregister()
            installService()
        }
    }

    /// Approved in System Settings but the service never answers: with ad-hoc builds launchd
    /// sometimes refuses the new daemon after an update (EX_CONFIG, "spawn scheduled") until it is
    /// registered again, which then needs no new approval (seen twice on macOS 27.2, 2026-11-27).
    /// Do what the "Reinstall Background Service" button does, once per launch, after 20 s.
    private func repairIfStuck() {
        let now = Date()
        guard let since = notRespondingSince else {
            notRespondingSince = now
            return
        }
        guard !repairAttempted, now.timeIntervalSince(since) >= 20 else { return }
        repairAttempted = true
        logger.info("service approved but not answering for 20 s: registering it again")
        reinstallService()
    }

    // MARK: Quit

    /// "Quit ClamStop" from the menu. Once the app has quit the daemon does nothing (it watches the
    /// app's process), so a running session ends too. While Stay Awake is on, ask first (spec section 5, "Menu bar
    /// menu"), unless "Do not ask again" was checked.
    func quit() {
        guard status?.session != nil, !UserDefaults.standard.bool(forKey: DefaultsKey.skipQuitConfirmation) else {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit ClamStop and turn off Stay Awake?")
        alert.informativeText = String(localized: "Until you open ClamStop again, your Mac sleeps as macOS decides: no sleep with the lid closed when a screen is plugged in, no hibernation, no staying awake for AI agents or apps.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Do not ask again")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: DefaultsKey.skipQuitConfirmation)
        }
        NSApp.terminate(nil)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = String(localized: "Open at login could not be changed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Uninstall

    /// Restore the default power settings, remove the daemon and the login item, reveal the app, quit.
    func uninstall() {
        Task {
            screenDimmer.restore()  // before its saved level is removed below
            if serviceState == .running {
                _ = try? await client.restoreDefaults()
            }
            client.invalidate()
            setAgentHooks(installed: false)
            try? await daemonService.unregister()
            try? await SMAppService.mainApp.unregister()
            DefaultsKey.all.forEach(UserDefaults.standard.removeObject(forKey:))
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            NSApp.terminate(nil)
        }
    }

    // MARK: Text

    /// Duration label: "10 min", "2 h" (positive minutes only).
    static func delayLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60) h") }
        return String(localized: "\(minutes) min")
    }

    /// One-line status for the menu and the settings window.
    var statusLine: String {
        switch serviceState {
        case .checking:
            return String(localized: "Checking…")
        case .requiresApproval:
            return String(localized: "Waiting for approval in System Settings")
        case .notRegistered:
            return String(localized: "Background service not installed")
        case .notFound:
            return String(localized: "Background service missing: run ClamStop from the Applications folder")
        case .notResponding:
            return String(localized: "Background service not responding")
        case .running:
            guard let status else { return String(localized: "Checking…") }
            if !status.settings.enabled { return String(localized: "Off: macOS decides when you close the lid") }
            if status.sleepDisabled && status.sleepDisabledByClamStop != true {
                return String(localized: "Sleep is disabled on this Mac (pmset disablesleep)")
            }
            switch status.lidPlan?.action {
            case .stayAwake: return String(localized: "Rule: stays awake when you close the lid")
            case .macOS: return String(localized: "macOS decides when you close the lid, for now")
            case .sleep, nil: return String(localized: "Sleeps when you close the lid")
            }
        }
    }

    var statusIsOK: Bool {
        serviceState == .running && enabled
            && (status?.sleepDisabled == false || status?.sleepDisabledByClamStop == true)
    }
}
