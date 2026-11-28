// While the Mac stays awake with the lid closed, macOS leaves the built-in screen on (verified
// on Apple Silicon, macOS 27.2, 2026-11-28): set it to zero brightness, and put the level back
// when the lid opens (spec G2).

import Foundation

/// The built-in screen's brightness (0...1). nil or false when it cannot be read or set, for
/// instance while macOS has it off because the lid is closed with an external screen.
public protocol ScreenBrightness: AnyObject {
    func level() -> Float?
    @discardableResult func setLevel(_ level: Float) -> Bool
}

/// Keeps the level to put back across a crash of the app.
public protocol SavedLevelStore: AnyObject {
    var savedLevel: Float? { get set }
}

/// Not thread-safe: call from one serial queue.
public final class ScreenDimmer {
    private let screen: ScreenBrightness
    private let store: SavedLevelStore
    private let log: (String) -> Void
    private var lidClosed = false
    private var keptAwake = false
    /// Read when the lid closed: macOS adjusts the level once the sensor is covered.
    private var levelAtClose: Float?

    public init(screen: ScreenBrightness, store: SavedLevelStore, log: @escaping (String) -> Void = { _ in }) {
        self.screen = screen
        self.store = store
        self.log = log
    }

    /// App start. With the lid open, a level left saved by a crash is put back.
    public func start(lidClosed: Bool) {
        self.lidClosed = lidClosed
        if !lidClosed { restore() }
    }

    public func lidChanged(closed: Bool) {
        guard closed != lidClosed else {
            if !closed { restore() }
            return
        }
        lidClosed = closed
        // Wait for the service to say what happens with the lid closed this time.
        keptAwake = false
        if closed {
            levelAtClose = screen.level()
        } else {
            levelAtClose = nil
            restore()
        }
    }

    /// Latest word from the background service: it keeps the Mac awake with the lid closed.
    public func update(keptAwake: Bool) {
        self.keptAwake = keptAwake
        if lidClosed {
            dim()
        } else {
            restore()  // the screen may not have answered right after the lid opened
        }
    }

    /// Put the saved level back, if any (lid opened, app quitting).
    public func restore() {
        guard let level = store.savedLevel, screen.setLevel(level) else { return }
        store.savedLevel = nil
        log("built-in screen back to \(Int((level * 100).rounded())) %")
    }

    private func dim() {
        guard keptAwake, let current = screen.level(), current > 0 else { return }
        if store.savedLevel == nil { store.savedLevel = levelAtClose ?? current }
        if screen.setLevel(0) { log("lid closed, staying awake: built-in screen off") }
    }
}
