import Foundation

/// Side effects of the power state machine (IOKit, pmset, timers), injected so the logic
/// can be tested without touching the real machine.
public protocol PowerEffects: AnyObject {
    func now() -> Date
    func isLidClosed() -> Bool
    /// Ask the system to sleep now (after `delay` seconds), even with "prevent sleep" assertions.
    func requestSleep(after delay: TimeInterval)
    /// Schedule a wake at `date`. Returns false if it could not be scheduled.
    func scheduleWake(at date: Date) -> Bool
    func cancelWake(at date: Date)
    /// Cancel every wake scheduled by ClamStop, including ones lost after a crash.
    func cancelAllOwnWakes()
    func currentHibernateMode() -> Int?
    @discardableResult func setHibernateMode(_ mode: Int) -> Bool
    /// Run `block` on the controller's queue at `date` (wall clock: counts time asleep).
    func run(at date: Date, _ block: @escaping () -> Void)
}

public protocol StateStore: AnyObject {
    func load() -> PersistedState
    func save(_ state: PersistedState)
}

/// Lid close -> sleep, then delayed hibernation:
/// on sleep with the lid closed, schedule a wake after the delay; on that wake with the lid still
/// closed, set `hibernatemode 25` and sleep again; on any user wake, restore `hibernatemode` and
/// cancel the pending wake. Not thread-safe: call everything from one serial queue.
///
/// Verified on Apple Silicon (2026-11-26): the scheduled wake is a *dark* wake (display off) and
/// dark wakes send no sleep/wake notification to `IORegisterForSystemPower` clients. So the
/// deadline is also checked by a wall-clock timer and on the clamshell messages that dark wakes
/// emit (`deadlineCheck`), and `awake` only tracks full (user) wakes.
public final class PowerController {
    /// A wake this close to the scheduled date counts as the scheduled one (wakes can be coalesced).
    public static let wakeTolerance: TimeInterval = 60
    /// If the Mac is still awake this long after asking to hibernate, give up and restore.
    public static let hibernationTimeout: TimeInterval = 120
    /// Grace period after the deadline before deciding an early wake was a real user session.
    public static let missedDeadlineGrace: TimeInterval = 120
    /// Pause between a wake and the re-sleep into hibernation, to let the wake settle.
    public static let resleepDelay: TimeInterval = 1
    /// A full-wake notification this soon after starting hibernation is the same wake, not a
    /// wake from hibernation (the deadline timer can fire before the notification arrives).
    public static let sameWakeWindow: TimeInterval = 30

    public private(set) var settings: ClamStopSettings
    public private(set) var state: PersistedState
    /// Test hook: delay in seconds instead of `settings.hibernateDelayMinutes`.
    public var delayOverride: TimeInterval?

    private let effects: PowerEffects
    private let store: StateStore
    private let log: (String) -> Void
    private var lastLidClosed = false
    /// Fully awake (user wake). Dark wakes leave it false.
    private var awake = true
    private var hibernationStartedAt: Date?
    private var hibernationGeneration = 0
    /// Incremented on each sleep; lets timers know whether a sleep happened since they were armed.
    private var sleepGeneration = 0

    public init(settings: ClamStopSettings, effects: PowerEffects, store: StateStore,
                log: @escaping (String) -> Void = { _ in }) {
        self.settings = settings
        self.effects = effects
        self.store = store
        self.log = log
        self.state = store.load()
    }

    /// Seconds before hibernating: 0 = at lid close, nil = never.
    public var hibernateDelay: TimeInterval? {
        delayOverride ?? settings.hibernateDelay
    }

    // MARK: Lifecycle

    /// Daemon start. The Mac is awake, so any leftover from a previous run is stale: clean it up.
    public func start() {
        lastLidClosed = effects.isLidClosed()
        awake = true
        if state != PersistedState() {
            log("start: cleaning up previous state \(state)")
        }
        effects.cancelAllOwnWakes()
        restoreHibernateMode()
        update(phase: .idle, pendingWake: nil)
    }

    /// Daemon exit (SIGTERM, unregister): leave the system as it was.
    public func stop() {
        cancelPendingWake()
        effects.cancelAllOwnWakes()
        restoreHibernateMode()
        update(phase: .idle, pendingWake: nil)
    }

    /// Uninstall: back to macOS defaults (`hibernatemode 3`, no ClamStop wake).
    public func restoreDefaults() {
        cancelPendingWake()
        effects.cancelAllOwnWakes()
        if effects.currentHibernateMode() != HibernateMode.default {
            effects.setHibernateMode(HibernateMode.default)
        }
        state.savedHibernateMode = nil
        update(phase: .idle, pendingWake: nil)
        log("defaults restored: hibernatemode \(HibernateMode.default), wakes cancelled")
    }

    public func apply(settings newSettings: ClamStopSettings) {
        settings = newSettings
        // Settings only change while awake (XPC); drop any hibernation plan made with old values.
        if state.phase != .idle {
            cancelPendingWake()
            restoreHibernateMode()
            update(phase: .idle, pendingWake: nil)
        }
    }

    // MARK: Events

    public func lidChanged(closed: Bool) {
        defer { lastLidClosed = closed }
        if closed && lastLidClosed {
            // Repeated "closed" messages come with dark wakes, including the scheduled one.
            deadlineCheck(trigger: "lid message")
            return
        }
        if !closed {
            // Lid opened while awake (after an early lid-closed wake): the user is here.
            if lastLidClosed, awake, state.phase == .awaitingHibernation {
                log("lid opened while awake: cancelling hibernation")
                endHibernationPlan()
            }
            return
        }
        guard !lastLidClosed else { return }  // react only to open -> closed
        guard settings.enabled else {
            log("lid closed: ClamStop disabled, nothing to do")
            return
        }
        if hibernateDelay == 0, state.phase == .idle {
            // "Immediately": switch to hibernatemode 25 before the lid-close sleep. Not in
            // systemWillSleep: pmset there would wait on powerd, which waits on our reply.
            log("lid closed: hibernating immediately")
            hibernate(after: 0)
            return
        }
        log("lid closed: requesting sleep")
        effects.requestSleep(after: 0)
    }

    public func systemWillSleep() {
        awake = false
        sleepGeneration += 1
        guard settings.enabled else { return }
        switch state.phase {
        case .hibernating:
            log("will sleep: going into hibernation")
        case .awaitingHibernation:
            if let wake = state.pendingWake, wake > effects.now() {
                log("will sleep: hibernation wake still pending at \(wake)")
                return
            }
            log("will sleep: pending wake missing or past, rescheduling")
            cancelPendingWake()
            schedule()
        case .idle:
            guard let delay = hibernateDelay, delay > 0 else { return }
            guard effects.isLidClosed() else {
                log("will sleep: lid open, no hibernation scheduled")
                return
            }
            schedule()
        }
    }

    /// - Parameter fullWake: display/graphics available (user wake). False for a dark wake, which
    ///   on AC power can also be notified (verified: capabilities 9 = CPU + network).
    public func systemDidWake(fullWake: Bool = true) {
        if fullWake { awake = true }
        let lidClosed = effects.isLidClosed()
        lastLidClosed = lidClosed
        switch state.phase {
        case .idle:
            restoreHibernateMode()  // safety net, normally a no-op
        case .hibernating:
            // Same wake only if no sleep was seen since (a quick lid reopen after an immediate
            // hibernation is a real wake from hibernation).
            if let started = hibernationStartedAt, sleepGeneration == hibernationGeneration,
               effects.now().timeIntervalSince(started) < Self.sameWakeWindow {
                log("full wake notification for the scheduled wake: hibernation already requested")
                return
            }
            log("woke from hibernation (lid closed: \(lidClosed)): restoring hibernatemode")
            restoreHibernateMode()
            update(phase: .idle, pendingWake: nil)
        case .awaitingHibernation:
            guard let wake = state.pendingWake else {
                update(phase: .idle, pendingWake: nil)
                return
            }
            let now = effects.now()
            if !lidClosed {
                log("user wake (lid open): cancelling hibernation wake")
                endHibernationPlan()
            } else if now >= wake.addingTimeInterval(-Self.wakeTolerance) {
                log("scheduled wake with lid closed: hibernating")
                hibernate()
            } else if !fullWake {
                log("dark wake with lid closed, \(Int(wake.timeIntervalSince(now))) s before deadline: keeping plan")
            } else {
                // Maintenance (dark) wake or a wake from an external keyboard with the lid closed.
                // Keep the plan; if the Mac is still awake after the deadline, the user is using it.
                log("early wake with lid closed, \(Int(wake.timeIntervalSince(now))) s before deadline: keeping plan")
                let generation = sleepGeneration
                effects.run(at: wake.addingTimeInterval(Self.missedDeadlineGrace)) { [weak self] in
                    self?.checkMissedDeadline(generation: generation)
                }
            }
        }
    }

    /// Hibernate if the deadline has passed while the Mac is in a dark wake with the lid closed.
    /// Called by the deadline timer and on clamshell messages; full wakes go through `systemDidWake`.
    public func deadlineCheck(trigger: String) {
        guard state.phase == .awaitingHibernation, let wake = state.pendingWake else { return }
        guard !awake else { return }  // fully awake: the user is here, systemDidWake decides
        guard effects.now() >= wake.addingTimeInterval(-Self.wakeTolerance) else { return }
        guard effects.isLidClosed() else { return }
        log("deadline reached (\(trigger)) in a dark wake with the lid closed: hibernating")
        hibernate()
    }

    // MARK: Internals

    private func schedule() {
        // Whole seconds: the date is persisted and must match exactly to cancel the event.
        let date = Date(timeIntervalSince1970: effects.now().addingTimeInterval(hibernateDelay ?? 0)
            .timeIntervalSince1970.rounded(.up))
        if effects.scheduleWake(at: date) {
            log("will sleep: hibernation wake scheduled at \(date)")
            update(phase: .awaitingHibernation, pendingWake: date)
            effects.run(at: date) { [weak self] in self?.deadlineCheck(trigger: "timer") }
        } else {
            log("will sleep: could not schedule the hibernation wake")
            update(phase: .idle, pendingWake: nil)
        }
    }

    private func hibernate(after sleepDelay: TimeInterval = PowerController.resleepDelay) {
        cancelPendingWake()  // already fired; cancel in case it was coalesced
        if state.savedHibernateMode == nil {
            state.savedHibernateMode = effects.currentHibernateMode() ?? HibernateMode.default
        }
        hibernationStartedAt = effects.now()
        hibernationGeneration = sleepGeneration
        update(phase: .hibernating, pendingWake: nil)  // persist before changing the system
        guard effects.setHibernateMode(HibernateMode.hibernate) else {
            log("could not set hibernatemode \(HibernateMode.hibernate); sleeping normally")
            restoreHibernateMode()
            update(phase: .idle, pendingWake: nil)
            effects.requestSleep(after: sleepDelay)
            return
        }
        effects.requestSleep(after: sleepDelay)
        let generation = sleepGeneration
        effects.run(at: effects.now().addingTimeInterval(Self.hibernationTimeout)) { [weak self] in
            guard let self, self.sleepGeneration == generation, self.state.phase == .hibernating else { return }
            self.log("still awake \(Int(Self.hibernationTimeout)) s after requesting hibernation: restoring")
            self.restoreHibernateMode()
            self.update(phase: .idle, pendingWake: nil)
        }
    }

    private func checkMissedDeadline(generation: Int) {
        guard generation == sleepGeneration, awake, state.phase == .awaitingHibernation else { return }
        log("awake past the hibernation deadline with no sleep: user session, cancelling")
        endHibernationPlan()
    }

    private func endHibernationPlan() {
        cancelPendingWake()
        restoreHibernateMode()
        update(phase: .idle, pendingWake: nil)
    }

    private func cancelPendingWake() {
        if let wake = state.pendingWake {
            effects.cancelWake(at: wake)
            state.pendingWake = nil
        }
    }

    /// Put back the `hibernatemode` saved before ClamStop changed it.
    private func restoreHibernateMode() {
        guard let saved = state.savedHibernateMode else { return }
        if effects.currentHibernateMode() != saved {
            if effects.setHibernateMode(saved) {
                log("hibernatemode restored to \(saved)")
            } else {
                log("could not restore hibernatemode \(saved)")
                return  // keep the saved value to retry later
            }
        }
        state.savedHibernateMode = nil
        store.save(state)
    }

    private func update(phase: PowerPhase, pendingWake: Date?) {
        state.phase = phase
        state.pendingWake = pendingWake
        store.save(state)
    }
}
