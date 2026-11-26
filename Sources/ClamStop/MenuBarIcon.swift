import AppKit
import SwiftUI

/// Icon shown in the menu bar, chosen in the settings.
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case laptop
    case seashell

    var id: Self { self }

    var title: String {
        switch self {
        case .laptop: String(localized: "Laptop")
        case .seashell: String(localized: "Seashell")
        }
    }

    /// Template image: AppKit tints it for the menu bar (light, dark, tinted or opaque).
    /// `active` = ClamStop is on and working; otherwise the icon is crossed out.
    func image(active: Bool) -> NSImage {
        let image: NSImage
        switch self {
        case .laptop:
            image = NSImage(systemSymbolName: active ? "laptopcomputer" : "laptopcomputer.slash",
                            accessibilityDescription: nil) ?? NSImage()
        case .seashell:
            image = active ? SeashellGlyph.image : SeashellGlyph.slashedImage
        }
        image.isTemplate = true
        return image
    }
}

/// Label of the `MenuBarExtra`.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    @AppStorage(DefaultsKey.menuBarIconStyle) private var style = MenuBarIconStyle.laptop

    var body: some View {
        Image(nsImage: style.image(active: model.statusIsOK))
            .accessibilityLabel("ClamStop")
            .accessibilityValue(model.statusLine)
    }
}

/// Scallop shell drawn as a vector template image, the same weight as the SF Symbols of the
/// menu bar. Original artwork (no third-party shapes): a fan of five scalloped ribs above a
/// hinge with two small "ears", as seen on a scallop.
enum SeashellGlyph {
    /// Canvas in points; the menu bar centers it vertically.
    static let size = NSSize(width: 19, height: 16)

    static let image = makeImage(slashed: false)
    static let slashedImage = makeImage(slashed: true)

    private static func makeImage(slashed: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            shell().stroke()
            ears().fill()
            if slashed {
                // Same convention as the ".slash" SF Symbols: a diagonal bar with a clear gap.
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3.5, y: 15))
                slash.line(to: NSPoint(x: 16, y: 1))
                slash.lineCapStyle = .round
                slash.lineWidth = 3.6
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                slash.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                slash.lineWidth = 1.4
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ClamStop"
        return image
    }

    private static let hinge = NSPoint(x: 9.5, y: 3.4)
    private static let radius: CGFloat = 9.8
    private static let ribCount = 5
    /// Angles of the fan's two straight sides, in degrees (0 = right).
    private static let firstAngle: CGFloat = 152
    private static let lastAngle: CGFloat = 28

    private static func point(angle: CGFloat, radius: CGFloat) -> NSPoint {
        let a = angle * .pi / 180
        return NSPoint(x: hinge.x + radius * cos(a), y: hinge.y + radius * sin(a))
    }

    /// Outline with a scalloped edge, plus the ribs between the scallops.
    private static func shell() -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 1.3
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        let step = (lastAngle - firstAngle) / CGFloat(ribCount)
        path.move(to: hinge)
        path.line(to: point(angle: firstAngle, radius: radius))
        for i in 0..<ribCount {
            let start = firstAngle + CGFloat(i) * step
            let end = start + step
            let bulge = point(angle: start + step / 2, radius: radius * 1.1)
            path.curve(to: point(angle: end, radius: radius),
                       controlPoint1: bulge, controlPoint2: bulge)
        }
        path.close()
        // Ribs, stopping short of the hinge so they do not merge into a blob.
        for i in 1..<ribCount {
            let angle = firstAngle + CGFloat(i) * step
            path.move(to: point(angle: angle, radius: 4.2))
            path.line(to: point(angle: angle, radius: radius))
        }
        return path
    }

    /// The hinge with its two flat "ears", wider than the tip of the fan.
    private static func ears() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: hinge.x - 4.4, y: hinge.y - 2.8))
        path.line(to: NSPoint(x: hinge.x + 4.4, y: hinge.y - 2.8))
        path.line(to: NSPoint(x: hinge.x + 2.4, y: hinge.y - 0.3))
        path.line(to: NSPoint(x: hinge.x - 2.4, y: hinge.y - 0.3))
        path.close()
        return path
    }
}
