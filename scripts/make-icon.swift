// Renders the Pocketbay app icon (a phone tucked into a pocket) to a 1024px PNG.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: CGSize(width: size, height: size), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    let inset: CGFloat = 100
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    // soft drop shadow under the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.35).cgColor)
    NSColor.black.setFill()
    tilePath.fill()
    ctx.restoreGState()

    // background gradient: teal → deep indigo
    tilePath.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.78, blue: 0.66, alpha: 1),
                        NSColor(srgbRed: 0.16, green: 0.30, blue: 0.72, alpha: 1)])!
        .draw(in: tile, angle: -60)

    // phone, tilted, peeking out of the pocket
    ctx.saveGState()
    ctx.translateBy(x: size / 2 + 20, y: size / 2 + 40)
    ctx.rotate(by: -0.18)
    let phone = CGRect(x: -125, y: -170, width: 250, height: 430)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor(white: 0, alpha: 0.3).cgColor)
    NSColor(white: 0.98, alpha: 1).setFill()
    NSBezierPath(roundedRect: phone, xRadius: 44, yRadius: 44).fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    let screen = phone.insetBy(dx: 18, dy: 18)
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.85, blue: 0.55, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.62, blue: 0.80, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: screen, xRadius: 30, yRadius: 30), angle: -90)
    // a play triangle on the screen
    let tri = NSBezierPath()
    tri.move(to: CGPoint(x: -34, y: 150)); tri.line(to: CGPoint(x: -34, y: 240)); tri.line(to: CGPoint(x: 44, y: 195)); tri.close()
    NSColor(white: 1, alpha: 0.95).setFill()
    tri.fill()
    ctx.restoreGState()

    // the pocket (front), with stitching
    let pocket = NSBezierPath()
    let top: CGFloat = 470, bottom: CGFloat = 200, left: CGFloat = 250, right: CGFloat = size - 250
    pocket.move(to: CGPoint(x: left, y: top))
    pocket.line(to: CGPoint(x: right, y: top))
    pocket.line(to: CGPoint(x: right, y: bottom + 80))
    pocket.curve(to: CGPoint(x: size / 2, y: bottom - 10), controlPoint1: CGPoint(x: right, y: bottom + 20), controlPoint2: CGPoint(x: size / 2 + 150, y: bottom - 10))
    pocket.curve(to: CGPoint(x: left, y: bottom + 80), controlPoint1: CGPoint(x: size / 2 - 150, y: bottom - 10), controlPoint2: CGPoint(x: left, y: bottom + 20))
    pocket.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: NSColor(white: 0, alpha: 0.35).cgColor)
    NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.20, blue: 0.45, alpha: 1),
                        NSColor(srgbRed: 0.09, green: 0.13, blue: 0.32, alpha: 1)])!
        .draw(in: pocket, angle: -90)
    ctx.restoreGState()

    let stitch = NSBezierPath()
    stitch.move(to: CGPoint(x: left + 30, y: top - 32))
    stitch.line(to: CGPoint(x: right - 30, y: top - 32))
    stitch.lineWidth = 9
    stitch.setLineDash([26, 18], count: 2, phase: 0)
    stitch.lineCapStyle = .round
    NSColor(srgbRed: 0.55, green: 0.95, blue: 0.85, alpha: 0.9).setStroke()
    stitch.stroke()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
