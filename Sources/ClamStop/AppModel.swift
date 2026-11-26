import AppKit
import Foundation
import ServiceManagement
import ClamStopShared

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
    static let pauseAudio = "pauseAudioWhileAsleep"
    static let menuBarIconStyle = "menuBarIconStyle"

    /// Every key, removed on uninstall.
    static let all = [showMenuBarIcon, hasLaunchedBefore, pauseAudio, menuBarIconStyle]
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
    @Published var showAudioHelp = false
    // Pro (see AppModel+Pro.swift)
    @Published var settingsTab: SettingsTab = CommandLine.arguments.contains("--preview-pro") ? .pro : .general
    @Published var showAgentHelp = false
    @Published var showSleepLog = false
    @Published var agentHookStates: [AgentKind: AgentHookSettings.State] = [:]
    @Published var sleepLog: [SleepEvent] = []

    /// Hibernation delays offered in the settings (minutes, 0 = immediately, last = never).
    static let allDelayChoices = [0, 5, 10, 15, 30, 60, 120, 240, ClamStopSettings.never]
    /// The free edition offers "after 1 h" and "never" (Pro: every delay).
    static var delayChoices: [Int] {
        Entitlement.isUnlocked(.hibernationDelays) ? allDelayChoices : ClamStopSettings.freeDelayChoices
    }

    let client = DaemonClient()
    private let daemonService = SMAppService.daemon(plistName: ClamStopID.daemonPlistName)
    private var timer: Timer?
    /// register() was refused because the item is turned off in System Settings.
    private var registrationDenied = false

    var enabled: Bool { status?.settings.enabled ?? false }
    var delayMinutes: Int { status?.settings.effective().hibernateDelayMinutes ?? ClamStopSettings.defaultDelayMinutes }

    /// Development aid (`--preview-approval`, with `--snapshot`): show the approval state
    /// without touching the real registration.
    static let previewApproval = CommandLine.arguments.contains("--preview-approval")

    func start() {
        if Self.previewPro {
            startProPreview()
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
    }

    func refresh() {
        guard !Self.previewApproval, !Self.previewPro else { return }
        refreshAgentHooks()
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
                    let status = try await client.status()
                    self.status = status
                    self.serviceState = .running
                } catch {
                    self.status = nil
                    self.serviceState = .notResponding
                }
            }
        @unknown default:
            serviceState = .notResponding
        }
    }

    /// Previews only (`--preview-pro`): show this status as if the service answered.
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

    /// Unregister then register again. Needed after replacing an ad-hoc signed ClamStop.app:
    /// launchd pins the daemon's code signature at registration and refuses the new binary
    /// (exit reason OS_REASON_CODESIGNING, verified on macOS 27.2).
    func reinstallService() {
        Task {
            try? await daemonService.unregister()
            installService()
        }
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
            if !status.settings.enabled { return String(localized: "Off: the lid works as usual") }
            if status.keepingAwakeForAgents == true {
                return String(localized: "Lid closed: staying awake while AI agents work")
            }
            if status.sleepDisabled && status.sleepDisabledByClamStop != true {
                return String(localized: "Sleep is disabled on this Mac (pmset disablesleep)")
            }
            let minutes = delayMinutes
            if minutes < 0 { return String(localized: "On: sleeps when the lid closes") }
            if minutes == 0 { return String(localized: "On: hibernates when the lid closes") }
            return String(localized: "On: sleeps when the lid closes, hibernates after \(Self.delayLabel(minutes))")
        }
    }

    var statusIsOK: Bool {
        serviceState == .running && enabled
            && (status?.sleepDisabled == false || status?.sleepDisabledByClamStop == true)
    }
}
