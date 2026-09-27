import AppKit
import os

private let log = Logger(subsystem: "com.devesh.pocketbay", category: "keymap")

/// Turns keyboard/mouse input into multi-touch according to the active keymap.
/// Every control owns its own touch identifier so several can be held at once
/// (move + aim + fire + scope).
final class KeymapEngine {
    var client: EmulatorClient?
    var keymap: Keymap { didSet { releaseAll() } }
    var deviceSize = CGSize(width: 1920, height: 1080)
    /// Converts a point on the shown picture to the emulator's touch space (rotation).
    var toNative: (CGPoint) -> CGPoint = { $0 }

    /// Whether mapping applies right now (enabled + the mapped app is in front).
    var isActive = false {
        didSet { if !isActive && oldValue { releaseAll() } }
    }
    private(set) var isAiming = false
    var onAimingChanged: ((Bool) -> Void)?
    /// On-foot vs vehicle controls.
    private(set) var mode: ControlMode = .foot
    var onModeChanged: ((ControlMode) -> Void)?
    /// Which controls each held input activated, so release lifts exactly those even if
    /// the mode changed in between.
    private var activated: [InputKey: [UUID]] = [:]

    private var held = Set<InputKey>()
    private var joystickTouching = false
    /// Current finger position for the aim / free-look drags (device pixels).
    private var aimFinger: CGPoint?
    private var lookFinger: CGPoint?
    private var lookHeld = false
    /// A "shows cursor" button (bag/map) paused mouse aim; pressing it again, or Esc, resumes.
    private var aimPausedBy: UUID?
    private var resumeAimOnRelease = false
    /// Hold-to-open buttons currently held: when they were pressed, and whether aim should resume.
    private var holdStarted: [UUID: (time: Date, resumeAim: Bool)] = [:]

    private static let aimTouchID: Int32 = 200
    private static let lookTouchID: Int32 = 201

    init(keymap: Keymap) { self.keymap = keymap }

    // MARK: Queries

    private var aimControl: Control? { keymap.controls.first { $0.type == .aim } }
    private var lookControl: Control? { keymap.controls.first { $0.type == .look } }

    private func touchID(_ c: Control) -> Int32 {
        Int32((keymap.controls.firstIndex(of: c) ?? 0) + 1)
    }

    private func worksNow(_ c: Control) -> Bool { c.mode == nil || c.mode == mode }

    private func point(_ c: Control) -> CGPoint {
        CGPoint(x: c.x * deviceSize.width, y: c.y * deviceSize.height)
    }

    /// Mouse buttons are only mapped while aiming, so the pointer works normally otherwise.
    private func applies(_ input: InputKey) -> Bool {
        isActive && (!input.isMouse || isAiming)
    }

    // MARK: Input

    /// Returns true if the input was consumed by the keymap.
    @discardableResult
    func press(_ input: InputKey) -> Bool {
        guard applies(input) else {
            log.debug("press \(input.longName, privacy: .public) ignored (active=\(self.isActive), aiming=\(self.isAiming))")
            return false
        }
        if input == keymap.vehicleToggleKey, !keymap.controls.contains(where: { $0.inputs.contains(input) }) {
            if !held.contains(input) { held.insert(input); setMode(mode == .foot ? .vehicle : .foot) }
            return true
        }
        let all = keymap.controls.filter { $0.inputs.contains(input) }
        guard !all.isEmpty else { return false }
        let controls = all.filter(worksNow)
        log.info("press \(input.longName, privacy: .public) -> \(controls.map { $0.label ?? $0.type.title }.joined(separator: ","), privacy: .public) (aiming=\(self.isAiming), paused=\(self.aimPausedBy != nil))")
        if held.contains(input) { return true }   // key repeat
        held.insert(input)
        activated[input] = controls.map(\.id)
        activate(controls, for: input)
        return true
    }

    /// Puts fingers down for the given controls (a key press, or a mode change while held).
    private func activate(_ controls: [Control], for input: InputKey) {
        for c in controls {
            switch c.type {
            case .tap where c.holdToOpen == true:
                // Open now; release (below) closes it again.
                let wasAiming = isAiming
                if c.showsCursor == true && wasAiming { setAiming(false) }
                holdStarted[c.id] = (Date(), wasAiming && c.showsCursor == true)
                quickTap(c)
            case .tap, .fire:
                if c.type == .fire && !isAiming { continue }
                if c.showsCursor == true {
                    if isAiming {
                        setAiming(false)
                        aimPausedBy = c.id
                    } else if aimPausedBy == c.id {
                        aimPausedBy = nil
                        resumeAimOnRelease = true
                    }
                }
                touch(c, at: point(c), down: true)
            case .joystick:
                updateJoystick(c)
            case .aim:
                setAiming(!isAiming)
            case .look:
                if isAiming { beginLook() } else { touch(c, at: point(c), down: true) }
            }
        }
    }

    @discardableResult
    func release(_ input: InputKey) -> Bool {
        guard held.remove(input) != nil else { return false }
        let ids = activated.removeValue(forKey: input) ?? []
        let controls = keymap.controls.filter { ids.contains($0.id) || ($0.type == .joystick && $0.inputs.contains(input)) }
        deactivate(controls, for: input)
        if let action = controls.first(where: { $0.switchesTo != nil })?.switchesTo {
            // After the tap lands, so the game sees the button press first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                switch action {
                case .foot: self.setMode(.foot)
                case .vehicle: self.setMode(.vehicle)
                case .toggle: self.setMode(self.mode == .foot ? .vehicle : .foot)
                }
            }
        }
        return true
    }

    /// Lifts the fingers of the given controls.
    private func deactivate(_ controls: [Control], for input: InputKey) {
        for c in controls {
            switch c.type {
            case .tap where c.holdToOpen == true:
                guard let hold = holdStarted.removeValue(forKey: c.id) else { continue }
                // Give the game time to register the opening tap before closing it.
                let wait = max(0, 0.15 - Date().timeIntervalSince(hold.time))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.quickTap(c)
                    if hold.resumeAim {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.setAiming(true) }
                    }
                }
            case .tap, .fire:
                touch(c, at: point(c), down: false)
                if resumeAimOnRelease {
                    resumeAimOnRelease = false
                    // Let the game close its menu before the camera grabs the mouse again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.setAiming(true) }
                }
            case .joystick: updateJoystick(c)
            case .aim: break
            case .look:
                if lookHeld { endLook() } else { touch(c, at: point(c), down: false) }
            }
        }
    }

    /// Switches between on-foot and vehicle controls. Keys still held are re-applied:
    /// controls that stopped working are lifted, ones that now work are pressed.
    func setMode(_ newMode: ControlMode) {
        guard newMode != mode else { return }
        mode = newMode
        for input in held {
            let ids = activated[input] ?? []
            let stale = keymap.controls.filter { ids.contains($0.id) && !worksNow($0) }
            if !stale.isEmpty { deactivate(stale, for: input) }
            let fresh = keymap.controls.filter { $0.inputs.contains(input) && worksNow($0) && !ids.contains($0.id) && $0.type != .aim }
            activated[input] = ids.filter { id in !stale.contains { $0.id == id } } + fresh.map(\.id)
            if !fresh.isEmpty { activate(fresh, for: input) }
        }
        for c in keymap.controls where c.type == .joystick { updateJoystick(c) }
        onModeChanged?(newMode)
    }

    /// Scroll mapping fires a quick tap.
    func scroll(up: Bool) -> Bool {
        let input: InputKey = up ? .scrollUp : .scrollDown
        guard applies(input), keymap.controls.contains(where: { $0.inputs.contains(input) }) else { return false }
        press(input)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { self.release(input) }
        return true
    }

    /// Relative mouse motion while aiming (points, y down).
    func mouseMoved(dx: CGFloat, dy: CGFloat) {
        guard isAiming else { return }
        // Mice report far faster than the emulator applies touches; sending one touch
        // per event queues input up (and delays key presses behind it). Accumulate and
        // flush at most every 4 ms.
        pendingDX += dx
        pendingDY += dy
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self] in self?.flushAimMotion() }
    }

    private var pendingDX: CGFloat = 0
    private var pendingDY: CGFloat = 0
    private var flushScheduled = false

    private func flushAimMotion() {
        flushScheduled = false
        let dx = pendingDX, dy = pendingDY
        pendingDX = 0; pendingDY = 0
        guard isAiming, dx != 0 || dy != 0 else { return }
        if lookHeld, let look = lookControl {
            lookFinger = drag(lookFinger, anchor: point(look), id: Self.lookTouchID,
                              dx: dx, dy: dy, sensitivity: look.sensitivity ?? 1)
        } else if let aim = aimControl {
            aimFinger = drag(aimFinger, anchor: point(aim), id: Self.aimTouchID,
                             dx: dx, dy: dy, sensitivity: aim.sensitivity ?? 1)
        }
    }

    // MARK: Behaviours

    private func finger(_ id: Int32, _ p: CGPoint, down: Bool) -> EmuTouch {
        let n = toNative(p)
        return .finger(id, x: Int32(n.x), y: Int32(n.y), down: down)
    }

    /// A short press-and-release on the control's spot.
    private func quickTap(_ c: Control) {
        touch(c, at: point(c), down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.touch(c, at: self.point(c), down: false)
        }
    }

    private func touch(_ c: Control, at p: CGPoint, down: Bool) {
        client?.touch([finger(touchID(c), p, down: down)])
    }

    private func updateJoystick(_ c: Control) {
        guard let dirs = c.keys, dirs.count == 4 else { return }
        let up = held.contains(dirs[0]), left = held.contains(dirs[1])
        let down = held.contains(dirs[2]), right = held.contains(dirs[3])
        let working = worksNow(c)
        var v = working ? CGVector(dx: (right ? 1 : 0) - (left ? 1 : 0), dy: (down ? 1 : 0) - (up ? 1 : 0)) : .zero
        let centre = point(c)
        let id = touchID(c)

        guard v.dx != 0 || v.dy != 0 else {
            if joystickTouching {
                client?.touch([finger(id, centre, down: false)])
                joystickTouching = false
            }
            return
        }
        let len = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        v = CGVector(dx: v.dx / len, dy: v.dy / len)
        var r = (c.radius ?? 0.12) * deviceSize.height
        if let boost = c.boostKey, held.contains(boost), up { r *= 1.9 }   // push past the ring = sprint
        let target = CGPoint(x: centre.x + v.dx * r, y: centre.y + v.dy * r)

        // Separate events: updates to the same finger inside one event are merged by
        // Android's multitouch protocol, which would drop the initial press.
        if !joystickTouching {
            client?.touch([finger(id, centre, down: true)])
            joystickTouching = true
        }
        client?.touch([finger(id, target, down: true)])
    }

    /// Moves a camera-drag finger; when it wanders too far it lifts and re-grabs at
    /// the anchor so the drag never runs off the screen.
    private func drag(_ current: CGPoint?, anchor: CGPoint, id: Int32, dx: CGFloat, dy: CGFloat, sensitivity: Double) -> CGPoint {
        let scale = CGFloat(sensitivity) * deviceSize.width / 1920 * 1.2
        // Each step is its own event: several updates to one finger in a single event get
        // merged by Android, which turned "lift, re-grab, move" into a jump back to the anchor.
        var p = current ?? anchor
        if current == nil { client?.touch([finger(id, p, down: true)]) }
        var next = CGPoint(x: p.x + dx * scale, y: p.y + dy * scale)

        // The drag may roam the whole half of the screen the anchor is on (buttons only react
        // to where a touch *starts*); only leaving that area forces a lift and re-grab.
        // A small radius here caused a camera hitch every ~80 ms of fast mouse movement.
        let W = deviceSize.width, H = deviceSize.height
        let area = anchor.x >= W / 2
            ? CGRect(x: W * 0.36, y: H * 0.03, width: W * 0.61, height: H * 0.94)
            : CGRect(x: W * 0.03, y: H * 0.03, width: W * 0.61, height: H * 0.94)
        let outOfRange = !area.contains(next)
        if outOfRange {
            client?.touch([finger(id, p, down: false)])
            p = anchor
            client?.touch([finger(id, p, down: true)])
            next = CGPoint(x: p.x + dx * scale, y: p.y + dy * scale)
        }
        client?.touch([finger(id, next, down: true)])
        return next
    }

    private func liftAim() {
        pendingDX = 0; pendingDY = 0
        if let p = aimFinger {
            client?.touch([finger(Self.aimTouchID, p, down: false)])
            aimFinger = nil
        }
    }

    private func beginLook() {
        liftAim()
        lookHeld = true
    }

    private func endLook() {
        if let p = lookFinger {
            client?.touch([finger(Self.lookTouchID, p, down: false)])
        }
        lookFinger = nil
        lookHeld = false
    }

    /// Esc while a bag/map paused aim: close it (Android Back) and resume aiming.
    /// Returns true if it handled the key.
    func escapeFromPausedMenu() -> Bool {
        guard isActive, aimPausedBy != nil else { return false }
        aimPausedBy = nil
        client?.press(key: "GoBack")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.setAiming(true) }
        return true
    }

    func setAiming(_ on: Bool) {
        log.info("setAiming(\(on)) from aiming=\(self.isAiming)")
        if on { aimPausedBy = nil }
        guard on != isAiming, !on || aimControl != nil else { return }
        isAiming = on
        if !on {
            liftAim()
            endLook()
            // release any mouse-held controls (e.g. fire) that no longer apply
            for input in held where input.isMouse { release(input) }
        }
        onAimingChanged?(on)
    }

    /// Lifts every finger and forgets held keys (focus loss, keymap change).
    func releaseAll() {
        for input in held { release(input) }
        held.removeAll()
        activated.removeAll()
        setAiming(false)
        liftAim()
        endLook()
    }
}
