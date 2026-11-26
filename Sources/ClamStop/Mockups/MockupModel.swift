import SwiftUI

// UI mockups (docs/functional-spec.md, sections 4 and 5): real SwiftUI views fed with mock data,
// rendered to PNG by `ClamStop --mockups <dir>` (see MockupRenderer.swift and
// scripts/mockups.sh). No daemon, XPC or licensing here. View state lives in this model rather
// than in `@State` (the macro is unavailable with the Command Line Tools).

/// Website build (Developer ID, background service) or Mac App Store build (sandbox).
enum Edition: String, CaseIterable {
    case full
    case store

    var hasBackgroundService: Bool { self == .full }

    /// Page listing every Pro feature. The Store edition links to a help page without any
    /// purchase or download link (App Store guideline 3.1.1, spec section 6). Pages to create.
    var proFeaturesURL: URL {
        switch self {
        case .full: URL(string: "https://chanoj.github.io/ClamStop/pro/")!
        case .store: URL(string: "https://chanoj.github.io/ClamStop/help/pro-features/")!
        }
    }
}

/// What the lid does (spec A2).
enum LidAction: String, CaseIterable, Identifiable {
    case sleep
    case keepWorkingWithScreen
    case stayAwake
    case stayAwakeThenSleep
    case screensOff
    case macOSDefault

    var id: String { rawValue }

    var isPro: Bool {
        switch self {
        case .sleep, .keepWorkingWithScreen, .macOSDefault: false
        case .stayAwake, .stayAwakeThenSleep, .screensOff: true
        }
    }

    func title(edition: Edition) -> String {
        switch self {
        case .sleep: String(localized: "Sleep, even with a screen plugged in")
        case .keepWorkingWithScreen:
            edition == .full
                ? String(localized: "Keep working when a screen is plugged in")
                : String(localized: "Keep working with a screen and power plugged in")
        case .stayAwake: String(localized: "Stay awake")
        case .stayAwakeThenSleep: String(localized: "Stay awake, then sleep after a delay")
        case .screensOff: String(localized: "Turn the screens off only")
        case .macOSDefault: String(localized: "Do what macOS does")
        }
    }

    /// One line under the picker, in plain words.
    func explanation(edition: Edition) -> String {
        switch self {
        case .sleep:
            String(localized: "Like a MacBook with nothing connected: close the lid and it sleeps.")
        case .keepWorkingWithScreen:
            edition == .full
                ? String(localized: "Use your Mac lid closed with an external screen, even on battery. Without a screen, it sleeps.")
                : String(localized: "Use your Mac lid closed with an external screen while it charges. Otherwise, it sleeps.")
        case .stayAwake:
            String(localized: "Your Mac keeps running with the lid closed. Do not put it in a bag.")
        case .stayAwakeThenSleep:
            String(localized: "Gives you time to carry the Mac or finish a task, then it sleeps.")
        case .screensOff:
            String(localized: "The screens turn off, but apps keep running.")
        case .macOSDefault:
            String(localized: "ClamStop does nothing when you close the lid.")
        }
    }
}

/// Hibernation delay (spec B1): free = 1 hour or never; Pro = everything else.
enum HibernateDelay: Int, CaseIterable, Identifiable {
    case immediately = 0
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case twoHours = 120
    case fourHours = 240
    case never = -1

    var id: Int { rawValue }
    var isPro: Bool { self != .oneHour && self != .never }

    var title: String {
        switch self {
        case .immediately: String(localized: "Immediately")
        case .fiveMinutes: String(localized: "After 5 minutes")
        case .fifteenMinutes: String(localized: "After 15 minutes")
        case .thirtyMinutes: String(localized: "After 30 minutes")
        case .oneHour: String(localized: "After 1 hour")
        case .twoHours: String(localized: "After 2 hours")
        case .fourHours: String(localized: "After 4 hours")
        case .never: String(localized: "Never")
        }
    }
}

/// First-run choice on screen 1 (spec section 5).
enum FirstRunLidChoice: String {
    case sleep
    case keepWorking
    case agents
}

/// Tabs of the settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case sessions
    case rules
    case safety
    case actions
    case automation
    case journal

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .sessions: "Stay Awake"
        case .rules: "Rules"
        case .safety: "Safety"
        case .actions: "Actions"
        case .automation: "Automation"
        case .journal: "Journal"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sessions: "cup.and.saucer"
        case .rules: "list.bullet.rectangle"
        case .safety: "checkmark.shield"
        case .actions: "bolt"
        case .automation: "keyboard"
        case .journal: "book"
        }
    }
}

/// Menu state shown by the menu mockup.
enum MenuMockState {
    case idle
    case session
}

/// Mock values for "More options" (no behavior behind them).
struct MockOptions {
    var defaultDuration = 0
    var clickToToggle = false
    var sessionsOnBattery = false
    var screenPolicy = 0
    var endReminder = true
    var agentsAwake = true
    var whileAppsRun = true
    var separateOnBattery = false
    var noSleepDuringCalls = true
    var batteryFloor = 20
    var heatGuard = true
    var onlyWhileCharging = true
    var maxSessionHours = 0
    var lockOnClose = false
    var hibernateOnLowBattery = false
    var lowPowerMode = false
    var keepJournal = true
    var morningReport = false
    var busyOnly = false
}

@MainActor
final class MockupModel: ObservableObject {
    @Published var edition: Edition
    @Published var isPro: Bool

    // First run
    @Published var firstRunStep = 1
    @Published var firstRunLidChoice = FirstRunLidChoice.sleep
    @Published var serviceApproved = false

    // Settings
    @Published var lidAction = LidAction.sleep
    @Published var hibernateDelay = HibernateDelay.oneHour
    @Published var showInMenuBar = true
    @Published var openAtLogin = true
    @Published var settingsTab = SettingsTab.general
    @Published var options = MockOptions()

    // Menu
    @Published var menuState = MenuMockState.idle

    init(edition: Edition = .full, isPro: Bool = false) {
        self.edition = edition
        self.isPro = isPro
    }

    /// Step count of the first run: 3 in the full edition, 1 in the Store edition.
    var firstRunStepCount: Int { edition.hasBackgroundService ? 3 : 1 }

    func locked(_ pro: Bool) -> Bool { pro && !isPro }

    /// The live sentence at the top of the settings.
    var summary: String {
        let lid: String
        switch lidAction {
        case .sleep:
            lid = String(localized: "When you close the lid, your Mac goes to sleep, even with a screen plugged in.")
        case .keepWorkingWithScreen:
            lid = edition == .full
                ? String(localized: "When you close the lid with a screen plugged in, your Mac keeps working, even on battery. Otherwise, it goes to sleep.")
                : String(localized: "When you close the lid with a screen and power plugged in, your Mac keeps working. Otherwise, it goes to sleep.")
        case .stayAwake:
            lid = String(localized: "When you close the lid, your Mac stays awake.")
        case .stayAwakeThenSleep:
            lid = String(localized: "When you close the lid, your Mac stays awake for 15 minutes, then goes to sleep.")
        case .screensOff:
            lid = String(localized: "When you close the lid, the screens turn off and your Mac keeps running.")
        case .macOSDefault:
            lid = String(localized: "When you close the lid, macOS decides, as if ClamStop were not installed.")
        }
        guard edition.hasBackgroundService else { return lid }
        let hibernation: String
        switch hibernateDelay {
        case .never: return lid
        case .immediately:
            hibernation = String(localized: "Right away, it stops using the battery completely (hibernation).")
        default:
            hibernation = String(localized: "\(hibernateDelay.title) asleep, it stops using the battery completely (hibernation).")
        }
        return lid + " " + hibernation
    }
}
