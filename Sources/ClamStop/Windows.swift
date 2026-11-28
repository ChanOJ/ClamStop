import AppKit
import Combine
import SwiftUI

extension NSWindow {
    /// Show in front of the other apps' windows. `NSApp.activate()` alone is a request that macOS
    /// can turn down, for instance the first time after the app was opened in the background: the
    /// window then opened behind the app in use (seen 2026-11-28).
    func showInFront() {
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}

/// A window sized by hand to its SwiftUI content. No constraint-driven window sizing: with a
/// grouped Form it can loop forever ("update constraints" exception, seen on first launch).
@MainActor
final class FittedWindow {
    private let window: SettingsWindow
    private let measure: (NSSize) -> NSSize
    private var observer: AnyCancellable?

    init<Content: View>(title: String, model: AppModel, rootView: Content) {
        let controller = NSHostingController(rootView: rootView)
        controller.sizingOptions = []
        window = SettingsWindow(contentViewController: controller)
        // Not `view.fittingSize`: it stays zero for these windows (seen on macOS 27.2).
        measure = { [unowned controller] in controller.sizeThatFits(in: $0) }
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        fit()
        window.center()
        observer = model.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.fit() }
    }

    func show() {
        fit()
        window.showInFront()
    }

    func close() {
        window.close()
    }

    var isVisible: Bool { window.isVisible }

    /// ⌘ and a key of the digit row (see `SettingsWindow`); true when it did something.
    var onCommandDigit: ((Int) -> Bool)? {
        get { window.onCommandDigit }
        set { window.onCommandDigit = newValue }
    }

    /// Resize the window to the SwiftUI content's ideal height, keeping its top edge in place.
    private func fit() {
        let size = measure(NSSize(width: 2000, height: 5000))
        guard size.width > 0, size.height > 0,
              abs(window.contentLayoutRect.height - size.height) > 0.5
                || abs(window.contentLayoutRect.width - size.width) > 0.5 else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        // A taller tab must not end below the screen.
        if let bottom = window.screen?.visibleFrame.minY, window.frame.minY < bottom {
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: bottom))
        }
    }
}

/// The settings window of an agent app has no menu bar, hence no File > Close item:
/// handle ⌘W here (HIG: every window closes with ⌘W).
final class SettingsWindow: NSWindow {
    var onCommandDigit: ((Int) -> Bool)?

    /// Key codes of 1 to 9 on the digit row. The position, not the character: on a French
    /// keyboard, among others, these keys type something else without Shift, and ⌘⇧ with a
    /// digit takes screenshots.
    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
            if event.charactersIgnoringModifiers == "w" {
                performClose(nil)
                return true
            }
            if let index = Self.digitKeyCodes.firstIndex(of: event.keyCode), onCommandDigit?(index + 1) == true {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
