@testable import ClamStopAppCore
@testable import ClamStopShared
import Foundation
import Testing

@Suite struct AgentHookFileTests {
    private let executable = "/Applications/ClamStop.app/Contents/MacOS/ClamStop"
    private let claude = AgentHookTarget.all.first { $0.agent == .claude }!
    private let fm = FileManager.default

    private func folder() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isLink(_ url: URL) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    @Test func writesThroughASymbolicLink() throws {
        let home = try folder()
        defer { try? fm.removeItem(at: home) }
        let real = home.appendingPathComponent("real.json")
        let link = home.appendingPathComponent("settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: real)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "real.json")
        try AgentHookFile.install(claude, at: link, executable: executable)
        #expect(isLink(link))
        #expect(AgentHookFile.read(real)?["hooks"] != nil)
        let backup = AgentHookFile.backup(of: link)
        #expect(!isLink(backup))
        #expect(try String(contentsOf: backup, encoding: .utf8) == #"{"model":"opus"}"#)
        try AgentHookFile.uninstall(claude, at: link)
        #expect(isLink(link))
        #expect(AgentHookFile.read(real)?["hooks"] == nil)
        #expect(AgentHookFile.read(real)?["model"] as? String == "opus")
        #expect(!fm.fileExists(atPath: backup.path))
    }

    @Test func writesThroughALinkToAFileNotThereYet() throws {
        let home = try folder()
        defer { try? fm.removeItem(at: home) }
        let link = home.appendingPathComponent("settings.json")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "later.json")
        try AgentHookFile.install(claude, at: link, executable: executable)
        #expect(isLink(link))
        #expect(AgentHookFile.read(home.appendingPathComponent("later.json"))?["hooks"] != nil)
    }

    @Test func anUnreadableFileAndItsBackupAreLeftAlone() throws {
        let home = try folder()
        defer { try? fm.removeItem(at: home) }
        let file = home.appendingPathComponent("settings.json")
        let backup = AgentHookFile.backup(of: file)
        try Data("{ not json".utf8).write(to: file)
        try Data("{}".utf8).write(to: backup)
        #expect(throws: (any Error).self) {
            try AgentHookFile.install(claude, at: file, executable: executable)
        }
        try AgentHookFile.uninstall(claude, at: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{}")
    }

    @Test func theShellReadsThePathAsItIs() throws {
        let home = try folder()
        defer { try? fm.removeItem(at: home) }
        let path = home.appendingPathComponent(#"a "b" $HOME `id` \\ c"#).path
        let command = claude.command(executable: path, event: "Stop")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "printf '%s\\n' " + command]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) == path)
        #expect(claude.command(executable: executable, event: "Stop")
            == "\"\(executable)\" --agent-hook claude")
    }

    @Test func onlyAnInstalledCopyRepointsHooks() {
        let home = "/Users/someone"
        func may(_ path: String) -> Bool { AgentHookTarget.mayRepointHooks(toAppAt: path, home: home) }
        #expect(may("/Applications/ClamStop.app"))
        #expect(may("/Users/someone/Applications/ClamStop.app"))
        #expect(!may("/Volumes/ClamStop/ClamStop.app"))
        #expect(!may("/Users/someone/Downloads/ClamStop.app"))
        #expect(!may("/private/var/folders/x/AppTranslocation/y/d/ClamStop.app"))
    }
}
