import SwiftUI
import ClamStopShared

/// First-run assistant (spec section 5): what the lid does, the background service approval,
/// then hibernation. Only choices that already work are offered.
struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Step \(model.firstRunStep) of 3")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            switch model.firstRunStep {
            case 2: approvalStep
            case 3: hibernationStep
            default: lidStep
            }
        }
        .padding(28)
        .frame(width: 560, alignment: .leading)
    }

    // MARK: Screen 1

    private var lidStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("What should happen when you close the lid?",
                    detail: "You can change this at any time in Settings.")
            VStack(spacing: 10) {
                ChoiceCard(
                    symbol: "moon.zzz",
                    title: "Sleep, even when a screen is plugged in",
                    detail: "Like a MacBook with nothing connected: close the lid and it sleeps.",
                    recommended: true,
                    isSelected: model.firstRunChoice == .sleep
                ) { model.firstRunChoice = .sleep }
                ChoiceCard(
                    symbol: "sparkles",
                    title: "Stay awake while AI agents work, then sleep",
                    detail: "For Claude Code, Codex, Cursor and others: your Mac keeps working even with the lid closed and sleeps when they are done.",
                    info: "ClamStop adds a small hook to the agents’ settings so they can tell it when they work.",
                    warning: "With the lid closed, your Mac can get hot, especially in a bag. Keep it out in the open while agents work. If it gets too hot, ClamStop puts it to sleep.",
                    isSelected: model.firstRunChoice == .agents
                ) { model.firstRunChoice = .agents }
            }
            HStack {
                Spacer()
                Button("Continue") { model.firstRunStep = model.serviceRunning ? 3 : 2 }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Screen 2

    private var approvalStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Allow ClamStop in System Settings",
                    detail: "To put your Mac to sleep and stop it using the battery, ClamStop uses a small background service. macOS asks you to allow it once.")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click Open System Settings.")
                Text("2. Under Background App Activity, turn on ClamStop:")
            }
            ApprovalIllustration()
            HStack(spacing: 12) {
                Button("Open System Settings") { model.openLoginItemsSettings() }
                    .disabled(model.serviceRunning)
                if model.serviceRunning {
                    Label("Done: ClamStop is allowed.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Waiting for you to turn it on…")
                        .foregroundStyle(.secondary)
                }
            }
            Text("If ClamStop quits when you turn it on, open it again from the Applications folder.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Back") { model.firstRunStep = 1 }
                Spacer()
                Button("Continue") { model.firstRunStep = 3 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.serviceRunning)
            }
        }
        // VoiceOver hears the wait end, as the screen shows it.
        .onChange(of: model.serviceRunning) { _, running in
            guard running else { return }
            AccessibilityNotification.Announcement(String(localized: "Done: ClamStop is allowed.")).post()
        }
    }

    // MARK: Screen 3

    private var hibernationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("When your Mac has been asleep for a while, should it stop using the battery completely?",
                    detail: "To do this, it saves its memory to disk and turns itself off (this is called hibernation), so the battery is still charged days later. Waking up then takes a few seconds longer.")
            VStack(spacing: 10) {
                ChoiceCard(
                    symbol: "battery.100",
                    title: "After 1 hour",
                    detail: "Quick wake-ups during the day, a full battery the next morning.",
                    recommended: true,
                    isSelected: model.firstRunDelay == ClamStopSettings.defaultDelayMinutes
                ) { model.firstRunDelay = ClamStopSettings.defaultDelayMinutes }
                ChoiceCard(
                    symbol: "moon",
                    title: "Never",
                    detail: "Your Mac only sleeps. It wakes up at once, but the battery slowly runs down.",
                    isSelected: model.firstRunDelay == ClamStopSettings.never
                ) { model.firstRunDelay = ClamStopSettings.never }
            }
            Text("You can choose another delay in Settings, from immediately to 4 hours.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Back") { model.firstRunStep = model.serviceRunning ? 1 : 2 }
                Spacer()
                Button("Done") {
                    model.pendingFirstRun = FirstRunResult(choice: model.firstRunChoice,
                                                           hibernateDelayMinutes: model.firstRunDelay)
                    model.applyPendingFirstRun()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func heading(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// About tab of the settings window (spec J6). Full edition: website, source code and a
/// discreet "Buy me a coffee" link; Store edition: only a neutral Help link.
struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ClamStopVersion.current
        guard let build = info?["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(verbatim: "ClamStop")
                .font(.title.bold())
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("Puts your MacBook to sleep when you close the lid, even with a screen plugged in, or keeps it awake when you choose.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 16) {
                if Edition.current == .full {
                    Link("Website", destination: Links.website)
                    Link("Source code", destination: Links.sourceCode)
                    Link("Vote for features", destination: Links.featureVote)
                } else {
                    Link("Help", destination: Links.help)
                }
            }
            .padding(.top, 4)
            if Edition.current == .full {
                DonationLink(text: "ClamStop is free and open source. You can help pay for the developer account, and the time spent building it.")
                    .padding(.top, 4)
                Text("AI agent support is based on ideas from clamshut by Ishaan Chamoli (MIT license).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: "© 2026 ChanOJ · MIT License")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .frame(width: 360)
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
