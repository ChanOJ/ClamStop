// The text of "Copy Diagnostics" and of a problem report (spec H4). English only: it is read by
// whoever helps. Nothing is sent by ClamStop itself.

import ClamStopShared
import Foundation

public struct DiagnosticsReport: Sendable {
    public var date: Date
    public var appVersion: String
    public var macOSVersion: String
    public var model: String
    public var thermalLevel: ThermalLevel?
    /// What holds sleep off (spec H2): names, kinds and durations, never the assertions' names.
    public var awake: AwakeList?
    public var facts: HealthFacts
    /// nil when the service did not give its journal.
    public var events: [SleepEvent]?
    /// ClamStop's lines of the unified log, or why they could not be read.
    public var log: Result<String, LogUnavailable>

    public struct LogUnavailable: Error, Equatable, Sendable {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    public static let eventLimit = 50
    public static let logLineLimit = 300
    /// A GitHub issue takes 65 536 characters: room is left for the description.
    public static let characterLimit = 60_000

    public init(date: Date, appVersion: String, macOSVersion: String, model: String, facts: HealthFacts,
                events: [SleepEvent]?, log: Result<String, LogUnavailable>, thermalLevel: ThermalLevel? = nil) {
        self.date = date
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.model = model
        self.facts = facts
        self.events = events
        self.log = log
        self.thermalLevel = thermalLevel
    }

    /// The whole report, with the home folder written `~`. Beyond the limits, the oldest log lines
    /// go first.
    public func text(home: String, characterLimit: Int = Self.characterLimit) -> String {
        var head = ["ClamStop diagnostics",
                    "Date: \(Self.format(date))",
                    "ClamStop: \(appVersion)",
                    "macOS: \(macOSVersion)",
                    "Mac: \(model)"]
        let status = facts.status
        if let thermalLevel { head.append("Thermal level: \(thermalLevel.rawValue)") }
        if let adapter = status?.onPowerAdapter {
            let battery = status?.batteryPercent.map { ", battery \($0) %" } ?? ""
            head.append("Power: \(adapter ? "adapter" : "battery")\(battery)")
        }

        head += ["", "## Health check"]
        head += HealthCheck.evaluate(facts).map { "\($0.level.rawValue.uppercased()) \($0.kind.rawValue)" }
        head.append("Service state: \(facts.service.rawValue)")
        head.append("Notifications: \(facts.notifications.rawValue)")
        if !facts.agentsMissingHooks.isEmpty {
            head.append("Agents without hook: \(facts.agentsMissingHooks.joined(separator: ", "))")
        }

        head += ["", "## macOS sleep"]
        if let system = facts.system {
            head.append("SleepDisabled: \(system.sleepDisabled.map(String.init) ?? "unknown")")
            head.append("hibernatemode: \(system.hibernateMode.map(String.init) ?? "unknown")")
            head.append("ClamStop wakes: \(system.scheduledWakes.map(Self.format).joined(separator: ", ").orNone)")
        } else {
            head.append("not read")
        }

        if let awake {
            head += ["", "## Holding sleep off"]
            head += Self.lines(awake, now: date)
        }

        // The status holds the settings; its notices are in the journal and the log already.
        head += ["", "## Service status"]
        if var status {
            status.notices = nil
            head.append(Self.json(status))
        } else {
            head.append("no answer from the service")
        }

        head += ["", "## Sleep journal (last \(Self.eventLimit) events)"]
        if let events {
            head += events.suffix(Self.eventLimit).map(Self.line)
            if events.isEmpty { head.append("empty") }
        } else {
            head.append("not available")
        }

        head += ["", "## Log (last hour)"]
        var lines: [String]
        switch log {
        case .success(let text):
            lines = text.split(separator: "\n").suffix(Self.logLineLimit).map(String.init)
            if lines.isEmpty { lines = ["empty"] }
        case .failure(let error):
            lines = ["not available: \(error.reason)"]
        }

        let start = Self.redact(head.joined(separator: "\n"), home: home)
        var kept: [String] = []
        var room = characterLimit - start.count
        for line in lines.reversed() {
            let clean = Self.redact(line, home: home)
            room -= clean.count + 1
            if room < 0 { break }
            kept.append(clean)
        }
        return String(([start] + kept.reversed()).joined(separator: "\n").prefix(characterLimit))
    }

    /// The home folder as `~`, and no user name in any other path under /Users.
    public static func redact(_ text: String, home: String) -> String {
        var result = text
        if home.count > 1 { result = result.replacingOccurrences(of: home, with: "~") }
        return result.replacingOccurrences(of: #"/Users/(?!Shared\b)[^/\s"']+"#, with: "~", options: .regularExpression)
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func json<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "cannot be encoded" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func lines(_ awake: AwakeList, now: Date) -> [String] {
        func age(_ since: Date) -> String { "for \(max(0, Int(now.timeIntervalSince(since) / 60))) min" }
        func line(_ holder: AwakeList.Holder) -> String {
            let kinds = [holder.keepsMac ? "mac" : nil, holder.keepsScreen ? "screen" : nil]
            return "\(kinds.compactMap { $0 }.joined(separator: "+")) \(holder.name) \(age(holder.since))"
        }
        var lines = awake.clamStop.map { reason in
            switch reason {
            case .session(let since, _): "ClamStop session \(age(since))"
            case .agents(let names, let since): "ClamStop agents \(names.joined(separator: ", ")) \(age(since))"
            case .apps(let names): "ClamStop watched apps \(names.joined(separator: ", "))"
            case .rule: "ClamStop rule"
            }
        }
        if awake.sleepDisabledElsewhere { lines.append("disablesleep on") }
        lines += awake.apps.map(line)
        lines += awake.system.map { "macOS " + line($0) }
        return lines.isEmpty ? ["nothing"] : lines
    }

    private static func line(_ event: SleepEvent) -> String {
        var parts = [format(event.date), event.kind.rawValue]
        if let battery = event.batteryPercent { parts.append("battery=\(battery)") }
        if let adapter = event.onPowerAdapter { parts.append("adapter=\(adapter)") }
        if let detail = event.detail { parts.append("detail=\"\(detail)\"") }
        if let wake = event.wakeReason { parts.append("wake=\(wake)") }
        if let thermal = event.thermal { parts.append("thermal=\(thermal)") }
        return parts.joined(separator: " ")
    }
}

private extension String {
    var orNone: String { isEmpty ? "none" : self }
}
