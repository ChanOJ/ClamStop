import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

/// Software updates with Sparkle (full edition only: the Mac App Store edition is built without
/// Sparkle, see Package.swift, and every member here then does nothing).
///
/// Updates come from the appcast in `SUFeedURL` (a GitHub Release asset) and must be signed
/// with the EdDSA key whose public half is `SUPublicEDKey`. A build without that key (local
/// builds before the key exists) keeps updates off rather than showing Sparkle's error.
@MainActor
final class UpdaterModel: NSObject, ObservableObject {
    static let shared = UpdaterModel()

    /// A scheduled check found an update while ClamStop was in the background (no window to
    /// show it in front of): the menu offers it instead of an alert popping up.
    @Published private(set) var updateAvailable = false
    @Published private(set) var canCheckForUpdates = false

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private var canCheckObserver: NSKeyValueObservation?
    #endif

    var isAvailable: Bool {
        #if canImport(Sparkle)
        controller != nil
        #else
        false
        #endif
    }

    func start() {
        #if canImport(Sparkle)
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard controller == nil, !key.isEmpty else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: self)
        self.controller = controller
        canCheckObserver = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
        #endif
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            #if canImport(Sparkle)
            controller?.updater.automaticallyChecksForUpdates ?? false
            #else
            false
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
            #endif
        }
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        NSApp.activate()
        controller?.checkForUpdates(nil)
        #endif
    }

    static var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(version) (\(build))")
    }
}

#if canImport(Sparkle)
// Gentle reminders, as Sparkle recommends for menu bar apps: no alert stealing focus from
// whatever the person is doing; "Update Available…" appears in the menu instead.
extension UpdaterModel: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            if !handleShowingUpdate { self.updateAvailable = true }
            if state.userInitiated { NSApp.activate() }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.updateAvailable = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.updateAvailable = false }
    }
}
#endif

/// "Updates" section of the settings.
struct UpdatesSettingsView: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        if updater.isAvailable {
            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                HStack {
                    Text(UpdaterModel.versionLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("Updates")
            } footer: {
                Footnote("ClamStop checks GitHub once a day. Nothing about this Mac is sent.")
            }
        }
    }
}

/// "Check for Updates…" (or "Update Available…") in the menu bar menu.
struct CheckForUpdatesMenuItem: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        if updater.isAvailable {
            Button { updater.checkForUpdates() } label: {
                Label(updater.updateAvailable ? "Update Available…" : "Check for Updates…",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
