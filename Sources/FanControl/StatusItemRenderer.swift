import AppKit
import FanCore

/// One value in the menu bar. `template` is the widest text the value can take,
/// so its slot keeps a constant width as readings change.
struct StatusSegment: Equatable {
    var value: String
    var unit: String
    var template: String
    var tint: NSColor?
}

struct StatusDisplay: Equatable {
    var segments: [StatusSegment]
    var icon: MenuIconStyle
    var manual: Bool
    var demo: Bool
}

/// Draws the status item as a single image: fixed-width, right-aligned value slots
/// keep the item from shifting as readings change, which a plain title cannot do.
enum StatusItemRenderer {
    private static let height: CGFloat = 22
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    private static let unitFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private static let badgeFont = NSFont.systemFont(ofSize: 8, weight: .bold)

    static func image(_ display: StatusDisplay, appearance: NSAppearance? = nil) -> NSImage {
        // Template images let AppKit pick the menu bar's text color, including
        // the highlighted state. Any per-value tint needs a full-color image.
        let tinted = display.icon == .colored && (display.manual || display.segments.contains { $0.tint != nil })
        let ink = tinted ? labelColor(appearance) : NSColor.black
        var parts: [(width: CGFloat, draw: (CGFloat) -> Void)] = []

        if display.icon != .none, let symbol = icon(display, ink: ink) {
            parts.append((symbol.size.width, { x in
                symbol.draw(in: NSRect(x: x, y: (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
            }))
        }
        if display.demo {
            let text = NSAttributedString(string: "DEMO", attributes: [.font: badgeFont, .foregroundColor: ink])
            let size = text.size()
            parts.append((size.width + 8, { x in
                let box = NSRect(x: x, y: (height - 12) / 2, width: size.width + 8, height: 12)
                ink.withAlphaComponent(0.85).setStroke()
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                path.lineWidth = 1; path.stroke()
                text.draw(at: NSPoint(x: box.minX + 4, y: box.minY + (12 - size.height) / 2))
            }))
        }
        for segment in display.segments {
            let color = (tinted ? segment.tint : nil) ?? ink
            let value = NSAttributedString(string: segment.value, attributes: [.font: valueFont, .foregroundColor: color])
            let unit = NSAttributedString(string: segment.unit, attributes: [.font: unitFont, .foregroundColor: color.withAlphaComponent(0.7)])
            let slot = max(NSAttributedString(string: segment.template, attributes: [.font: valueFont]).size().width, value.size().width)
            let unitWidth = unit.size().width
            parts.append((slot + 1.5 + unitWidth, { x in
                let valueSize = value.size()
                // Right-align so the digits stay put and only leading space changes.
                value.draw(at: NSPoint(x: x + slot - valueSize.width, y: (height - valueSize.height) / 2))
                let baseline = (height - valueSize.height) / 2 + valueFont.ascender
                unit.draw(at: NSPoint(x: x + slot + 1.5, y: baseline - unitFont.ascender))
            }))
        }

        let spacing: CGFloat = 6
        let width = ceil(parts.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, parts.count - 1)))
        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts { part.draw(x); x += part.width + spacing }
            return true
        }
        image.isTemplate = !tinted
        image.accessibilityDescription = "Macs Fan Control Swift"
        return image
    }

    private static func icon(_ display: StatusDisplay, ink: NSColor) -> NSImage? {
        let colored = display.icon == .colored
        let name = display.manual ? "fan.fill" : "fan"
        var configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if colored { configuration = configuration.applying(.init(paletteColors: [display.manual ? .systemOrange : ink])) }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        if colored { return symbol }
        // Template drawing needs opaque black pixels.
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.black.set(); rect.fill(using: .sourceAtop)
            return true
        }
        return tinted
    }

    private static func labelColor(_ appearance: NSAppearance?) -> NSColor {
        let isDark = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .white : .black
    }

    static func temperatureTint(_ celsius: Double) -> NSColor? {
        celsius >= 90 ? .systemRed : celsius >= 75 ? .systemOrange : nil
    }
}
