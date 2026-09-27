import AppKit

/// A physical input that can drive a mapped control: a keyboard key (Mac virtual
/// key code), a mouse button, or a scroll direction.
enum InputKey: Hashable {
    case key(UInt16)
    case mouse(Int)      // 0 left, 1 right, 2 middle, 3+ side buttons
    case scrollUp
    case scrollDown

    var isMouse: Bool {
        switch self {
        case .key: return false
        default: return true
        }
    }

    /// Short, natural label for keycaps ("W", "⇧", "Space"). Mouse inputs return nil
    /// because they are drawn as a mouse icon instead.
    var capLabel: String? {
        guard case .key(let code) = self else { return nil }
        return InputKey.names[code] ?? "#\(code)"
    }

    /// Readable name for tooltips and the editor ("Left click", "Shift").
    var longName: String {
        switch self {
        case .key(let code): return InputKey.longNames[code] ?? capLabel ?? "Key"
        case .mouse(0): return "Left click"
        case .mouse(1): return "Right click"
        case .mouse(2): return "Middle click"
        case .mouse(let n): return "Mouse button \(n + 1)"
        case .scrollUp: return "Scroll up"
        case .scrollDown: return "Scroll down"
        }
    }

    // Mac virtual key codes (kVK_*) → keycap text.
    static let names: [UInt16: String] = {
        var m: [UInt16: String] = [:]
        let letters: [(UInt16, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
            (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"),
            (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
            (50, "`"), (27, "-"), (24, "="), (33, "["), (30, "]"), (42, "\\"), (41, ";"), (39, "'"), (43, ","),
            (47, "."), (44, "/"),
            (49, "Space"), (48, "⇥"), (36, "⏎"), (51, "⌫"), (53, "esc"), (117, "⌦"),
            (56, "⇧"), (60, "⇧"), (59, "⌃"), (62, "⌃"), (58, "⌥"), (61, "⌥"), (57, "⇪"),
            (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
            (115, "home"), (119, "end"), (116, "pg↑"), (121, "pg↓"),
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
            (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
        ]
        for (k, v) in letters { m[k] = v }
        return m
    }()

    static let longNames: [UInt16: String] = [
        49: "Space", 48: "Tab", 36: "Return", 51: "Delete", 53: "Escape", 56: "Shift", 60: "Right Shift",
        59: "Control", 62: "Right Control", 58: "Option", 61: "Right Option", 57: "Caps Lock", 50: "Backtick (`)",
        123: "Left arrow", 124: "Right arrow", 125: "Down arrow", 126: "Up arrow",
    ]

    /// Modifier keys arrive as flagsChanged events; this maps their key code to the flag.
    static let modifierFlags: [UInt16: NSEvent.ModifierFlags] = [
        56: .shift, 60: .shift, 59: .control, 62: .control, 58: .option, 61: .option,
        55: .command, 54: .command, 57: .capsLock, 63: .function,
    ]
}

// MARK: - Persistence as compact strings ("k:13", "m:0", "wheel:up")

extension InputKey: Codable {
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        if s == "wheel:up" { self = .scrollUp; return }
        if s == "wheel:down" { self = .scrollDown; return }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad key \(s)"))
        }
        self = parts[0] == "m" ? .mouse(n) : .key(UInt16(n))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .key(let k): try c.encode("k:\(k)")
        case .mouse(let n): try c.encode("m:\(n)")
        case .scrollUp: try c.encode("wheel:up")
        case .scrollDown: try c.encode("wheel:down")
        }
    }
}

// MARK: - Drawing

enum Glyph {
    static let capFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// Size a key glyph needs at the given scale.
    static func size(of key: InputKey, scale: CGFloat = 1) -> CGSize {
        if let label = key.capLabel {
            let w = (label as NSString).size(withAttributes: [.font: capFont]).width
            return CGSize(width: max(22, w + 12) * scale, height: 22 * scale)
        }
        return CGSize(width: 18 * scale, height: 24 * scale)
    }

    /// Draws a keycap or a mouse icon centred at `center`.
    static func draw(_ key: InputKey, at center: CGPoint, scale: CGFloat = 1, highlighted: Bool = false, dim: Bool = false) {
        let sz = size(of: key, scale: scale)
        let rect = CGRect(x: center.x - sz.width / 2, y: center.y - sz.height / 2, width: sz.width, height: sz.height)
        let alpha: CGFloat = dim ? 0.55 : 0.95
        if let label = key.capLabel {
            drawKeycap(label, in: rect, scale: scale, highlighted: highlighted, alpha: alpha)
        } else {
            drawMouse(key, in: rect, highlighted: highlighted, alpha: alpha)
        }
    }

    static func drawKeycap(_ label: String, in rect: CGRect, scale: CGFloat, highlighted: Bool, alpha: CGFloat) {
        let r = 5 * scale
        // base + lip gives the keycap a bit of depth
        NSColor(white: 0.0, alpha: 0.45 * alpha).setFill()
        NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: 1.5 * scale), xRadius: r, yRadius: r).fill()
        (highlighted ? NSColor.controlAccentColor : NSColor(white: 0.14, alpha: 0.88 * alpha)).setFill()
        let cap = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        cap.fill()
        NSColor(white: 1, alpha: 0.35 * alpha).setStroke()
        cap.lineWidth = 1
        cap.stroke()
        let font = NSFont.systemFont(ofSize: 12 * scale, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: alpha)]
        let s = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: CGPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2), withAttributes: attrs)
    }

    /// A mouse outline with the relevant button (or wheel) filled in.
    static func drawMouse(_ key: InputKey, in rect: CGRect, highlighted: Bool, alpha: CGFloat) {
        let body = NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2)
        NSColor(white: 0.14, alpha: 0.88 * alpha).setFill()
        body.fill()

        let fill = highlighted ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.9 * alpha)
        let top = rect.height * 0.45
        // Flipped views have y growing downward; draw relative to the button region.
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        let buttonsRect = flipped
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: top)
            : CGRect(x: rect.minX, y: rect.maxY - top, width: rect.width, height: top)

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        fill.setFill()
        switch key {
        case .mouse(0):
            CGRect(x: buttonsRect.minX, y: buttonsRect.minY, width: buttonsRect.width / 2 - 0.5, height: buttonsRect.height).fill()
        case .mouse(1):
            CGRect(x: buttonsRect.midX + 0.5, y: buttonsRect.minY, width: buttonsRect.width / 2, height: buttonsRect.height).fill()
        default:
            break
        }
        NSGraphicsContext.restoreGraphicsState()

        // divider between buttons and body outline
        NSColor(white: 1, alpha: 0.6 * alpha).setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: buttonsRect.midX, y: buttonsRect.minY))
        divider.line(to: CGPoint(x: buttonsRect.midX, y: buttonsRect.maxY))
        let across = NSBezierPath()
        let yLine = flipped ? buttonsRect.maxY : buttonsRect.minY
        across.move(to: CGPoint(x: rect.minX, y: yLine))
        across.line(to: CGPoint(x: rect.maxX, y: yLine))
        for p in [divider, across, body] { p.lineWidth = 1; p.stroke() }

        // wheel: filled for middle click / scroll, with an arrow for scroll direction
        let wheel = CGRect(x: rect.midX - 1.5, y: buttonsRect.midY - 3.5, width: 3, height: 7)
        let wheelActive: Bool
        switch key {
        case .mouse(2), .scrollUp, .scrollDown: wheelActive = true
        default: wheelActive = false
        }
        (wheelActive ? fill : NSColor(white: 0.14, alpha: alpha)).setFill()
        NSBezierPath(roundedRect: wheel, xRadius: 1.5, yRadius: 1.5).fill()
        if case .mouse(let n) = key, n >= 3 {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: fill]
            ("\(n + 1)" as NSString).draw(at: CGPoint(x: rect.midX - 3, y: rect.midY), withAttributes: attrs)
        }
        if key == .scrollUp || key == .scrollDown {
            let up = (key == .scrollUp) != flipped
            let arrow = NSBezierPath()
            let ax = rect.maxX + 5, ay = rect.midY
            arrow.move(to: CGPoint(x: ax - 3, y: up ? ay - 2 : ay + 2))
            arrow.line(to: CGPoint(x: ax, y: up ? ay + 2 : ay - 2))
            arrow.line(to: CGPoint(x: ax + 3, y: up ? ay - 2 : ay + 2))
            fill.setStroke()
            arrow.lineWidth = 1.5
            arrow.stroke()
        }
    }

    /// Draws an SF Symbol tinted white, centred at `center`.
    static func drawSymbol(_ name: String, at center: CGPoint, pointSize: CGFloat, alpha: CGFloat = 0.95) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(white: 1, alpha: alpha)]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = img.size
        img.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
