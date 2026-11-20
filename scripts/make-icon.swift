// Draws the app icon and writes Resources/AppIcon.icns (plus a 1024 px preview PNG).
// Usage: swift scripts/make-icon.swift [output-dir] [--preview]   (default: Resources)
// Design: a dark rounded tile with a terminal prompt (">_") and three process rows whose status
// dots read running / running / warning — "commands, managed".
import AppKit
import Foundation

let args = CommandLine.arguments.dropFirst()
let wantsPreview = args.contains("--preview")
let outDir = URL(fileURLWithPath: args.first { !$0.hasPrefix("--") } ?? "Resources", isDirectory: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon in a 1024 × 1024 coordinate space (origin bottom-left).
func draw(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // macOS icon grid: 824 pt tile centred in 1024, continuous corners.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x141B2E))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x2B3A67), color(0x121A30)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Glow behind the prompt.
    let glow = CGGradient(colorsSpace: space, colors: [color(0x5CF2C2, 0.22), color(0x5CF2C2, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 690), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 690), endRadius: 360, options: [])
    // Top sheen.
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()

    // Hairline border.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // Prompt ">" and cursor "_".
    let mint = color(0x5CF2C2)
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(58)
    ctx.setStrokeColor(mint)
    ctx.move(to: CGPoint(x: 228, y: 790))
    ctx.addLine(to: CGPoint(x: 360, y: 690))
    ctx.addLine(to: CGPoint(x: 228, y: 590))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 430, y: 592))
    ctx.addLine(to: CGPoint(x: 590, y: 592))
    ctx.strokePath()
    ctx.restoreGState()

    // Three process rows: status dot + bar.
    let rows: [(dot: UInt32, length: CGFloat, y: CGFloat)] = [
        (0x34D399, 470, 440), (0x34D399, 380, 330), (0xFBBF24, 430, 220),
    ]
    for row in rows {
        let dot = CGRect(x: 214, y: row.y - 30, width: 60, height: 60)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 18, color: color(row.dot, 0.55))
        ctx.setFillColor(color(row.dot))
        ctx.fillEllipse(in: dot)
        ctx.restoreGState()
        let bar = CGRect(x: 314, y: row.y - 22, width: row.length, height: 44)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.setFillColor(color(0xFFFFFF, 0.78))
        ctx.fillPath()
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
if wantsPreview { try png(size: 1024).write(to: outDir.appendingPathComponent("AppIcon-preview.png")) }

let icns = outDir.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(icns.path)")
