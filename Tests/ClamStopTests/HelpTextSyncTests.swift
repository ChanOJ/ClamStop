import Foundation
import Testing

/// The ⓘ help popover (LidHelpView) and the opening of README.md must say the same thing.
@Test func helpPopoverMatchesReadme() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let view = try String(contentsOf: root.appendingPathComponent("Sources/ClamStop/SettingsView.swift"), encoding: .utf8)
    let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)

    guard let start = view.range(of: "struct LidHelpView"),
          let end = view.range(of: "\n}\n", range: start.upperBound..<view.endIndex) else {
        Issue.record("LidHelpView not found")
        return
    }
    let body = view[start.upperBound..<end.lowerBound]
    let regex = try NSRegularExpression(pattern: #"Text\("([^"]+)"\)\s*\n"#)
    let ns = String(body) as NSString
    let paragraphs = regex.matches(in: String(body), range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)) }
        .filter { $0 != "Why ClamStop?" }
    #expect(paragraphs.count == 3)

    let flatReadme = readme.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    for paragraph in paragraphs {
        #expect(flatReadme.contains(paragraph), "README.md does not contain: \(paragraph)")
    }
}
