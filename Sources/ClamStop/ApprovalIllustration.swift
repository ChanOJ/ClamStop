import AppKit
import SwiftUI

/// Drawing of the row to turn on in System Settings > General > Login Items & Extensions >
/// Background App Activity. Drawn rather than a screenshot so that it follows the light or dark
/// appearance, the app icon and, later, the app's language. `README.md` uses PNG exports of it
/// (`ClamStop --export-illustration <png> [--appearance light|dark]`).
struct ApprovalIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background App Activity")
                .font(.headline)
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    // Without ".app": Finder hides extensions by default, and so does System Settings then.
                    Text(verbatim: "ClamStop")
                    Text("Not running in background")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                SwitchDrawing()
                    .padding(4)
                    .overlay(Capsule().stroke(Color.orange, lineWidth: 2.5))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The ClamStop switch to turn on in System Settings")
    }
}

/// A switch in the off position, drawn with shapes: the real control is AppKit-backed and
/// would not render in `ImageRenderer`.
private struct SwitchDrawing: View {
    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 38, height: 22)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: 20, height: 20)
                    .padding(.leading, 1)
            }
    }
}

extension ApprovalIllustration {
    /// Writes the illustration as a 2x PNG, in the application's current appearance.
    @MainActor
    static func export(to url: URL) throws {
        let appearance = NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let renderer = ImageRenderer(content: ApprovalIllustration()
            .frame(width: 420)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            png = renderer.cgImage.flatMap {
                NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
            }
        }
        guard let png else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
