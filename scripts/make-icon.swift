// Renders the app icon: a Victron-blue tile carrying a single-line diagram (AC source → converter → battery).
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    // Squircle tile with a vertical blue gradient.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor(srgbRed: 0.106, green: 0.373, blue: 0.667, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.16, green: 0.45, blue: 0.78, alpha: 1).cgColor,
        NSColor(srgbRed: 0.08, green: 0.29, blue: 0.55, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // Faint drafting grid.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor); ctx.setLineWidth(2 * s)
    stride(from: tile.minX, through: tile.maxX, by: 64 * s).forEach { ctx.move(to: CGPoint(x: $0, y: tile.minY)); ctx.addLine(to: CGPoint(x: $0, y: tile.maxY)) }
    stride(from: tile.minY, through: tile.maxY, by: 64 * s).forEach { ctx.move(to: CGPoint(x: tile.minX, y: $0)); ctx.addLine(to: CGPoint(x: tile.maxX, y: $0)) }
    ctx.strokePath()
    ctx.restoreGState()

    let white = NSColor.white.cgColor
    ctx.translateBy(x: 0, y: 70 * s)   // optical centring of the drawing in the tile
    ctx.setStrokeColor(white); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let lw = 30 * s
    ctx.setLineWidth(lw)
    // AC source (circle with sine) on the left.
    let src = CGPoint(x: 270 * s, y: 600 * s), r = 82 * s
    ctx.strokeEllipse(in: CGRect(x: src.x - r, y: src.y - r, width: 2 * r, height: 2 * r))
    ctx.move(to: CGPoint(x: src.x - 44 * s, y: src.y))
    ctx.addCurve(to: CGPoint(x: src.x + 44 * s, y: src.y), control1: CGPoint(x: src.x - 14 * s, y: src.y + 66 * s), control2: CGPoint(x: src.x + 14 * s, y: src.y - 66 * s))
    ctx.strokePath()
    // Conductor to the converter, with brown→ amber energy dashes.
    ctx.move(to: CGPoint(x: src.x + r, y: src.y)); ctx.addLine(to: CGPoint(x: 560 * s, y: src.y)); ctx.strokePath()
    // Converter box (~ / =) on the right.
    let box = CGRect(x: 560 * s, y: 470 * s, width: 260 * s, height: 260 * s)
    ctx.stroke(box.insetBy(dx: lw / 2, dy: lw / 2))
    ctx.move(to: CGPoint(x: box.minX + 20 * s, y: box.minY + 20 * s)); ctx.addLine(to: CGPoint(x: box.maxX - 20 * s, y: box.maxY - 20 * s)); ctx.strokePath()
    ctx.setLineWidth(22 * s)
    let t = CGPoint(x: box.minX + 70 * s, y: box.maxY - 72 * s)
    ctx.move(to: CGPoint(x: t.x - 34 * s, y: t.y)); ctx.addCurve(to: CGPoint(x: t.x + 34 * s, y: t.y), control1: CGPoint(x: t.x - 10 * s, y: t.y + 40 * s), control2: CGPoint(x: t.x + 10 * s, y: t.y - 40 * s)); ctx.strokePath()
    let e = CGPoint(x: box.maxX - 72 * s, y: box.minY + 70 * s)
    for dy: CGFloat in [-14, 14] { ctx.move(to: CGPoint(x: e.x - 34 * s, y: e.y + dy * s)); ctx.addLine(to: CGPoint(x: e.x + 34 * s, y: e.y + dy * s)) }
    ctx.strokePath()
    // Battery (IEC: long plate +, short plate −), leads from the converter to its outer plates.
    ctx.setLineWidth(lw)
    let bx = box.midX
    let plates: [(x: CGFloat, long: Bool)] = [(-96, true), (-58, false), (-19, true), (19, false), (58, true), (96, false)]
    for p in plates {
        let x = bx + p.x * s
        ctx.move(to: CGPoint(x: x, y: (p.long ? 330 : 300) * s)); ctx.addLine(to: CGPoint(x: x, y: (p.long ? 190 : 220) * s))
    }
    ctx.strokePath()
    ctx.setStrokeColor(NSColor(srgbRed: 0.95, green: 0.35, blue: 0.37, alpha: 1).cgColor)
    ctx.move(to: CGPoint(x: bx - 96 * s, y: box.minY)); ctx.addLine(to: CGPoint(x: bx - 96 * s, y: 330 * s)); ctx.strokePath()
    ctx.setStrokeColor(white)
    ctx.move(to: CGPoint(x: bx + 96 * s, y: box.minY)); ctx.addLine(to: CGPoint(x: bx + 96 * s, y: 300 * s)); ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset directory>\n".data(using: .utf8)!)
    exit(64)
}
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
