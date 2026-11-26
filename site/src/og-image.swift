// Draws the Open Graph image, site/img/og-<lang>.png (1200 × 630), from the app icon and the
// `og.tagline` string. macOS only; run again after changing the icon or the tagline:
//   swift site/src/og-image.swift        (English)
//   swift site/src/og-image.swift fr
import AppKit

let language = CommandLine.arguments.dropFirst().first ?? "en"
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let site = source.deletingLastPathComponent()

let stringsFile = source.appendingPathComponent("strings/\(language).json")
let strings = try JSONSerialization.jsonObject(with: Data(contentsOf: stringsFile)) as! [String: String]
let tagline = strings["og.tagline"]!

let iconFile = site.deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns")
guard let icon = NSImage(contentsOf: iconFile) else { fatalError("cannot read \(iconFile.path)") }

let size = NSSize(width: 1200, height: 630)
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

NSColor(srgbRed: 0.059, green: 0.071, blue: 0.133, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

icon.draw(in: NSRect(x: 450, y: 285, width: 300, height: 300))

func draw(_ text: String, font: NSFont, color: NSColor, bottom: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
    ]
    // Shrink long translations to fit on one line.
    let width = text.size(withAttributes: attributes).width
    if width > 1100 {
        attributes[.font] = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 1100 / width)
    }
    text.draw(in: NSRect(x: 40, y: bottom, width: 1120, height: font.pointSize * 1.4),
              withAttributes: attributes)
}

draw("ClamStop", font: .systemFont(ofSize: 88, weight: .bold), color: .white, bottom: 160)
draw(tagline, font: .systemFont(ofSize: 44, weight: .regular),
     color: NSColor(srgbRed: 0.72, green: 0.75, blue: 0.87, alpha: 1), bottom: 80)

NSGraphicsContext.restoreGraphicsState()

let output = site.appendingPathComponent("img/og-\(language).png")
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print(output.path)
