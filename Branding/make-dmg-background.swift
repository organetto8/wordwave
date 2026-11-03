// Renders the DMG window background (600×400 pt) as a Retina-ready TIFF.
// Usage: swift Branding/make-dmg-background.swift   (writes Branding/dmg-background.tiff)
//
// Mid-tone brand colours keep Finder's icon labels readable in both light (black text) and dark (white text) mode.
// Icons sit at (160, 200) and (440, 200), top-left origin: keep scripts/release.sh in sync.
import AppKit

let size = NSSize(width: 600, height: 400)
let brandDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws `text` centred horizontally, with its vertical centre `top` points from the top edge.
func drawCentered(_ text: String, top: CGFloat, font: NSFont, alpha: CGFloat) {
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
    let textSize = string.size()
    string.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: size.height - top - textSize.height / 2))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let bounds = NSRect(origin: .zero, size: size)
    NSGradient(colors: [color(0x0EA5A4), color(0x2F6FE8), color(0x5B4BD8)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: bounds, angle: -20)
    NSGradient(colors: [color(0xFFFFFF, alpha: 0), color(0xFFFFFF, alpha: 0.14)])!
        .draw(in: bounds, angle: 90)

    drawCentered("Wordwave", top: 58, font: .systemFont(ofSize: 26, weight: .bold), alpha: 1)
    drawCentered("Drag to Applications to install", top: 92, font: .systemFont(ofSize: 14, weight: .medium), alpha: 0.85)
    drawCentered("Voice notes, as words.", top: 358, font: .systemFont(ofSize: 12, weight: .regular), alpha: 0.6)

    // Arrow from the app icon (x 160) to the Applications icon (x 440), at icon height (y 200 from top).
    let y = size.height - 200
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 246, y: y))
    arrow.line(to: NSPoint(x: 350, y: y))
    arrow.move(to: NSPoint(x: 330, y: y + 18))
    arrow.line(to: NSPoint(x: 354, y: y))
    arrow.line(to: NSPoint(x: 330, y: y - 18))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.85).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Two representations in one TIFF: Finder picks the 2x one on Retina displays.
let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [render(scale: 1), render(scale: 2)], using: .lzw, factor: 0)!
try tiff.write(to: brandDirectory.appending(path: "dmg-background.tiff"))
print("wrote", brandDirectory.appending(path: "dmg-background.tiff").path)
