import Foundation
import Testing
@testable import ClamStopShared

/// The agents beyond Claude Code and Codex. Hook inputs follow each agent's documentation
/// (read 2026-11-28); none of these agents has been tried for real yet.
private func parse(_ json: String, _ agent: AgentKind, event: String? = nil) -> AgentHookMessage? {
    AgentHookMessage.fromHookInput(Data(json.utf8), agent: agent, event: event)
}

@Suite struct AgentInputTests {
    @Test func geminiEvents() {
        let start = parse(#"{"hook_event_name":"BeforeAgent","session_id":"g","transcript_path":"/t.json"}"#, .gemini)
        #expect(start?.event == "UserPromptSubmit")
        #expect(start?.transcriptPath == "/t.json")
        #expect(parse(#"{"hook_event_name":"AfterAgent","session_id":"g"}"#, .gemini)?.event == "Stop")
    }

    @Test func cursorUsesTheConversationIdentifierOnEveryEvent() {
        let start = parse(#"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c","transcript_path":null}"#, .cursor)
        let end = parse(#"{"hook_event_name":"sessionEnd","conversation_id":"c","session_id":"other"}"#, .cursor)
        #expect(start?.event == "UserPromptSubmit")
        #expect(start?.sessionID == "c")
        #expect(end?.event == "SessionEnd")
        #expect(end?.sessionID == "c")
        #expect(parse(#"{"hook_event_name":"stop","conversation_id":"c"}"#, .cursor)?.event == "Stop")
    }

    @Test func copilotEventComesFromTheCommandLine() {
        let json = #"{"sessionId":"p","transcriptPath":"/p.jsonl"}"#
        #expect(parse(json, .copilot, event: "userPromptSubmitted")?.event == "UserPromptSubmit")
        #expect(parse(json, .copilot, event: "agentStop")?.event == "Stop")
        #expect(parse(json, .copilot, event: "agentStop")?.transcriptPath == "/p.jsonl")
        #expect(parse(json, .copilot) == nil)
    }

    @Test func antigravityStopsOnlyWhenIdle() {
        #expect(parse(#"{"conversationId":"a"}"#, .antigravity, event: "PreInvocation")?.event == "UserPromptSubmit")
        #expect(parse(#"{"conversationId":"a","fullyIdle":false}"#, .antigravity, event: "Stop") == nil)
        #expect(parse(#"{"conversationId":"a","fullyIdle":true}"#, .antigravity, event: "Stop")?.event == "Stop")
    }

    @Test func repliesLetEachAgentCarryOn() {
        #expect(AgentHookMessage.hookReply(agent: .claude, event: nil) == nil)
        #expect(AgentHookMessage.hookReply(agent: .codex, event: nil) == nil)
        #expect(AgentHookMessage.hookReply(agent: .gemini, event: nil) == "{}")
        #expect(AgentHookMessage.hookReply(agent: .copilot, event: "agentStop") == "{}")
        #expect(AgentHookMessage.hookReply(agent: .cursor, event: nil) == #"{"continue":true}"#)
        #expect(AgentHookMessage.hookReply(agent: .antigravity, event: "PreInvocation") == "{}")
        #expect(AgentHookMessage.hookReply(agent: .antigravity, event: "Stop") == #"{"decision":"stop"}"#)
    }
}

@Suite struct AgentHookTargetTests {
    private let executable = "/Applications/ClamStop.app/Contents/MacOS/ClamStop"

    private func merged(_ target: AgentHookTarget, into settings: [String: Any], path: String? = nil) -> [String: Any] {
        AgentHookSettings.merging(into: settings, layout: target.layout, events: target.events) {
            target.command(executable: path ?? executable, event: $0)
        }
    }

    private func state(_ target: AgentHookTarget, _ settings: [String: Any]) -> AgentHookSettings.State {
        AgentHookSettings.state(of: settings, layout: target.layout, events: target.events) {
            target.command(executable: executable, event: $0)
        }
    }

    private func target(_ agent: AgentKind) -> AgentHookTarget {
        AgentHookTarget.all.first { $0.agent == agent }!
    }

    @Test func everyAgentHasOneTarget() {
        #expect(AgentHookTarget.all.map(\.agent).sorted { $0.rawValue < $1.rawValue }
            == AgentKind.allCases.sorted { $0.rawValue < $1.rawValue })
    }

    @Test(arguments: AgentKind.allCases) func installIsIdempotentAndRemovable(agent: AgentKind) {
        let target = target(agent)
        let once = merged(target, into: [:])
        let twice = merged(target, into: once)
        #expect(NSDictionary(dictionary: once).isEqual(to: twice))
        #expect(state(target, twice) == .installed)
        let removed = AgentHookSettings.removing(from: twice, layout: target.layout)
        #expect(state(target, removed) == .notInstalled)
        #expect(AgentHookSettings.isEmpty(removed))
    }

    @Test(arguments: AgentKind.allCases) func anotherCopyIsOutdated(agent: AgentKind) {
        let target = target(agent)
        let old = merged(target, into: [:], path: "/tmp/ClamStop.app/Contents/MacOS/ClamStop")
        #expect(state(target, old) == .outdated)
        #expect(state(target, merged(target, into: old)) == .installed)
    }

    @Test func cursorKeepsOtherHooks() throws {
        let user: [String: Any] = ["version": 1, "hooks": ["stop": [["command": "./notify.sh"]]]]
        let removed = AgentHookSettings.removing(from: merged(target(.cursor), into: user), layout: .flat)
        #expect(NSDictionary(dictionary: removed).isEqual(to: user))
    }

    @Test func antigravityKeepsOtherHooks() {
        let user: [String: Any] = ["lint": ["Stop": [["type": "command", "command": "lint.sh"]]]]
        let removed = AgentHookSettings.removing(from: merged(target(.antigravity), into: user), layout: .named)
        #expect(NSDictionary(dictionary: removed).isEqual(to: user))
    }

    @Test func commandCarriesTheEventOnlyWhenNeeded() {
        #expect(target(.cursor).command(executable: "/C", event: "stop") == #""/C" --agent-hook cursor"#)
        #expect(target(.copilot).command(executable: "/C", event: "agentStop") == #""/C" --agent-hook copilot agentStop"#)
        // Hooks installed by earlier versions stay as they are.
        #expect(target(.claude).command(executable: "/C", event: "Stop") == #""/C" --agent-hook claude"#)
    }

    @Test func geminiAndAntigravityShareAFolder() {
        func found(_ paths: Set<String>) -> [AgentKind] {
            AgentHookTarget.all.filter { $0.isFound(exists: paths.contains) }.map(\.agent)
        }
        #expect(found([".gemini"]) == [.gemini])
        #expect(found([".gemini", ".gemini/antigravity-cli"]) == [.antigravity])
        #expect(found([".gemini", ".gemini/config", ".gemini/settings.json"]) == [.gemini, .antigravity])
        #expect(found([]) == [])
    }
}

@Suite struct AgentProcessTests {
    @Test func binariesAndScripts() {
        #expect(ProcessTable.agentKind(ofExecutable: "/usr/local/bin/agy") == .antigravity)
        #expect(ProcessTable.agentKind(ofExecutable: "/opt/homebrew/bin/node", script: "/opt/homebrew/bin/gemini") == .gemini)
        #expect(ProcessTable.agentKind(ofExecutable: "/x/node",
                                       script: "/x/lib/node_modules/@github/copilot/index.js") == .copilot)
        #expect(ProcessTable.agentKind(ofExecutable: "/x/node",
                                       script: "/Users/a/.local/share/cursor-agent/versions/1/index.js") == .cursor)
        #expect(ProcessTable.agentKind(ofExecutable: "/x/node", script: "/x/server.js") == nil)
        // The desktop apps are not anchors.
        #expect(ProcessTable.agentKind(ofExecutable: "/Applications/Cursor.app/Contents/MacOS/Cursor") == nil)
    }

    @Test func scriptInArguments() {
        #expect(ProcessTable.script(inArguments: ["node", "--max-old-space-size=8192", "/x/gemini"]) == "/x/gemini")
        #expect(ProcessTable.script(inArguments: ["node", "--require", "/hook.js", "/x/copilot"]) == "/x/copilot")
        #expect(ProcessTable.script(inArguments: ["python3", "-m", "aider"]) == "aider")
        #expect(ProcessTable.script(inArguments: ["python3", "-c", "print(1)"]) == nil)
        #expect(ProcessTable.script(inArguments: ["node"]) == nil)
    }

    @Test func argumentsOfARealProcess() throws {
        let arguments = try #require(ProcessTable.arguments(getpid()))
        #expect(arguments.first == CommandLine.arguments.first)
        #expect(arguments.count == CommandLine.arguments.count)
    }

    @Test func aScriptIsAWatchedCommand() {
        let aider = WatchedApp(name: "Aider", executables: ["aider"])
        func process(_ script: String?) -> ProcessTable.Entry {
            ProcessTable.Entry(pid: 1, parent: 0, startMicros: 0, path: "/x/Python", script: script)
        }
        #expect(aider.matches(process("/Users/a/.local/bin/aider")))
        #expect(aider.matches(process("aider")))
        #expect(!aider.matches(process("/x/other.py")))
        #expect(!aider.matches(process(nil)))
    }
}
