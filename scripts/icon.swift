// Draws the DevClean app icon (a gauge reading low, with a sparkle) as a 1024×1024 PNG.
// Run through scripts/make-icon.sh, which turns it into Support/AppIcon.icns.
// Drawn with plain paths: SF Symbols may not be used in app icons.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"
let size = 1024.0
let white = NSColor.white

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Rounded-square body on Apple's macOS icon grid: 824 pt inside a 1024 canvas, a little above center.
let body = NSRect(x: 100, y: 110, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.86, blue: 0.68, alpha: 1),
                    NSColor(srgbRed: 0.10, green: 0.53, blue: 0.86, alpha: 1),
                    NSColor(srgbRed: 0.17, green: 0.25, blue: 0.70, alpha: 1)])!
    .draw(in: shape, angle: -60)

// Soft highlight on the top half.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(starting: white.withAlphaComponent(0.18), ending: white.withAlphaComponent(0))!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Gauge: a 240° arc open at the bottom, filled only a little (plenty of room left).
let center = NSPoint(x: 512, y: 480)
let radius = 255.0
func arc(from start: Double, to end: Double, color: NSColor) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    path.lineWidth = 72
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}
arc(from: 210, to: -30, color: white.withAlphaComponent(0.28))
arc(from: 210, to: 135, color: white)

// Needle pointing at the low end, with a hub.
let angle = 140.0 * .pi / 180
let needle = NSBezierPath()
needle.move(to: center)
needle.line(to: NSPoint(x: center.x + cos(angle) * 185, y: center.y + sin(angle) * 185))
needle.lineWidth = 40
needle.lineCapStyle = .round
white.setStroke()
needle.stroke()
white.setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - 52, y: center.y - 52, width: 104, height: 104)).fill()

// Four-point sparkle, top right, plus a small one.
func sparkle(at point: NSPoint, radius r: Double) {
    let path = NSBezierPath()
    let waist = r * 0.22
    for i in 0..<8 {
        let a = Double(i) * .pi / 4 + .pi / 2
        let d = i.isMultiple(of: 2) ? r : waist
        let p = NSPoint(x: point.x + cos(a) * d, y: point.y + sin(a) * d)
        i == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.close()
    path.fill()
}
sparkle(at: NSPoint(x: 752, y: 768), radius: 92)
sparkle(at: NSPoint(x: 838, y: 660), radius: 44)

NSGraphicsContext.current = nil
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
