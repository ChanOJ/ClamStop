import SwiftUI

/// First-run assistant (spec section 5): 3 screens in the full edition, 1 in the Store edition.
struct FirstRunView: View {
    @ObservedObject var model: MockupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.firstRunStepCount > 1 {
                Text("Step \(model.firstRunStep) of \(model.firstRunStepCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            switch model.firstRunStep {
            case 2: ApprovalStep(model: model)
            case 3: HibernationStep(model: model)
            default: LidChoiceStep(model: model)
            }
        }
        .padding(28)
        .frame(width: 560, alignment: .leading)
    }
}

/// Screen 1: "What should happen when you close the lid?"
private struct LidChoiceStep: View {
    @ObservedObject var model: MockupModel

    private var proPicked: Bool { model.firstRunLidChoice == .agents && !model.isPro }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What should happen when you close the lid?")
                    .font(.title2.bold())
                Text("You can change this at any time in Settings.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                ChoiceCard(
                    symbol: "moon.zzz",
                    title: "Sleep, even when a screen is plugged in",
                    detail: "Like a MacBook with nothing connected: close the lid and it sleeps. Best for most people.",
                    badge: .recommended,
                    isSelected: model.firstRunLidChoice == .sleep
                ) { model.firstRunLidChoice = .sleep }
                if model.edition == .full {
                    ChoiceCard(
                        symbol: "display",
                        title: "Keep working when a screen is plugged in",
                        detail: "Use your Mac lid closed with an external screen, even on battery. On its own, macOS needs the power adapter for this.",
                        info: "On battery, your Mac uses its battery while the lid is closed. Without a screen, it sleeps as usual.",
                        isSelected: model.firstRunLidChoice == .keepWorking
                    ) { model.firstRunLidChoice = .keepWorking }
                }
                ChoiceCard(
                    symbol: "sparkles",
                    title: "Stay awake while AI agents work, then sleep",
                    detail: "For Claude Code, Codex and other coding agents: your Mac keeps working with the lid closed and sleeps when they are done.",
                    badge: model.isPro ? nil : .pro,
                    isSelected: model.firstRunLidChoice == .agents
                ) { model.firstRunLidChoice = .agents }
            }
            if proPicked {
                UnlockProPanel(edition: model.edition)
            }
            HStack {
                Spacer()
                if proPicked {
                    Button("Continue with Sleep") { model.firstRunLidChoice = .sleep }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button {} label: {
                        model.firstRunStepCount > 1 ? Text("Continue") : Text("Done")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// What a Pro choice unlocks, with one "Unlock Pro" button (never a pop-up).
private struct UnlockProPanel: View {
    let edition: Edition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("This choice is part of ClamStop Pro")
                    .font(.headline)
                ProBadge()
            }
            Text("Pro also keeps your Mac awake while chosen apps run, adds rules, a sleep journal, keyboard shortcuts and more. Sleep on lid close stays free.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("See all Pro features", destination: edition.proFeaturesURL)
            HStack {
                Button("Unlock Pro…") {}
                if edition == .full {
                    Button("Enter License Key…") {}
                } else {
                    Button("Restore Purchase") {}
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
    }
}

/// Screen 2 (full edition): allow the background service in System Settings.
private struct ApprovalStep: View {
    @ObservedObject var model: MockupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow ClamStop in System Settings")
                    .font(.title2.bold())
                Text("To put your Mac to sleep and stop it using the battery, ClamStop uses a small background service. macOS asks you to allow it once.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click Open System Settings.")
                Text("2. Under Background App Activity, turn on ClamStop:")
            }
            ApprovalIllustration()
            HStack(spacing: 12) {
                Button("Open System Settings") {}
                    .disabled(model.serviceApproved)
                if model.serviceApproved {
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
                    .disabled(!model.serviceApproved)
            }
        }
    }
}

/// Screen 3 (full edition): hibernation, free choices only.
private struct HibernationStep: View {
    @ObservedObject var model: MockupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("When your Mac has been asleep for a while, should it stop using the battery completely?")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("To do this, it saves its memory to disk and turns itself off (this is called hibernation), so the battery is still charged days later. Waking up then takes a few seconds longer.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                ChoiceCard(
                    symbol: "battery.100",
                    title: "After 1 hour",
                    detail: "Quick wake-ups during the day, a full battery the next morning.",
                    badge: .recommended,
                    isSelected: model.hibernateDelay == .oneHour
                ) { model.hibernateDelay = .oneHour }
                ChoiceCard(
                    symbol: "moon",
                    title: "Never",
                    detail: "Your Mac only sleeps. It wakes up at once, but the battery slowly runs down.",
                    isSelected: model.hibernateDelay == .never
                ) { model.hibernateDelay = .never }
            }
            (model.isPro
                 ? Text("You can choose another delay in Settings, from immediately to 4 hours.")
                 : Text("Other delays, from immediately to 4 hours, come with ClamStop Pro."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Back") { model.firstRunStep = 2 }
                Spacer()
                Button("Done") {}
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
