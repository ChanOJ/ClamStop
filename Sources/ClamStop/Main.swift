import Foundation
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
        ClamStopApp.main()
    }
}
