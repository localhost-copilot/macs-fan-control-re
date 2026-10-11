import AppKit

// Renders the app icon: a cool-toned plate with a seven-blade fan in a recessed
// shroud. Sizes follow the macOS icon grid (artwork inset ~10% with a soft shadow).
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func draw(_ s: CGFloat) {
    let plate = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: s * 0.18, yRadius: s * 0.18)

    // Drop shadow beneath the plate.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    color(0x0E2A47).setFill(); platePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x2F8CFF), color(0x1557C0), color(0x0B2E66)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: platePath, angle: -90)
    // Top sheen.
    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()
    NSGradient(starting: .white.withAlphaComponent(0.22), ending: .white.withAlphaComponent(0))!
        .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.18).setStroke(); platePath.lineWidth = max(1, s * 0.004)
    NSBezierPath(roundedRect: plate.insetBy(dx: s * 0.002, dy: s * 0.002), xRadius: s * 0.178, yRadius: s * 0.178).stroke()

    let center = NSPoint(x: s / 2, y: s / 2)
    let radius = s * 0.29

    // Recessed shroud.
    let shroud = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    NSGradient(starting: color(0x06182F, 0.55), ending: color(0x0A3772, 0.35))!.draw(in: shroud, angle: -90)
    color(0xFFFFFF, 0.28).setStroke(); shroud.lineWidth = max(1, s * 0.008); shroud.stroke()

    // Blades: swept teardrops, lit from the top.
    NSGraphicsContext.saveGraphicsState()
    let bladeShadow = NSShadow()
    bladeShadow.shadowColor = .black.withAlphaComponent(0.3)
    bladeShadow.shadowBlurRadius = s * 0.012; bladeShadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
    bladeShadow.set()
    let r = radius * 0.9
    // Sickle blades: each sweeps forward from the hub to a wide tip near the shroud.
    func polar(_ radius: CGFloat, _ degrees: CGFloat, _ base: CGFloat) -> NSPoint {
        let angle = (degrees + base) * .pi / 180
        return NSPoint(x: center.x + cos(angle) * r * radius, y: center.y + sin(angle) * r * radius)
    }
    for index in 0..<7 {
        let base = CGFloat(index) * 360 / 7 + 90
        let blade = NSBezierPath()
        blade.move(to: polar(0.24, -12, base))
        blade.curve(to: polar(0.98, 28, base), controlPoint1: polar(0.62, -14, base), controlPoint2: polar(0.9, 8, base))
        blade.curve(to: polar(0.96, 62, base), controlPoint1: polar(1.04, 40, base), controlPoint2: polar(1.03, 54, base))
        blade.curve(to: polar(0.24, 22, base), controlPoint1: polar(0.72, 52, base), controlPoint2: polar(0.4, 30, base))
        blade.close()
        NSGradient(starting: color(0xFFFFFF), ending: color(0xBCD4F2))!.draw(in: blade, angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()

    // Hub.
    let hubRadius = radius * 0.22
    let hub = NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2))
    NSGradient(starting: color(0xE9F2FF), ending: color(0x8FB3E0))!.draw(in: hub, angle: -90)
    color(0x0B2E66, 0.35).setStroke(); hub.lineWidth = max(1, s * 0.004); hub.stroke()
    let cap = hubRadius * 0.38
    color(0x1557C0, 0.8).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - cap, y: center.y - cap, width: cap * 2, height: cap * 2)).fill()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
