import AppKit

// Finder uses a 640 x 400 point canvas; render at 2x for Retina displays.
let size = NSSize(width: 640, height: 400)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 800,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.setFillColor(CGColor(red: 0.965, green: 0.98, blue: 1, alpha: 1))
context.fill(CGRect(origin: .zero, size: size))

// Airflow rings echo the fan icon while leaving the installation area clear.
context.setLineWidth(1)
for radius in stride(from: CGFloat(60), through: 240, by: 24) {
    context.setStrokeColor(CGColor(red: 0.18, green: 0.48, blue: 0.85, alpha: 0.09))
    context.strokeEllipse(in: CGRect(x: 635 - radius, y: 380 - radius, width: radius * 2, height: radius * 2))
    context.strokeEllipse(in: CGRect(x: 5 - radius, y: 15 - radius, width: radius * 2, height: radius * 2))
}
func centered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    (text as NSString).draw(in: NSRect(x: 30, y: y, width: 580, height: 36), withAttributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: style
    ])
}
centered("Macs Fan Control", y: 305, font: .systemFont(ofSize: 27, weight: .semibold),
    color: NSColor(srgbRed: 0.08, green: 0.19, blue: 0.32, alpha: 1))
centered("Drag to Applications to install", y: 55, font: .systemFont(ofSize: 15), color: .secondaryLabelColor)
context.setStrokeColor(CGColor(red: 0.15, green: 0.40, blue: 0.72, alpha: 1))
context.setLineWidth(2.5)
context.setLineCap(.round); context.setLineJoin(.round)
context.move(to: CGPoint(x: 285, y: 195)); context.addLine(to: CGPoint(x: 355, y: 195))
context.move(to: CGPoint(x: 345, y: 205)); context.addLine(to: CGPoint(x: 355, y: 195))
context.addLine(to: CGPoint(x: 345, y: 185)); context.strokePath()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .tiff, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
