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
public final class PowerController {
    /// A wake this close to the scheduled date counts as the scheduled one (wakes can be coalesced).
    public static let wakeTolerance: TimeInterval = 60
    /// If the Mac is still awake this long after asking to hibernate, give up and restore.
    public static let hibernationTimeout: TimeInterval = 120
    /// Grace period after the deadline before deciding an early wake was a real user session.
    public static let missedDeadlineGrace: TimeInterval = 120
    /// Pause between a wake and the re-sleep into hibernation, to let the wake settle.
    public static let resleepDelay: TimeInterval = 1

    public private(set) var settings: ClamStopSettings
    public private(set) var state: PersistedState
    /// Test hook: delay in seconds instead of `settings.hibernateDelayMinutes`.
    public var delayOverride: TimeInterval?

    private let effects: PowerEffects
    private let store: StateStore
    private let log: (String) -> Void
    private var lastLidClosed = false
    private var awake = true
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

    public var hibernateDelay: TimeInterval {
        delayOverride ?? TimeInterval(settings.hibernateDelayMinutes * 60)
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
            guard hibernateDelay > 0 else { return }
            guard effects.isLidClosed() else {
                log("will sleep: lid open, no hibernation scheduled")
                return
            }
            schedule()
        }
    }

    public func systemDidWake() {
        awake = true
        let lidClosed = effects.isLidClosed()
        lastLidClosed = lidClosed
        switch state.phase {
        case .idle:
            restoreHibernateMode()  // safety net, normally a no-op
        case .hibernating:
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
                hibernate()
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

    // MARK: Internals

    private func schedule() {
        // Whole seconds: the date is persisted and must match exactly to cancel the event.
        let date = Date(timeIntervalSince1970: effects.now().addingTimeInterval(hibernateDelay)
            .timeIntervalSince1970.rounded(.up))
        if effects.scheduleWake(at: date) {
            log("will sleep: hibernation wake scheduled at \(date)")
            update(phase: .awaitingHibernation, pendingWake: date)
        } else {
            log("will sleep: could not schedule the hibernation wake")
            update(phase: .idle, pendingWake: nil)
        }
    }

    private func hibernate() {
        log("scheduled wake with lid closed: hibernating")
        cancelPendingWake()  // already fired; cancel in case it was coalesced
        if state.savedHibernateMode == nil {
            state.savedHibernateMode = effects.currentHibernateMode() ?? HibernateMode.default
        }
        update(phase: .hibernating, pendingWake: nil)  // persist before changing the system
        guard effects.setHibernateMode(HibernateMode.hibernate) else {
            log("could not set hibernatemode \(HibernateMode.hibernate); sleeping normally")
            restoreHibernateMode()
            update(phase: .idle, pendingWake: nil)
            effects.requestSleep(after: Self.resleepDelay)
            return
        }
        effects.requestSleep(after: Self.resleepDelay)
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
