import Foundation
import ClamStopShared

/// The plain-words sentences of the menu, the menu bar icon and the settings window.
extension AppModel {
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

    /// Menu bar icon state (spec H1).
    var iconState: MenuBarIconState {
        guard statusIsOK, let status else { return .inactive }
        let agentsHolding = !(status.agents ?? []).isEmpty
            && (status.keepingAwake == true || status.sleepDisabledByClamStop == true)
        // Same precedence as the menu lines: a Stay Awake session first, then AI agents, then apps.
        if status.session != nil { return .awake(.session) }
        if agentsHolding { return .awake(.agents) }
        if !workingApps.isEmpty,
           status.keepingAwake == true || status.sleepDisabledByClamStop == true {
            return .awake(.app)
        }
        return .active
    }

    /// Closing the lid would keep the Mac awake now (a session or AI agents, within the Safety
    /// guards): the "Sleeps when you close the lid" line no longer applies.
    var lidLineOverridden: Bool {
        statusIsOK && status?.lidPlan?.action != .stayAwake
            && (status?.sleepDisabledByClamStop == true || status?.keepingAwake == true)
    }

    /// Watched apps that hold the Mac awake.
    private var workingApps: [WatchedAppActivity] {
        (status?.apps ?? []).filter(\.holdsTheMac)
    }

    /// Grey menu line saying why the Mac stays awake when AI agents or watched apps hold it:
    /// "Staying awake while Claude Code works". nil otherwise (a session has its own line).
    var awakeLine: String? {
        let names: [String]
        let finishing: Bool
        switch iconState {
        case .awake(.agents):
            let sessions = status?.agents ?? []
            names = Set(sessions.map(\.agent.displayName)).sorted()
            finishing = sessions.allSatisfy(\.finishing)
        case .awake(.app):
            names = workingApps.map(\.name)
            finishing = workingApps.allSatisfy { $0.state == .finishing }
        default:
            return nil
        }
        guard !names.isEmpty else { return nil }
        let list = names.formatted(.list(type: .and))
        switch (names.count > 1, finishing) {
        case (false, false): return String(localized: "Staying awake while \(list) works")
        case (false, true): return String(localized: "Staying awake while \(list) finishes")
        case (true, false): return String(localized: "Staying awake while \(list) work")
        case (true, true): return String(localized: "Staying awake while \(list) finish")
        }
    }

    /// Short time left next to the icon: "25m", "1h 20m" (nil without an end time).
    var sessionTimeLeft: String? {
        guard serviceRunning, let until = status?.session?.until else { return nil }
        let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        if minutes < 60 { return String(localized: "\(minutes)m", comment: "Time left in the menu bar") }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60)h", comment: "Time left in the menu bar") }
        return String(localized: "\(minutes / 60)h \(minutes % 60)m", comment: "Time left in the menu bar")
    }

    /// "Staying awake until 15:30 (25 min left)" or "Staying awake until you turn it off".
    var sessionLine: String? {
        guard serviceRunning, let session = status?.session else { return nil }
        guard let until = session.until else { return String(localized: "Staying awake until you turn it off") }
        let time = until.formatted(date: .omitted, time: .shortened)
        let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        let left: String
        switch minutes {
        case ..<60: left = String(localized: "\(minutes) min left")
        case let m where m % 60 == 0: left = String(localized: "\(m / 60) h left")
        case let m: left = String(localized: "\(m / 60) h \(m % 60) min left")
        }
        return String(localized: "Staying awake until \(time) (\(left))")
    }

    /// "Immediately", "After 5 minutes", "After 1 hour", "Never".
    static func delayTitle(_ minutes: Int) -> String {
        switch minutes {
        case ..<0: String(localized: "Never")
        case 0: String(localized: "Immediately")
        case 60: String(localized: "After 1 hour")
        case let m where m % 60 == 0: String(localized: "After \(m / 60) hours")
        default: String(localized: "After \(minutes) minutes")
        }
    }

    /// The separate battery settings apply now, not those for the power adapter.
    var usesBatterySettings: Bool {
        status?.settings.separateBatterySettings == true && status?.onPowerAdapter == false
            && status?.lidPlan?.rule == nil
    }

    /// The live sentence at the top of the General tab (spec section 5).
    var summary: String {
        guard serviceRunning, let status else { return statusLine }
        let s = status.settings
        guard s.enabled else {
            return String(localized: "When you close the lid, macOS decides, as if ClamStop were not installed.")
        }
        let plan = status.lidPlan
        let action = plan?.action ?? .sleep
        var parts: [String] = []
        if plan?.rule != nil { parts.append(String(localized: "A rule applies now.")) }
        switch action {
        case .sleep:
            parts.append(usesBatterySettings
                ? String(localized: "On battery, when you close the lid, your Mac goes to sleep, even with a screen plugged in.")
                : String(localized: "When you close the lid, your Mac goes to sleep, even with a screen plugged in."))
            switch plan?.hibernateDelayMinutes ?? s.hibernateDelayMinutes {
            case ..<0: break
            case 0: parts.append(String(localized: "Right away, it stops using the battery completely (hibernation)."))
            case let m: parts.append(String(localized: "\(Self.delayTitle(m)) asleep, it stops using the battery completely (hibernation)."))
            }
        case .stayAwake:
            parts.append(String(localized: "When you close the lid, your Mac stays awake."))
        case .macOS:
            parts.append(usesBatterySettings
                ? String(localized: "On battery, when you close the lid, macOS decides, as if ClamStop were not installed.")
                : String(localized: "When you close the lid, macOS decides, as if ClamStop were not installed."))
        }
        if action == .sleep {
            switch (s.keepAwakeForAgents && agentHooksInstalled, !s.watchedApps.isEmpty) {
            case (true, true): parts.append(String(localized: "While AI agents or your chosen apps work, it stays awake."))
            case (true, false): parts.append(String(localized: "While AI agents work, it stays awake."))
            case (false, true): parts.append(String(localized: "While your chosen apps work, it stays awake."))
            case (false, false): break
            }
        }
        return parts.joined(separator: " ")
    }

    /// Second line of the menu status, nil when there is nothing to add.
    var menuDetail: String? {
        guard serviceRunning, let s = status?.settings, s.enabled else { return nil }
        let plan = status?.lidPlan
        guard plan == nil || plan?.action == .sleep else { return nil }
        let battery = usesBatterySettings
        switch plan?.hibernateDelayMinutes ?? s.hibernateDelayMinutes {
        case ..<0: return nil
        case 0:
            return battery ? String(localized: "On battery: stops using the battery right away")
                : String(localized: "Stops using the battery right away")
        case 60:
            return battery ? String(localized: "On battery: stops using the battery after 1 hour asleep")
                : String(localized: "Stops using the battery after 1 hour asleep")
        case let m where m % 60 == 0:
            return battery ? String(localized: "On battery: stops using the battery after \(m / 60) hours asleep")
                : String(localized: "Stops using the battery after \(m / 60) hours asleep")
        case let m:
            return battery ? String(localized: "On battery: stops using the battery after \(m) minutes asleep")
                : String(localized: "Stops using the battery after \(m) minutes asleep")
        }
    }
}
