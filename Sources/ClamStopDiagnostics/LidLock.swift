// "Lock the screen when the lid closes" (spec F2): while ClamStop keeps the Mac awake, macOS does
// not necessarily lock it. App only.

/// When to lock: once for each time the lid is closed.
public struct LidLock: Sendable {
    private var locked = false

    public init() {}

    /// true: lock now. With an external screen the user may be working on it, lid closed; if it is
    /// unplugged before the lid opens, the screen locks then.
    public mutating func update(lidClosed: Bool, keptAwake: Bool, externalDisplay: Bool, enabled: Bool) -> Bool {
        guard lidClosed else {
            locked = false
            return false
        }
        guard !locked, enabled, keptAwake, !externalDisplay else { return false }
        locked = true
        return true
    }
}
