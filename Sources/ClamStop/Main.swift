import AppKit
import ClamStopShared

/// Entry point. `ClamStop --agent-hook claude|codex` is the command written into the AI agents'
/// hook settings: it forwards the hook event to the daemon and exits, without starting the app.
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--agent-hook") {
            let agent = i + 1 < args.count ? AgentKind(rawValue: args[i + 1]) : nil
            AgentHook.run(agent: agent ?? .claude)
            exit(0)  // never fail or block the agent
        }
        guard args.contains(where: developmentRunFlags.contains) else {
            ClamStopApp.main()
            return
        }
        // Previews and exports share the installed app's preferences: no menu bar item at all.
        // One would be saved as hidden there, and the running app's icon would disappear
        // (seen 2026-11-27).
        MainActor.assumeIsolated {
            let delegate = AppDelegate()
            NSApplication.shared.delegate = delegate
            withExtendedLifetime(delegate) { NSApplication.shared.run() }
        }
    }

    /// Development aids that show windows or write images (see `AppDelegate`).
    private static let developmentRunFlags: Set<String> = [
        "--preview-settings", "--preview-approval", "--snapshot", "--mockups", "--export-icons",
        "--export-illustration",
    ]
}
