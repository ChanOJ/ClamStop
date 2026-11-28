import AppKit
import SwiftUI
import os
import ClamStopShared

private let badgeLogger = Logger(subsystem: ClamStopID.appBundleID, category: "badge")

/// What the menu bar icon shows (spec H1).
enum MenuBarIconState: Equatable {
    /// ClamStop works: the lid puts the Mac to sleep.
    case active
    /// The Mac stays awake, with a badge saying why (highest priority first): a Stay Awake
    /// session, AI agents work, another app works (video export, encoding; spec C5).
    case awake(AwakeReason)
    /// ClamStop is off, inactive or not working: the icon is crossed out.
    case inactive
}

/// Why the Mac stays awake, in order of priority for the menu bar badge.
enum AwakeReason: CaseIterable {
    case session
    case agents
    case app

    var badgeSymbol: String {
        switch self {
        case .agents: "sparkles"
        case .session: "cup.and.saucer.fill"
        case .app: "hourglass"
        }
    }

    /// The thin sparkles and the narrow hourglass look smaller than the cup at the same size (the
    /// hourglass was hard to make out at 7 points, reported 2026-11-28).
    var badgePointSize: CGFloat {
        self == .session ? 7 : 9.5
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
    /// `badgeOpacity`: below 1 while `BadgeAnimator` pulses the badge on top of it.
    @MainActor func image(_ state: MenuBarIconState, badgeOpacity: CGFloat = 1) -> NSImage {
        switch state {
        case .active: return image(active: true)
        case .inactive: return image(active: false)
        case .awake(let reason):
            let key = "\(rawValue)-\(reason)-\(badgeOpacity)"
            if let cached = Self.badgeCache[key] { return cached }
            let image = Self.withBadge(reason.badgeSymbol, pointSize: reason.badgePointSize, opacity: badgeOpacity,
                                       on: image(active: true))
            Self.badgeCache[key] = image
            return image
        }
    }

    @MainActor private static var badgeCache: [String: NSImage] = [:]

    /// The badge symbol, and where `withBadge` puts it in the icon (non-flipped coordinates).
    func badgeLayout(_ reason: AwakeReason) -> (symbol: NSImage, iconSize: NSSize, badge: NSRect)? {
        let config = NSImage.SymbolConfiguration(pointSize: reason.badgePointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: reason.badgeSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let base = image(active: true)
        let size = NSSize(width: base.size.width + (symbol.size.width * 0.55).rounded(), height: base.size.height)
        return (symbol, size, NSRect(x: size.width - symbol.size.width, y: 0,
                                     width: symbol.size.width, height: symbol.size.height))
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

    /// The icon with a small symbol in its lower right corner, with a thin gap around its strokes
    /// so both stay readable at menu bar size.
    static func withBadge(_ symbol: String, pointSize: CGFloat, opacity: CGFloat = 1,
                          on base: NSImage) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let cup = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return base }
        let size = NSSize(width: base.size.width + (cup.size.width * 0.55).rounded(), height: base.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size))
            let badge = NSRect(x: size.width - cup.size.width, y: 0, width: cup.size.width, height: cup.size.height)
            // Cut a margin that follows the symbol's strokes (the symbol drawn around a small
            // circle), so the icon stays visible between them.
            let margin: CGFloat = 1.2
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                cup.draw(in: badge.offsetBy(dx: cos(angle) * margin, dy: sin(angle) * margin),
                         from: .zero, operation: .destinationOut, fraction: opacity)
            }
            cup.draw(in: badge, from: .zero, operation: .sourceOver, fraction: opacity)
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
    @AppStorage(DefaultsKey.animateBadge) private var animateBadge = false

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: style.image(model.iconState,
                                       badgeOpacity: animateBadge && BadgeAnimator.enabled ? BadgeAnimator.dimmedOpacity : 1))
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

/// Slow pulse of the menu bar badge while the Mac stays awake, done by Core Animation on a
/// layer added to the status item button, so the window server animates it and the app does
/// nothing per frame. Swapping the icon image instead cost about 4.5 % of a core (measured
/// 2026-11-27): each swap makes macOS redraw the status item for every menu bar. Same approach
/// as RunCat Neo (runcat-dev/RunCatNeo, `RunnerLayer`). The layer only shows on the menu bar of
/// the active display; the icon image keeps a dimmed badge for the others.
@MainActor
final class BadgeAnimator {
    /// Opacity of the badge in the icon image while the layer pulses on top of it.
    static let dimmedOpacity: CGFloat = 0.35
    /// One step every 0.25 s: lights up quickly (0.5 s), fades slowly (1.25 s).
    static let opacitySteps: [Double] = [0, 0.5, 1, 0.8, 0.6, 0.4, 0.2]
    static let period: CFTimeInterval = 0.25 * Double(opacitySteps.count)

    private let colorLayer = CALayer()
    private let maskLayer = CALayer()
    private weak var button: NSStatusBarButton?
    private var appearanceObservation: NSKeyValueObservation?
    private var shown: (MenuBarIconStyle, AwakeReason)?

    /// Whether the badge pulses (and the icon image should carry a dimmed badge).
    /// Off by default (setting in General), and never with "Reduce motion".
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.animateBadge)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init() {
        colorLayer.mask = maskLayer
        maskLayer.contentsGravity = .resizeAspect
    }

    func update(_ state: MenuBarIconState, style: MenuBarIconStyle) {
        guard case .awake(let reason) = state, Self.enabled,
              let button = NSApp.statusItemButton, let layout = style.badgeLayout(reason) else {
            if case .awake = state {
                let windows = NSApp.windows.map { String(describing: type(of: $0)) }.joined(separator: ",")
                badgeLogger.info("badge: no status item button (windows: \(windows, privacy: .public))")
            }
            hide()
            return
        }
        // Where the button draws the icon: not centered when the time left is shown as a title.
        let bounds = button.bounds
        let imageRect = button.cell?.imageRect(forBounds: bounds)
            ?? NSRect(x: (bounds.width - layout.iconSize.width) / 2, y: (bounds.height - layout.iconSize.height) / 2,
                      width: layout.iconSize.width, height: layout.iconSize.height)
        var frame = layout.badge.offsetBy(dx: imageRect.minX, dy: imageRect.minY)
        if button.isFlipped { frame.origin.y = imageRect.minY + layout.iconSize.height - layout.badge.maxY }
        if let shown, shown == (style, reason), self.button === button, colorLayer.superlayer != nil {
            if colorLayer.frame != frame {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                colorLayer.frame = frame
                CATransaction.commit()
            }
            return
        }
        self.button = button
        button.wantsLayer = true
        guard let host = button.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorLayer.frame = frame
        maskLayer.frame = CGRect(origin: .zero, size: frame.size)
        let scale = button.window?.backingScaleFactor ?? 2
        var rect = CGRect(origin: .zero, size: layout.symbol.size)
        maskLayer.contents = layout.symbol.cgImage(forProposedRect: &rect, context: nil,
                                                   hints: [.ctm: AffineTransform(scale: scale)])
        maskLayer.contentsScale = scale
        colorLayer.contentsScale = scale
        updateColor()
        if colorLayer.superlayer !== host { host.addSublayer(colorLayer) }
        if colorLayer.animation(forKey: "pulse") == nil {
            // Discrete steps, not a smooth animation: a continuous one made the window server
            // recomposite the menu bar at the display refresh rate (+25 % of a core, measured
            // 2026-11-27); 4 steps per second look like a fade.
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = Self.opacitySteps
            pulse.calculationMode = .discrete
            pulse.duration = Self.period
            pulse.repeatCount = .infinity
            pulse.isRemovedOnCompletion = false
            colorLayer.add(pulse, forKey: "pulse")
        }
        CATransaction.commit()
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateColor() }
        }
        shown = (style, reason)
        badgeLogger.info("badge layer \(NSStringFromRect(frame), privacy: .public) in \(NSStringFromRect(bounds), privacy: .public), flipped \(button.isFlipped)")
    }

    private func hide() {
        guard colorLayer.superlayer != nil else { return }
        colorLayer.removeAllAnimations()
        colorLayer.removeFromSuperlayer()
        appearanceObservation = nil
        shown = nil
    }

    /// The color macOS gives template images in this menu bar (light, dark, tinted).
    private func updateColor() {
        guard let button else { return }
        var color = NSColor.labelColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorLayer.backgroundColor = color
        CATransaction.commit()
    }
}

extension NSApplication {
    /// The button of the `MenuBarExtra`'s status item (SwiftUI does not expose it).
    var statusItemButton: NSStatusBarButton? {
        for window in windows where String(describing: type(of: window)).contains("NSStatusBarWindow") {
            if let button = window.contentView?.firstSubview(of: NSStatusBarButton.self) { return button }
        }
        return nil
    }
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for view in subviews {
            if let match = view.firstSubview(of: type) { return match }
        }
        return nil
    }
}
