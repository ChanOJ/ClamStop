import AppKit
import SwiftUI

/// Development aid: `ClamStop --mockups <dir> [--icon <icns>]` renders every mockup screen to
/// PNG files in `<dir>` plus an `index.html` contact sheet, then quits. Windows are drawn with
/// `cacheDisplay` (no Screen Recording permission), kept invisible (alpha 0). Dark appearance
/// only, as asked during the review. Used by `scripts/mockups.sh`.
@MainActor
enum MockupRenderer {
    struct Screen {
        let id: String
        let title: String
        let note: String
        /// Window title; nil = no window frame (the menu drawing).
        let windowTitle: String?
        var editions: [Edition] = Edition.allCases
        let configure: (MockupModel) -> Void
        let view: (MockupModel) -> AnyView
    }

    struct Rendered {
        let screen: Screen
        let edition: Edition
        let file: String
        let size: NSSize
        /// Unique sequential number shown on the contact sheet, for quick references.
        let number: Int
    }

    private static let tabNames: [SettingsTab: String] = [
        .sessions: "Stay Awake", .rules: "Rules", .safety: "Safety", .more: "More",
    ]

    static var screens: [Screen] {
        let firstRun: (MockupModel) -> AnyView = { AnyView(FirstRunView(model: $0)) }
        let settings: (MockupModel) -> AnyView = { AnyView(SettingsMockupView(model: $0)) }
        let menu: (MockupModel) -> AnyView = { AnyView(MenuMockupView(model: $0)) }
        return [
            Screen(id: "first-run-1", title: "First run 1: what happens when the lid closes",
                   note: "The Store edition has no step counter (single screen); its second choice needs power.",
                   windowTitle: "Welcome to ClamStop", configure: { _ in }, view: firstRun),
            Screen(id: "first-run-1-battery", title: "First run 1: battery choice picked",
                   note: "The consequence is said next to the risky choice.",
                   windowTitle: "Welcome to ClamStop", editions: [.full],
                   configure: { $0.firstRunLidChoice = .keepWorking }, view: firstRun),
            Screen(id: "first-run-1-agents", title: "First run 1: AI agents choice picked",
                   note: "A warning about heat, next to the risky choice.",
                   windowTitle: "Welcome to ClamStop",
                   configure: { $0.firstRunLidChoice = .agents }, view: firstRun),
            Screen(id: "first-run-2-waiting", title: "First run 2: allow the background service (waiting)",
                   note: "Full edition only. Detected automatically when the switch is turned on.",
                   windowTitle: "Welcome to ClamStop", editions: [.full],
                   configure: { $0.firstRunStep = 2 }, view: firstRun),
            Screen(id: "first-run-2-done", title: "First run 2: allowed",
                   note: "Full edition only.",
                   windowTitle: "Welcome to ClamStop", editions: [.full],
                   configure: { $0.firstRunStep = 2; $0.serviceApproved = true }, view: firstRun),
            Screen(id: "first-run-3", title: "First run 3: hibernation",
                   note: "Full edition only. Every delay is available in Settings; the default stays 1 hour.",
                   windowTitle: "Welcome to ClamStop", editions: [.full],
                   configure: { $0.firstRunStep = 3 }, view: firstRun),
            Screen(id: "menu", title: "Menu bar menu, Stay Awake submenu open",
                   note: "Drawn in SwiftUI: a real NSMenu cannot be rendered to an image. Hibernate Now is full edition only.",
                   windowTitle: nil, configure: { _ in }, view: menu),
            Screen(id: "menu-session", title: "Menu bar menu while staying awake",
                   note: "The remaining time also shows next to the icon. Store edition: the lid-closed part needs power.",
                   windowTitle: nil,
                   configure: { $0.menuState = .session }, view: menu),
            Screen(id: "settings-general", title: "Settings: General tab",
                   note: "The Store edition has no Hibernate picker, no background service and no donation link.",
                   windowTitle: "ClamStop Settings", configure: { _ in }, view: settings),
        ] + SettingsTab.allCases.dropFirst().map { tab in
            Screen(id: "settings-\(tab.rawValue)", title: "Settings: \(tabNames[tab] ?? tab.rawValue) tab",
                   note: tab == .safety ? "On by default." : "Some options exist only in the full edition (background service).",
                   windowTitle: "ClamStop Settings",
                   configure: { $0.settingsTab = tab }, view: settings)
        } + [
            Screen(id: "about", title: "About window",
                   note: "Full edition: website, source code, Buy me a coffee. Store edition: Help link only (guideline 3.1.1).",
                   windowTitle: "About ClamStop", configure: { _ in }, view: { AnyView(AboutView(model: $0)) }),
        ]
    }

    static func run(outputDirectory: URL) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                var rendered: [Rendered] = []
                for screen in screens {
                    for edition in screen.editions {
                        let file = "\(String(format: "%02d", rendered.count + 1))-\(screen.id)-\(edition.rawValue).png"
                        let size = try await render(screen, edition: edition,
                                                    to: outputDirectory.appendingPathComponent(file))
                        rendered.append(Rendered(screen: screen, edition: edition, file: file, size: size,
                                                 number: rendered.count + 1))
                    }
                }
                try contactSheet(rendered).write(to: outputDirectory.appendingPathComponent("index.html"),
                                                 atomically: true, encoding: .utf8)
                print("\(rendered.count) mockups in \(outputDirectory.path)")
            } catch {
                FileHandle.standardError.write(Data("mockups failed: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    /// Renders one screen; returns its size in points.
    private static func render(_ screen: Screen, edition: Edition, to url: URL) async throws -> NSSize {
        let model = MockupModel(edition: edition)
        screen.configure(model)
        let controller = NSHostingController(rootView: screen.view(model))
        controller.sizingOptions = []
        let hosting = controller.view
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
            styleMask: screen.windowTitle == nil ? [.borderless] : [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = screen.windowTitle ?? ""
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        window.contentView = hosting
        // Size to the content, let SwiftUI lay out, then size again (wrapping text can change it).
        for _ in 0..<2 {
            window.setContentSize(controller.sizeThatFits(in: NSSize(width: 2000, height: 5000)))
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(400))
        }
        let view: NSView = screen.windowTitle == nil ? hosting : (hosting.superview ?? hosting)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        window.orderOut(nil)
        return view.bounds.size
    }

    /// One HTML page with every screen, filterable by edition; refresh it after each run.
    private static func contactSheet(_ items: [Rendered]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        var html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>ClamStop mockups</title>
        <style>
        body{background:#1b1b1d;color:#ddd;font:14px -apple-system,system-ui;margin:24px}
        h1{font-size:20px;margin:0 0 4px} h2{font-size:16px;margin:36px 0 2px;color:#fff}
        .note{color:#999;margin:0 0 12px} .grid{display:flex;flex-wrap:wrap;gap:24px;align-items:flex-start}
        figure{margin:0} figcaption{color:#aaa;font-size:12px;margin-top:6px} figcaption b{color:#fff;font-size:15px;margin-right:6px}
        .bar{position:sticky;top:0;background:#1b1b1d;padding:8px 0;border-bottom:1px solid #333;z-index:1}
        label{margin-right:16px} .hidden{display:none}
        </style></head><body>
        <h1>ClamStop mockups</h1>
        <div class="note">Dark appearance. Generated \(Date().formatted(date: .abbreviated, time: .shortened)) by scripts/mockups.sh; refresh after each run.</div>
        <div class="bar">
        <label><input type="checkbox" data-f="full" checked> Full edition</label>
        <label><input type="checkbox" data-f="store" checked> Store edition</label>
        </div>
        """
        var currentID = ""
        for item in items {
            if item.screen.id != currentID {
                if !currentID.isEmpty { html += "</div>\n" }
                currentID = item.screen.id
                html += "<h2 id=\"\(item.screen.id)\">\(esc(item.screen.title))</h2><p class=\"note\">\(esc(item.screen.note))</p><div class=\"grid\">\n"
            }
            let edition = item.edition == .full ? "Full" : "Store"
            html += """
            <figure id="\(item.number)" data-edition="\(item.edition.rawValue)">\
            <img src="\(item.file)?t=\(Int(Date().timeIntervalSince1970))" width="\(Int(item.size.width))" alt="\(esc(item.screen.title)), \(edition)">\
            <figcaption><b>#\(item.number)</b>\(edition) edition</figcaption></figure>\n
            """
        }
        html += """
        </div>
        <script>
        const boxes=[...document.querySelectorAll('.bar input')];
        function apply(){const on=Object.fromEntries(boxes.map(b=>[b.dataset.f,b.checked]));
        document.querySelectorAll('figure').forEach(f=>f.classList.toggle('hidden',!on[f.dataset.edition]));}
        boxes.forEach(b=>b.addEventListener('change',apply));
        </script></body></html>
        """
        return html
    }
}
