import AppKit

/// Draws the mapped controls over the game. In edit mode it becomes interactive:
/// drag to move, click to change keys, add/remove controls.
final class KeymapOverlayView: NSView {
    enum Mode { case hidden, play, edit }

    var mode: Mode = .hidden { didSet { modeChanged(from: oldValue) } }
    var keymap = Keymap.bgmi { didSet { needsDisplay = true } }
    var deviceSize = CGSize(width: 1920, height: 1080)
    var isAiming = false { didSet { needsDisplay = true } }
    /// Called whenever the user edits the layout.
    var onChange: ((Keymap) -> Void)?
    var onDone: (() -> Void)?
    /// Shown at the start of the editor toolbar (the layout picker).
    var toolbarAccessory: NSView?

    private var selectedID: UUID?
    private var dragOffset: CGPoint?
    private var dragMoved = false
    private var toolbar: NSView?
    private var popover: NSPopover?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        mode == .edit ? super.hitTest(point) : nil
    }

    private func modeChanged(from old: Mode) {
        isHidden = mode == .hidden
        if mode == .edit { showToolbar() } else { toolbar?.removeFromSuperview(); toolbar = nil; popover?.close() }
        selectedID = nil
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if let toolbar {
            toolbar.frame.origin = CGPoint(x: (bounds.width - toolbar.frame.width) / 2, y: 12)
        }
    }

    // MARK: Geometry

    private func center(_ c: Control) -> CGPoint { CGPoint(x: c.x * bounds.width, y: c.y * bounds.height) }

    private func joystickRadius(_ c: Control) -> CGFloat { CGFloat(c.radius ?? 0.12) * bounds.height }

    private func control(at p: CGPoint) -> Control? {
        keymap.controls.reversed().first { c in
            let d = hypot(p.x - center(c).x, p.y - center(c).y)
            return c.type == .joystick ? d < joystickRadius(c) + 14 : d < 26
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard mode != .hidden else { return }
        let editing = mode == .edit
        if editing {
            NSColor(white: 0, alpha: 0.45).setFill()
            bounds.fill()
        }
        let dim = !editing
        for c in keymap.controls {
            if !editing && isAiming && (c.type == .aim || c.type == .look) { continue }
            let p = center(c)
            let selected = c.id == selectedID
            switch c.type {
            case .joystick:
                let r = joystickRadius(c)
                let ring = NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                NSColor(white: 1, alpha: editing ? 0.12 : 0.05).setFill()
                ring.fill()
                NSColor(white: 1, alpha: editing ? 0.6 : 0.3).setStroke()
                ring.lineWidth = selected ? 3 : 1.5
                ring.stroke()
                if let dirs = c.keys, dirs.count == 4 {
                    let spots = [CGPoint(x: p.x, y: p.y - r), CGPoint(x: p.x - r, y: p.y),
                                 CGPoint(x: p.x, y: p.y + r), CGPoint(x: p.x + r, y: p.y)]
                    for (key, spot) in zip(dirs, spots) { Glyph.draw(key, at: spot, dim: dim) }
                }
                if let boost = c.boostKey {
                    let spot = CGPoint(x: p.x + r * 0.75, y: p.y - r * 0.95)
                    Glyph.draw(boost, at: spot, scale: 0.85, dim: dim)
                    if editing { caption("Sprint", below: spot, offset: 14) }
                }
            case .aim, .look:
                Glyph.drawSymbol(c.type.symbol, at: CGPoint(x: p.x, y: p.y - 6), pointSize: 18, alpha: dim ? 0.6 : 0.95)
                if let key = c.key { Glyph.draw(key, at: CGPoint(x: p.x, y: p.y + 16), dim: dim) }
            case .tap, .fire:
                if let key = c.key {
                    Glyph.draw(key, at: p, highlighted: selected, dim: dim)
                } else {
                    Glyph.drawKeycap("?", in: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22), scale: 1, highlighted: selected, alpha: 0.9)
                }
            }
            if editing {
                if selected && c.type != .joystick {
                    let ring = NSBezierPath(ovalIn: CGRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48))
                    NSColor.controlAccentColor.setStroke()
                    ring.lineWidth = 2
                    ring.stroke()
                }
                let below = c.type == .joystick ? joystickRadius(c) + 14 : (c.type == .aim || c.type == .look ? 32 : 16)
                caption(c.label ?? c.type.title, below: p, offset: below)
            }
        }
    }

    private func caption(_ text: String, below p: CGPoint, offset: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white, .shadow: shadow]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: p.x - s.width / 2, y: p.y + offset - 2), withAttributes: attrs)
    }

    // MARK: Editing

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        popover?.close()
        if let c = control(at: p) {
            selectedID = c.id
            dragOffset = CGPoint(x: p.x - center(c).x, y: p.y - center(c).y)
            dragMoved = false
        } else {
            selectedID = nil
            if event.clickCount == 2 { add(.tap, at: p) }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = selectedID, let off = dragOffset, let i = keymap.controls.firstIndex(where: { $0.id == id }) else { return }
        let p = convert(event.locationInWindow, from: nil)
        keymap.controls[i].x = Double(min(max((p.x - off.x) / bounds.width, 0), 1))
        keymap.controls[i].y = Double(min(max((p.y - off.y) / bounds.height, 0), 1))
        dragMoved = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOffset = nil }
        if dragMoved { onChange?(keymap); return }
        if let id = selectedID, dragOffset != nil { showInspector(for: id) }
    }

    override func keyDown(with event: NSEvent) {
        // Delete removes the selected control; Escape leaves the editor.
        if event.keyCode == 51 || event.keyCode == 117, let id = selectedID {
            remove(id)
        } else if event.keyCode == 53 {
            onDone?()
        }
    }

    override var acceptsFirstResponder: Bool { mode == .edit }

    private func add(_ type: ControlType, at p: CGPoint? = nil) {
        let at = p ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let c = Control.new(type, x: Double(at.x / bounds.width), y: Double(at.y / bounds.height))
        keymap.controls.append(c)
        selectedID = c.id
        onChange?(keymap)
        showInspector(for: c.id)
    }

    private func remove(_ id: UUID) {
        keymap.controls.removeAll { $0.id == id }
        selectedID = nil
        popover?.close()
        onChange?(keymap)
    }

    private func showInspector(for id: UUID) {
        guard let c = keymap.controls.first(where: { $0.id == id }) else { return }
        let inspector = ControlInspector(control: c)
        inspector.onChange = { [weak self] updated in
            guard let self, let i = self.keymap.controls.firstIndex(where: { $0.id == updated.id }) else { return }
            self.keymap.controls[i] = updated
            self.onChange?(self.keymap)
        }
        inspector.onDelete = { [weak self] in self?.remove(id) }
        let pop = NSPopover()
        pop.contentViewController = inspector
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        let p = center(c)
        pop.show(relativeTo: CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40), of: self, preferredEdge: .maxY)
        popover = pop
    }

    // MARK: Toolbar

    private func showToolbar() {
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.appearance = NSAppearance(named: .darkAqua)

        let add = { (title: String, symbol: String, type: ControlType) -> NSButton in
            let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                             target: nil, action: nil)
            b.bezelStyle = .accessoryBarAction
            b.imagePosition = .imageLeading
            b.toolTip = "Add \(type.title.lowercased())"
            b.setAccessibilityLabel("Add \(type.title)")
            b.onClick { [weak self] in self?.add(type) }
            return b
        }
        let reset = NSButton(title: "Reset", image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset")!,
                             target: nil, action: nil)
        reset.bezelStyle = .accessoryBarAction
        reset.toolTip = "Put this layout's buttons back to the BGMI Layout 2 defaults"
        reset.onClick { [weak self] in
            guard let self else { return }
            var fresh = Keymap.bgmi
            fresh.id = self.keymap.id
            fresh.name = self.keymap.name
            self.keymap = fresh
            self.selectedID = nil
            self.onChange?(self.keymap)
        }
        let done = NSButton(title: "Done", target: nil, action: nil)
        done.bezelStyle = .push
        done.keyEquivalent = "\r"
        done.onClick { [weak self] in self?.onDone?() }

        let hint = NSTextField(labelWithString: "Drag to move · Click to change its key · Double-click empty space to add a button")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: (toolbarAccessory.map { [$0] } ?? []) + [
            add("Button", "hand.tap", .tap), add("Joystick", "dpad", .joystick), add("Aim", "scope", .aim),
            add("Fire", "flame", .fire), add("Free look", "eye", .look), reset, done,
        ])
        buttons.spacing = 6
        let stack = NSStackView(views: [buttons, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        bar.frame.size = stack.fittingSize
        addSubview(bar)
        toolbar = bar
        needsLayout = true
        window?.makeFirstResponder(self)
    }
}

// MARK: - Inspector popover

/// Edits one control: name, keys, size / sensitivity, delete.
final class ControlInspector: NSViewController {
    private var control: Control
    var onChange: ((Control) -> Void)?
    var onDelete: (() -> Void)?

    init(control: Control) {
        self.control = control
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: control.type.title)
        title.font = .boldSystemFont(ofSize: 13)

        let name = NSTextField(string: control.label ?? "")
        name.placeholderString = "Name"
        name.onChange { [weak self] text in
            self?.control.label = text.isEmpty ? nil : text
            self?.commit()
        }

        var rows: [NSView] = [title, row("Name", name)]
        switch control.type {
        case .joystick:
            let names = ["Up", "Left", "Down", "Right"]
            for (i, n) in names.enumerated() {
                rows.append(row(n, KeyCaptureButton(key: control.keys?[i]) { [weak self] k in
                    self?.control.keys?[i] = k
                    self?.commit()
                }))
            }
            rows.append(row("Sprint", KeyCaptureButton(key: control.boostKey) { [weak self] k in
                self?.control.boostKey = k
                self?.commit()
            }))
            rows.append(row("Size", slider(value: control.radius ?? 0.12, range: 0.05...0.25) { [weak self] v in
                self?.control.radius = v
                self?.commit()
            }))
        case .aim, .look:
            let label = control.type == .aim ? "Toggle" : "Hold"
            rows.append(row(label, KeyCaptureButton(key: control.key) { [weak self] k in
                self?.control.key = k
                self?.commit()
            }))
            rows.append(row("Speed", slider(value: control.sensitivity ?? 1, range: 0.2...3) { [weak self] v in
                self?.control.sensitivity = v
                self?.commit()
            }))
        case .tap, .fire:
            rows.append(row("Key", KeyCaptureButton(key: control.key) { [weak self] k in
                self?.control.key = k
                self?.commit()
            }))
        }
        if control.type == .tap {
            let box = NSButton(checkboxWithTitle: "Show cursor (for bag, map, menus)", target: nil, action: nil)
            box.state = control.showsCursor == true ? .on : .off
            box.toolTip = "During mouse aim, this button shows the cursor; pressing it again (or Esc) hides it and resumes aim"
            box.onClick { [weak self] in
                self?.control.showsCursor = box.state == .on ? true : nil
                self?.commit()
            }
            rows.append(box)
            let hold = NSButton(checkboxWithTitle: "Hold to keep open (closes on release)", target: nil, action: nil)
            hold.state = control.holdToOpen == true ? .on : .off
            hold.toolTip = "Pressing the key opens it; letting go taps it again to close"
            hold.onClick { [weak self] in
                self?.control.holdToOpen = hold.state == .on ? true : nil
                self?.commit()
            }
            rows.append(hold)
        }
        if control.type == .aim {
            rows.append(note("Press it in game to lock the mouse for aiming. Esc releases it."))
        } else if control.type == .fire {
            rows.append(note("Works while mouse aim is on."))
        }

        let delete = NSButton(title: "Remove", image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove")!,
                              target: nil, action: nil)
        delete.bezelStyle = .push
        delete.contentTintColor = .systemRed
        delete.onClick { [weak self] in self?.onDelete?() }
        rows.append(delete)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.frame.size = stack.fittingSize
        view = stack
    }

    private func commit() { onChange?(control) }

    private func row(_ label: String, _ field: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.textColor = .secondaryLabelColor
        l.widthAnchor.constraint(equalToConstant: 52).isActive = true
        if field is NSTextField || field is NSSlider { field.widthAnchor.constraint(equalToConstant: 160).isActive = true }
        let s = NSStackView(views: [l, field])
        s.spacing = 8
        return s
    }

    private func note(_ text: String) -> NSView {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 220
        return t
    }

    private func slider(value: Double, range: ClosedRange<Double>, _ changed: @escaping (Double) -> Void) -> NSSlider {
        let s = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        s.isContinuous = true
        s.onChange { changed(s.doubleValue) }
        return s
    }
}

/// Shows a key as a keycap / mouse icon; click it, then press a key, click, or
/// scroll to rebind. Escape cancels.
final class KeyCaptureButton: NSButton {
    private var key: InputKey?
    private let changed: (InputKey) -> Void
    private var capturing = false { didSet { refresh() } }

    init(key: InputKey?, changed: @escaping (InputKey) -> Void) {
        self.key = key
        self.changed = changed
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        imagePosition = .imageLeading
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private func refresh() {
        if capturing {
            title = "Press a key, click or scroll…"
            image = nil
        } else if let key {
            title = key.longName
            let size = Glyph.size(of: key)
            image = NSImage(size: CGSize(width: size.width + 4, height: size.height + 4), flipped: false) { rect in
                Glyph.draw(key, at: CGPoint(x: rect.midX, y: rect.midY))
                return true
            }
        } else {
            title = "Choose a key"
            image = nil
        }
        invalidateIntrinsicContentSize()
    }

    private func finish(_ k: InputKey?) {
        capturing = false
        if let k { key = k; refresh(); changed(k) }
    }

    override func mouseDown(with event: NSEvent) {
        if capturing { finish(.mouse(0)) } else { capturing = true; window?.makeFirstResponder(self) }
    }
    override func rightMouseDown(with event: NSEvent) { if capturing { finish(.mouse(1)) } }
    override func otherMouseDown(with event: NSEvent) { if capturing { finish(.mouse(event.buttonNumber)) } }
    override func scrollWheel(with event: NSEvent) {
        if capturing, event.scrollingDeltaY != 0 { finish(event.scrollingDeltaY > 0 ? .scrollUp : .scrollDown) }
    }
    override func keyDown(with event: NSEvent) {
        guard capturing else { super.keyDown(with: event); return }
        finish(event.keyCode == 53 ? nil : .key(event.keyCode))
    }
    override func flagsChanged(with event: NSEvent) {
        guard capturing, let flag = InputKey.modifierFlags[event.keyCode], flag != .command,
              event.modifierFlags.contains(flag) else { return }
        finish(.key(event.keyCode))
    }
    override func resignFirstResponder() -> Bool {
        if capturing { capturing = false }
        return super.resignFirstResponder()
    }
}

// MARK: - Closure-based actions for AppKit controls

private final class ActionTrampoline: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

private var trampolineKey: UInt8 = 0

extension NSControl {
    func onClick(_ handler: @escaping () -> Void) {
        let t = ActionTrampoline(handler)
        objc_setAssociatedObject(self, &trampolineKey, t, .OBJC_ASSOCIATION_RETAIN)
        target = t
        action = #selector(ActionTrampoline.fire)
    }

    func onChange(_ handler: @escaping () -> Void) { onClick(handler) }
}

extension NSTextField {
    func onChange(_ handler: @escaping (String) -> Void) {
        onClick { [weak self] in handler(self?.stringValue ?? "") }
    }
}
