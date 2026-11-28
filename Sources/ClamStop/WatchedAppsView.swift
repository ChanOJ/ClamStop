import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClamStopShared

/// Stay Awake: the apps and commands that keep the Mac awake while they work (spec C5).
struct WatchedAppsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            OptionRow(title: "Stay awake while these apps work",
                      note: "While one of them is busy, your Mac stays awake, even with the lid closed, then sleeps as usual.") {
                Menu("Add App…") {
                    ForEach(model.knownApps.filter { known in
                        !model.settings.watchedApps.contains { $0.watchesTheSame(as: known) }
                    }) { app in
                        Button(app.name) { model.watch(app) }
                    }
                    Divider()
                    Button("Other App…") { model.chooseAppToWatch() }
                    Button("Command…") { model.askForCommandToWatch() }
                }
                .fixedSize()
            }
            ForEach(model.settings.watchedApps) { app in
                WatchedAppRow(model: model, app: app)
            }
        } footer: {
            Footnote("An app works when it keeps your Mac awake on its own or uses the processor. The guards of the Safety tab apply.")
        }
        .disabled(!model.serviceRunning || !model.settings.enabled)
        .onAppear { model.findKnownApps() }
    }
}

private struct WatchedAppRow: View {
    @ObservedObject var model: AppModel
    let app: WatchedApp

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(verbatim: app.name)
            Spacer(minLength: 8)
            if let state = model.status?.apps?.first(where: { $0.id == app.id })?.state {
                Text(title(state))
                    .foregroundStyle(state == .working || state == .finishing ? Color.accentColor : Color.secondary)
            }
            Button { model.stopWatching(app) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove from the list")
                .accessibilityLabel(Text("Remove \(app.name) from the list"))
        }
    }

    @ViewBuilder private var icon: some View {
        if let path = app.bundlePath, FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
        } else {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
        }
    }

    private func title(_ state: WatchedAppActivity.State) -> LocalizedStringKey {
        switch state {
        case .notRunning: "Not running"
        case .idle: "Idle"
        case .working: "Working now"
        case .finishing: "Finishing"
        }
    }
}

/// Apps and commands known for their long jobs, offered when they are on this Mac.
enum KnownApps {
    private struct Candidate {
        let name: String
        /// Beginning of the app bundle's name (Premiere Pro carries the year).
        var appName: String?
        var executables: [String] = []
        /// Files whose presence shows the commands are installed.
        var commandFiles: [String] = []
    }

    private static func commands(_ name: String) -> [String] {
        ["/opt/homebrew/bin/", "/usr/local/bin/", NSHomeDirectory() + "/.local/bin/"].map { $0 + name }
    }

    private static let candidates: [Candidate] = [
        Candidate(name: "HandBrake", appName: "HandBrake", executables: ["HandBrakeCLI"],
                  commandFiles: commands("HandBrakeCLI")),
        Candidate(name: "Final Cut Pro", appName: "Final Cut Pro"),
        Candidate(name: "Compressor", appName: "Compressor"),
        Candidate(name: "DaVinci Resolve", appName: "DaVinci Resolve"),
        Candidate(name: "Premiere Pro", appName: "Adobe Premiere Pro"),
        Candidate(name: "Blender", appName: "Blender"),
        // An AI agent without a hook for the start of a task: followed like any command.
        Candidate(name: "Aider", executables: ["aider"], commandFiles: commands("aider")),
        Candidate(name: "ffmpeg", executables: ["ffmpeg"], commandFiles: commands("ffmpeg")),
        Candidate(name: "Xcode Builds", executables: ["xcodebuild", "SWBBuildService", "XCBBuildService", "swift-build"],
                  commandFiles: ["/Applications/Xcode.app", "/Library/Developer/CommandLineTools/usr/bin/swift-build"]),
        Candidate(name: "Ollama", appName: "Ollama", executables: ["ollama"], commandFiles: commands("ollama")),
        Candidate(name: "LM Studio", appName: "LM Studio"),
    ]

    /// The candidates found in the Applications folders (and one folder below) or as commands.
    static func installed() -> [WatchedApp] {
        let fm = FileManager.default
        var bundles: [URL] = []
        for root in [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if item.pathExtension == "app" {
                    bundles.append(item)
                } else {
                    bundles += ((try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.pathExtension == "app" }
                }
            }
        }
        return candidates.compactMap { candidate in
            let bundle = candidate.appName.flatMap { name in
                bundles.first { $0.deletingPathExtension().lastPathComponent.hasPrefix(name) }
            }
            guard bundle != nil || candidate.commandFiles.contains(where: fm.fileExists) else { return nil }
            return WatchedApp(name: candidate.name, bundlePath: bundle?.path, executables: candidate.executables)
        }
    }
}

extension AppModel {
    func findKnownApps() {
        let found = KnownApps.installed()
        // Keep the identifiers: the menu compares what is watched, not them.
        if !found.elementsEqual(knownApps, by: { $0.watchesTheSame(as: $1) }) { knownApps = found }
    }

    func watch(_ app: WatchedApp) {
        changeSettings {
            guard !$0.watchedApps.contains(where: { $0.watchesTheSame(as: app) }) else { return }
            $0.watchedApps.append(app)
        }
    }

    func stopWatching(_ app: WatchedApp) {
        changeSettings { $0.watchedApps.removeAll { $0.id == app.id } }
    }

    func chooseAppToWatch() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose an app. Your Mac stays awake while it works.")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url?.resolvingSymlinksInPath() else { return }
        watch(WatchedApp(name: url.deletingPathExtension().lastPathComponent, bundlePath: url.path))
    }

    /// A command is recognised by the name of its program.
    func askForCommandToWatch() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "rsync"
        let alert = NSAlert()
        alert.messageText = String(localized: "Add a command")
        alert.informativeText = String(localized: "Type the name of the program, as in Terminal. Your Mac stays awake while it works.")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = (field.stringValue.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return }
        watch(WatchedApp(name: name, executables: [name]))
    }
}
