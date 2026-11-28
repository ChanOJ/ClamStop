// "Report a Problem" (spec H4): a GitHub issue or an e-mail, filled in and left for the user to
// complete and send. No server and no secret in the app.

import Foundation

public struct ProblemReport: Sendable {
    public var appVersion: String
    public var macOSVersion: String
    public var model: String
    public var checks: [HealthCheck]

    public init(appVersion: String, macOSVersion: String, model: String, checks: [HealthCheck]) {
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.model = model
        self.checks = checks
    }

    public var subject: String { "ClamStop \(appVersion): problem report" }

    private var summary: [String] {
        let failed = checks.filter(\.failed).map { "\($0.kind.rawValue) (\($0.level.rawValue))" }
        return ["ClamStop \(appVersion), macOS \(macOSVersion), \(model)",
                "Failed checks: \(failed.isEmpty ? "none" : failed.joined(separator: ", "))"]
    }

    /// A new issue in `repository`, with the description to write and where to paste the
    /// diagnostics (too long for an address). The instructions are a comment: shown while writing,
    /// not in the published issue. No label: setting one needs rights on the repository.
    public func gitHubIssue(repository: URL) -> URL? {
        let body = (["### What happened?", "", "", "### What did you expect?", "", "", "### Environment"]
            + summary
            + ["", "### Diagnostics",
               "<!-- Paste them below this line (⌘V). Read them first: this issue is public. -->", "", ""])
            .joined(separator: "\n")
        return Self.url(repository.appendingPathComponent("issues/new"), query: [("body", body)])
    }

    /// Diagnostics as a folded block of a GitHub issue.
    public static func gitHubBlock(_ diagnostics: String) -> String {
        "<details><summary>Diagnostics</summary>\n\n~~~~text\n\(diagnostics)\n~~~~\n\n</details>\n"
    }

    /// Diagnostics kept in the body of a `mailto:` link: mail apps get it as one long address.
    public static let mailBodyLimit = 30_000

    /// `diagnostics` nil when they are attached.
    public func mailBody(diagnostics: String?) -> String {
        (["What happened?", "", "", "What did you expect?", "", ""]
            + summary
            + ["", diagnostics.map { "--- Diagnostics ---\n\($0)" } ?? "The diagnostics are attached.", ""])
            .joined(separator: "\n")
    }

    /// For mail apps that cannot take an attachment from another app: the diagnostics are in the
    /// body.
    public func mailtoURL(address: String, diagnostics: String) -> URL? {
        guard let base = URL(string: "mailto:\(address)") else { return nil }
        // Line breaks in a `mailto:` body are CR LF (RFC 6068).
        let body = mailBody(diagnostics: diagnostics).replacingOccurrences(of: "\n", with: "\r\n")
        return Self.url(base, query: [("subject", subject), ("body", body)])
    }

    /// Everything but unreserved characters percent-encoded: `+` and `&` would change meaning.
    private static func url(_ base: URL, query: [(String, String)]) -> URL? {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var pairs: [String] = []
        for (name, value) in query {
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
            pairs.append("\(name)=\(encoded)")
        }
        return URL(string: base.absoluteString + "?" + pairs.joined(separator: "&"))
    }
}
