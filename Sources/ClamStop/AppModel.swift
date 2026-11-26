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

    /// Hibernation delays offered in the settings (minutes, 0 = never).
    static let delayChoices = [0, 5, 10, 15, 30, 60, 120, 240]

    private let client = DaemonClient()
    private let daemonService = SMAppService.daemon(plistName: ClamStopID.daemonPlistName)
    private var timer: Timer?

    var enabled: Bool { status?.settings.enabled ?? false }
    var delayMinutes: Int { status?.settings.hibernateDelayMinutes ?? ClamStopSettings.defaultDelayMinutes }

    func start() {
        registerDaemonIfNeeded()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        switch daemonService.status {
        case .notRegistered:
            serviceState = .notRegistered
            status = nil
        case .requiresApproval:
            serviceState = .requiresApproval
            status = nil
        case .notFound:
            // Also what macOS reports for a daemon that was never registered (verified on 27.2).
            serviceState = Self.daemonPlistInBundle ? .notRegistered : .notFound
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

    // MARK: Daemon settings

    func setEnabled(_ enabled: Bool) {
        update { try await $0.setEnabled(enabled) }
    }

    func setDelay(minutes: Int) {
        update { try await $0.setHibernateDelay(minutes: minutes) }
    }

    private func update(_ body: @escaping (DaemonClient) async throws -> DaemonStatus) {
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
            try? await daemonService.unregister()
            try? await SMAppService.mainApp.unregister()
            UserDefaults.standard.removeObject(forKey: DefaultsKey.hasLaunchedBefore)
            UserDefaults.standard.removeObject(forKey: DefaultsKey.showMenuBarIcon)
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            NSApp.terminate(nil)
        }
    }

    // MARK: Text

    /// Picker label: "Never", "10 min", "2 h".
    static func delayLabel(_ minutes: Int) -> String {
        if minutes == 0 { return String(localized: "Never") }
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
            if status.sleepDisabled { return String(localized: "Sleep is disabled on this Mac (pmset disablesleep)") }
            let minutes = status.settings.hibernateDelayMinutes
            if minutes == 0 { return String(localized: "On: sleeps when the lid closes") }
            return String(localized: "On: sleeps when the lid closes, hibernates after \(Self.delayLabel(minutes))")
        }
    }

    var statusIsOK: Bool {
        serviceState == .running && enabled && status?.sleepDisabled == false
    }
}
