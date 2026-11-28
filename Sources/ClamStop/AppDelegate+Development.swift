import AppKit
import ClamStopShared

// Command-line development aids, for docs and reviews. Their flags are listed in
// `Main.developmentRunFlags`, so that such runs start without a menu bar item.
extension AppDelegate {
    /// Development aids, for docs and reviews (no Screen Recording permission needed):
    /// - `--appearance light|dark`: force the appearance;
    /// - `--export-icons dir`: write the menu bar icons in every state to PNG files and quit;
    /// - `--export-illustration file.png`: write `ApprovalIllustration` to a PNG and quit
    ///   (README images); returns true then;
    /// - `--export-diagnostics file.txt`: write what "Copy Diagnostics" copies and quit; returns
    ///   true then.
    func runDevelopmentCommands() -> Bool {
        switch Self.argument(after: "--appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let directory = Self.argument(after: "--export-icons") {
            // Menu bar icons in every state, 4x, black on clear (review aid).
            for style in MenuBarIconStyle.allCases {
                for (name, state) in [("active", MenuBarIconState.active), ("agents", .awake(.agents)),
                                      ("session", .awake(.session)), ("app", .awake(.app)), ("inactive", .inactive)] {
                    let image = style.image(state)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 4),
                                               pixelsHigh: Int(image.size.height * 4), bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = image.size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    image.draw(in: NSRect(origin: .zero, size: image.size))
                    NSGraphicsContext.restoreGraphicsState()
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("\(style.rawValue)-\(name).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
            NSApp.terminate(nil)
            return true
        }
        if let path = Self.argument(after: "--export-diagnostics") {
            Task {
                await model.readServiceOnce()
                let text = await model.diagnosticsText()
                do {
                    try text.write(toFile: path, atomically: true, encoding: .utf8)
                } catch {
                    FileHandle.standardError.write(Data("cannot write \(path): \(error)\n".utf8))
                }
                NSApp.terminate(nil)
            }
            return true
        }
        guard let path = Self.argument(after: "--export-illustration") else { return false }
        do {
            try ApprovalIllustration.export(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("cannot write \(path): \(error)\n".utf8))
        }
        NSApp.terminate(nil)
        return true
    }

    private static func argument(after name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Development aid: `ClamStop --snapshot /path/to/file.png [--tab name]
    /// [--show-help [agent]] [--welcome step] [--until] [--journal] [--awake]` renders the visible windows to
    /// PNG files (no Screen Recording permission needed), for docs and reviews.
    func snapshotIfRequested() {
        guard let path = Self.argument(after: "--snapshot") else { return }
        let args = CommandLine.arguments
        let url = URL(fileURLWithPath: path)
        // SwiftUI only builds its accessibility tree for an assistive technology.
        if args.contains("--dump-accessibility") {
            NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                          with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        }
        if let step = Self.argument(after: "--welcome").flatMap(Int.init) {
            model.firstRunStep = step
            if args.contains("agents") { model.firstRunChoice = .agents }
            showWelcome()
        } else if args.contains("--until") {
            showSessionUntil()
        } else if args.contains("--journal") {
            showJournal()
        } else if args.contains("--awake") {
            showAwake()
        } else {
            showSettings()
        }
        if args.contains("--show-help") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if args.contains("agent") {
                    self.model.showAgentHelp = true
                } else {
                    self.model.showLidHelp = true
                }
            }
        }
        // Each visible window (settings, popover) to file.png, file.1.png, …
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 50 }
            for (index, window) in windows.enumerated() {
                guard let view = window.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let target = index == 0 ? url : url.deletingPathExtension()
                    .appendingPathExtension("\(index)").appendingPathExtension("png")
                try? rep.representation(using: .png, properties: [:])?.write(to: target)
            }
            // Development aid (`--dump-accessibility`, with `--snapshot`): what VoiceOver is
            // given, printed as a tree.
            if args.contains("--dump-accessibility") {
                windows.forEach { Self.dumpAccessibility($0, depth: 0) }
                fflush(stdout)
            }
        }
    }

    private static func dumpAccessibility(_ element: NSObject, depth: Int) {
        func read(_ name: String, of element: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        let texts = ["accessibilityRole", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
            .map { name in read(name, of: element).map { "\($0)" } ?? "" }
        // Controls can take their name from a neighbouring text.
        let titledBy = (read("accessibilityTitleUIElement", of: element) as? NSObject)
            .flatMap { read("accessibilityValue", of: $0) }
        print(String(repeating: "  ", count: depth)
              + "\(texts[0]) label=\(texts[1]) title=\(texts[2]) value=\(texts[3])"
              + (titledBy.map { " titled by=\($0)" } ?? ""))
        guard depth < 20 else { return }
        for child in read("accessibilityChildren", of: element) as? [NSObject] ?? [] {
            dumpAccessibility(child, depth: depth + 1)
        }
    }
}
