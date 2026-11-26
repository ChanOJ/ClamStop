import Foundation
import ClamStopShared

/// Runs as an AI agent hook (`ClamStop --agent-hook claude`): reads the event the agent writes
/// on standard input, adds the agent's process ID, sends it to the daemon and exits. Prints
/// nothing (Claude Code adds a UserPromptSubmit hook's output to the conversation) and always
/// exits 0 within about 2 s, so that a missing daemon never slows down or breaks the agent.
enum AgentHook {
    static let timeout: TimeInterval = 2

    static func run(agent: AgentKind) {
        let input = FileHandle.standardInput.readDataToEndOfFile().prefix(1_000_000)
        guard var message = AgentHookMessage.fromHookInput(Data(input), agent: agent) else { return }
        if let process = ProcessTable.agentAncestor(of: getppid(), kind: agent) {
            message.agentPID = process.pid
            message.agentStartMicros = process.startMicros
        }
        guard let payload = try? JSONEncoder().encode(message) else { return }

        let connection = NSXPCConnection(machServiceName: ClamStopID.machServiceName, options: .privileged)
        connection.remoteObjectInterface = .clamStopDaemon()
        connection.resume()
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? ClamStopDaemonXPC
        proxy?.agentEvent(payload) { _ in done.signal() }
        _ = done.wait(timeout: .now() + timeout)
        connection.invalidate()
    }
}
