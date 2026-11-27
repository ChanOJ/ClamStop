import AppKit
import SwiftUI

/// What the menu bar icon shows (spec H1).
enum MenuBarIconState: Equatable {
    /// ClamStop works: the lid puts the Mac to sleep.
    case active
    /// The Mac stays awake, with a badge saying why (highest priority first): AI agents work,
    /// a Stay Awake session, another app works (video export, encoding; spec C5).
    case awake(AwakeReason)
    /// ClamStop is off, inactive or not working: the icon is crossed out.
    case inactive
}

/// Why the Mac stays awake, in order of priority for the menu bar badge.
enum AwakeReason: CaseIterable {
    case agents
    case session
    case app

    var badgeSymbol: String {
        switch self {
        case .agents: "sparkles"
        case .session: "cup.and.saucer.fill"
        case .app: "hourglass"
        }
    }

    /// The sparkles are thin and look smaller than the filled symbols at the same size.
    var badgePointSize: CGFloat {
        self == .agents ? 9.5 : 7
    }
}

/// Icon shown in the menu bar, chosen in the settings.
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case laptop
    case clam

    var id: Self { self }

    var title: String {
        switch self {
        case .laptop: String(localized: "Laptop")
        case .clam: String(localized: "Clam")
        }
    }

    /// Template image: AppKit tints it for the menu bar (light, dark, tinted or opaque).
    func image(_ state: MenuBarIconState) -> NSImage {
        switch state {
        case .active: image(active: true)
        case .inactive: image(active: false)
        case .awake(let reason): Self.withBadge(reason.badgeSymbol, pointSize: reason.badgePointSize,
                                                on: image(active: true))
        }
    }

    /// `active` = ClamStop is on and working; otherwise the icon is crossed out.
    func image(active: Bool) -> NSImage {
        let image: NSImage
        switch self {
        case .laptop:
            image = NSImage(systemSymbolName: active ? "laptopcomputer" : "laptopcomputer.slash",
                            accessibilityDescription: nil) ?? NSImage()
        case .clam:
            image = active ? ClamGlyph.image : ClamGlyph.slashedImage
        }
        image.isTemplate = true
        return image
    }

    /// The icon with a small symbol in its lower right corner, cut out of the icon so it stays
    /// readable at menu bar size.
    static func withBadge(_ symbol: String, pointSize: CGFloat, on base: NSImage) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let cup = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return base }
        let size = NSSize(width: base.size.width + (cup.size.width * 0.55).rounded(), height: base.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size))
            let badge = NSRect(x: size.width - cup.size.width, y: 0, width: cup.size.width, height: cup.size.height)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(roundedRect: badge.insetBy(dx: -1.5, dy: -1.5), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            cup.draw(in: badge)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Label of the `MenuBarExtra`.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    @AppStorage(DefaultsKey.menuBarIconStyle) private var style = MenuBarIconStyle.laptop
    @AppStorage(DefaultsKey.showTimeLeft) private var showTimeLeft = false

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: style.image(model.iconState))
            if showTimeLeft, let left = model.sessionTimeLeft {
                Text(left)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ClamStop")
        .accessibilityValue(model.sessionLine ?? model.statusLine)
    }
}

/// Closed clam in isometric view, drawn as a vector template image in the line style of the
/// menu bar's SF Symbols. Original artwork: the domed top valve, the wavy seam where the two
/// valves meet, the thin lower valve, and folds running from the hinge to the seam.
enum ClamGlyph {
    /// Canvas in points; the menu bar centers it vertically.
    static let size = NSSize(width: 20, height: 16)

    static let image = makeImage(slashed: false)
    static let slashedImage = makeImage(slashed: true)

    private static let lineWidth: CGFloat = 1.2

    private static func makeImage(slashed: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let path = shape()
            path.lineWidth = lineWidth
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
            if slashed {
                // Same convention as the ".slash" SF Symbols: a diagonal bar with a clear gap.
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 4, y: 15.2))
                slash.line(to: NSPoint(x: 16.5, y: 0.8))
                slash.lineCapStyle = .round
                slash.lineWidth = lineWidth + 2.2
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                slash.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                slash.lineWidth = lineWidth
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ClamStop"
        return image
    }

    /// Shape in points: the valves meet at both ends; the hinge is at the back, on top.
    private static let left = NSPoint(x: 1, y: 7.4)
    private static let right = NSPoint(x: 19, y: 8.4)
    private static let hinge = NSPoint(x: 11.4, y: 13.6)
    private static let scallops = 4

    private static func cubic(_ t: CGFloat, _ p0: NSPoint, _ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint) -> NSPoint {
        let m = 1 - t
        let a = m * m * m, b = 3 * m * m * t, c = 3 * m * t * t, d = t * t * t
        return NSPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    private static func shape() -> NSBezierPath {
        let path = NSBezierPath()
        // Top valve, seen from above: a dome from one end, over the hinge, to the other.
        path.move(to: left)
        path.curve(to: hinge, controlPoint1: NSPoint(x: 2.2, y: 11.6), controlPoint2: NSPoint(x: 6.8, y: 13.9))
        path.curve(to: right, controlPoint1: NSPoint(x: 15.6, y: 13.3), controlPoint2: NSPoint(x: 18.4, y: 11.2))
        // Lower valve: a thin band under the seam.
        path.move(to: left)
        path.curve(to: right, controlPoint1: NSPoint(x: 4, y: -0.6), controlPoint2: NSPoint(x: 15.5, y: -0.4))
        // Seam: the front of the margin, sagging toward the viewer, as scallops.
        let c1 = NSPoint(x: 5, y: 3.6), c2 = NSPoint(x: 14.5, y: 3.9)
        let joints = (0...scallops).map { cubic(CGFloat($0) / CGFloat(scallops), left, c1, c2, right) }
        path.move(to: left)
        for (start, end) in zip(joints, joints.dropFirst()) {
            let bulge = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 1.5)
            path.curve(to: end, controlPoint1: bulge, controlPoint2: bulge)
        }
        // Folds fanning out from the hinge to the joints between the scallops.
        for joint in joints.dropFirst().dropLast() {
            let start = NSPoint(x: hinge.x + (joint.x - hinge.x) * 0.28, y: hinge.y + (joint.y - hinge.y) * 0.28)
            let control = NSPoint(x: (start.x + joint.x) / 2 + (joint.x - hinge.x) * 0.15,
                                  y: (start.y + joint.y) / 2 + 0.8)
            path.move(to: start)
            path.curve(to: joint, controlPoint1: control, controlPoint2: control)
        }
        return path
    }
}
