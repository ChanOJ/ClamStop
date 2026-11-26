// Draws the placeholder app icon and writes Resources/AppIcon.icns.
// Usage (from the repository root): swift scripts/make-icon.swift
// Replace Resources/AppIcon.icns to ship a real icon; the build only copies that file.

import AppKit

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory
    .appendingPathComponent("ClamStop-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

/// Rounded square with a closed laptop seen from the front, on a 1024 pt canvas.
func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let background = NSBezierPath(
        roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(
        starting: NSColor(red: 0.10, green: 0.13, blue: 0.30, alpha: 1),
        ending: NSColor(red: 0.27, green: 0.38, blue: 0.72, alpha: 1))!
        .draw(in: background, angle: 90)

    NSColor.white.setFill()
    // Lid and base of the closed laptop.
    NSBezierPath(roundedRect: NSRect(x: 232, y: 424, width: 560, height: 72), xRadius: 30, yRadius: 30).fill()
    NSBezierPath(roundedRect: NSRect(x: 200, y: 344, width: 624, height: 56), xRadius: 28, yRadius: 28).fill()
    // Pause sign: the Mac is stopped.
    for x in [440.0, 540.0] {
        NSBezierPath(roundedRect: NSRect(x: x, y: 560, width: 44, height: 160), xRadius: 22, yRadius: 22).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 2 ? "@2x" : ""
        try draw(pixels: size * factor)
            .write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns")
