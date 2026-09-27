import AppKit
import MetalKit
import UniformTypeIdentifiers

/// Shows the Android screen (Metal, straight from the shared-memory frame buffer)
/// and turns Mac input into touches / keys / keymap actions.
final class ScreenView: MTKView {
    var client: EmulatorClient?
    var engine: KeymapEngine!
    let overlay = KeymapOverlayView()

    /// Size of the picture as shown (already rotated by the emulator).
    private(set) var deviceSize = CGSize(width: 1920, height: 1080)
    /// Quarter turns of the current picture; touches must be sent in the unrotated space.
    private(set) var quarterTurns = 0
    var onDeviceSizeChanged: ((CGSize) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
    var onAimHint: ((Bool) -> Void)?

    private var renderer: Renderer!
    private var hasFrame = false
    private let frameLock = NSLock()
    private var pendingFrame: Frame?
    private var lastFrame: Frame?
    private var framePresentScheduled = false

    // Normal (unmapped) pointer state
    private var pointerDown = false
    private var scrollFinger: CGPoint?
    private var pinchCenter: CGPoint?
    private var pinchDistance: CGFloat = 0
    private var androidKeysDown = Set<UInt16>()

    private static let pointerID: Int32 = 0
    private static let scrollID: Int32 = 90
    private static let pinchIDs: (Int32, Int32) = (91, 92)

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        super.init(frame: .zero, device: device)
        renderer = Renderer(device: device)
        delegate = renderer
        isPaused = true
        enableSetNeedsDisplay = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        registerForDraggedTypes([.fileURL])
        addSubview(overlay)
    }

    required init(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Aspect-fit rectangle the Android screen occupies inside this view.
    var screenRect: CGRect {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return b }
        let aspect = deviceSize.width / deviceSize.height
        var w = b.width, h = b.width / aspect
        if h > b.height { h = b.height; w = h * aspect }
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h).integral
    }

    override func layout() {
        super.layout()
        overlay.frame = screenRect
        renderer.viewport = screenRect
        renderer.viewSize = bounds.size
        if hasFrame { draw() }
    }

    // MARK: Frames

    /// Called from the gRPC stream for every new frame (any thread). Coalesces to one
    /// main-thread present at a time so slow draws never queue up.
    func frameArrived(_ frame: Frame) {
        frameLock.lock()
        pendingFrame = frame
        let schedule = !framePresentScheduled
        framePresentScheduled = true
        frameLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in self?.presentPendingFrame() }
    }

    private func presentPendingFrame() {
        frameLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        framePresentScheduled = false
        frameLock.unlock()
        guard let frame else { return }

        let size = CGSize(width: frame.width, height: frame.height)
        quarterTurns = frame.quarterTurns
        if size != deviceSize {
            deviceSize = size
            engine.deviceSize = size
            overlay.deviceSize = size
            needsLayout = true
            onDeviceSizeChanged?(size)
        }
        frame.pixels.withUnsafeBytes { renderer.upload($0.baseAddress!, width: frame.width, height: frame.height) }
        lastFrame = frame
        if !hasFrame {
            hasFrame = true
            layoutSubtreeIfNeeded()
            onFirstFrame?()
        }
        draw()
    }

    /// Forget the previous emulator's frames (after Android restarts).
    func resetForNewSession() {
        hasFrame = false
        lastFrame = nil
        pointerDown = false
        scrollFinger = nil
        androidKeysDown.removeAll()
    }

    /// Current frame as an image (for screenshots).
    func snapshotImage() -> CGImage? {
        guard let frame = lastFrame else { return nil }
        let w = frame.width, h = frame.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let dst = ctx.data else { return nil }
        frame.pixels.withUnsafeBytes { src in memcpy(dst, src.baseAddress!, w * h * 4) }
        return ctx.makeImage()
    }

    // MARK: Coordinates

    private func devicePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let r = screenRect
        let x = (p.x - r.minX) / r.width * deviceSize.width
        let y = (r.maxY - p.y) / r.height * deviceSize.height
        return CGPoint(x: min(max(x, 0), deviceSize.width - 1), y: min(max(y, 0), deviceSize.height - 1))
    }

    /// Maps a point on the shown picture to the emulator's native (unrotated) touch space.
    /// Verified against the emulator for all four rotations.
    func toNative(_ p: CGPoint) -> CGPoint {
        let odd = quarterTurns % 2 == 1
        let nw = odd ? deviceSize.height : deviceSize.width
        let nh = odd ? deviceSize.width : deviceSize.height
        switch quarterTurns {
        case 1: return CGPoint(x: nw - p.y, y: p.x)
        case 2: return CGPoint(x: nw - p.x, y: nh - p.y)
        case 3: return CGPoint(x: p.y, y: nh - p.x)
        default: return p
        }
    }

    private func finger(_ id: Int32, _ p: CGPoint, down: Bool) -> EmuTouch {
        let n = toNative(p)
        return .finger(id, x: Int32(n.x), y: Int32(n.y), down: down)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if engine.press(.mouse(0)) { return }
        pointerDown = true
        client?.touch([finger(Self.pointerID, devicePoint(event), down: true)])
    }

    override func mouseDragged(with event: NSEvent) {
        if engine.isAiming { return }   // handled by the aim monitor
        if pointerDown { client?.touch([finger(Self.pointerID, devicePoint(event), down: true)]) }
    }

    override func mouseUp(with event: NSEvent) {
        if engine.release(.mouse(0)) { return }
        if pointerDown {
            pointerDown = false
            client?.touch([finger(Self.pointerID, devicePoint(event), down: false)])
        }
    }

    override func mouseMoved(with event: NSEvent) {}   // aim movement arrives via the aim monitor

    override func rightMouseDown(with event: NSEvent) { engine.press(.mouse(1)) }
    override func rightMouseUp(with event: NSEvent) { engine.release(.mouse(1)) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDown(with event: NSEvent) { engine.press(.mouse(event.buttonNumber)) }
    override func otherMouseUp(with event: NSEvent) { engine.release(.mouse(event.buttonNumber)) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        if engine.isAiming {
            if event.phase == [] || event.phase == .began, event.scrollingDeltaY != 0 {
                _ = engine.scroll(up: event.scrollingDeltaY > 0)
            }
            return
        }
        if event.hasPreciseScrollingDeltas {
            // Trackpad: a real finger drag, so Android's own scrolling and fling feel native.
            // Momentum events are ignored; Android flings from the release velocity.
            guard event.momentumPhase == [] else { return }
            if event.phase == .began || scrollFinger == nil && event.phase == .changed {
                let p = devicePoint(event)
                scrollFinger = p
                client?.touch([finger(Self.scrollID, p, down: true)])
            }
            if var p = scrollFinger, event.phase == .changed {
                let k = deviceSize.height / max(screenRect.height, 1)
                p.x += event.scrollingDeltaX * k
                p.y += event.scrollingDeltaY * k
                scrollFinger = p
                client?.touch([finger(Self.scrollID, p, down: true)])
            }
            if event.phase == .ended || event.phase == .cancelled, let p = scrollFinger {
                client?.touch([finger(Self.scrollID, p, down: false)])
                scrollFinger = nil
            }
        } else if event.scrollingDeltaY != 0 {
            client?.wheel(dx: 0, dy: event.scrollingDeltaY > 0 ? 120 : -120)
        }
    }

    override func magnify(with event: NSEvent) {
        guard !engine.isAiming else { return }
        let (a, b) = Self.pinchIDs
        switch event.phase {
        case .began:
            pinchCenter = devicePoint(event)
            pinchDistance = deviceSize.height * 0.1
        case .changed:
            pinchDistance = max(20, pinchDistance * (1 + event.magnification))
        default:
            break
        }
        guard let c = pinchCenter else { return }
        let down = !(event.phase == .ended || event.phase == .cancelled)
        client?.touch([finger(a, CGPoint(x: c.x - pinchDistance, y: c.y), down: down),
                       finger(b, CGPoint(x: c.x + pinchDistance, y: c.y), down: down)])
        if !down { pinchCenter = nil }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        let code = event.keyCode
        if code == 53 {   // Escape: leave mouse aim, otherwise Android Back
            if engine.isAiming { engine.setAiming(false) }
            else if !event.isARepeat, !engine.escapeFromPausedMenu() { client?.press(key: "GoBack") }
            return
        }
        if engine.press(.key(code)) { return }
        androidKeysDown.insert(code)
        client?.key(macKeyCode: code, down: true)
    }

    override func keyUp(with event: NSEvent) {
        let code = event.keyCode
        if engine.release(.key(code)) { return }
        if androidKeysDown.remove(code) != nil { client?.key(macKeyCode: code, down: false) }
    }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        guard let flag = InputKey.modifierFlags[code], flag != .command else { return }
        let down = event.modifierFlags.contains(flag)
        if down {
            if engine.press(.key(code)) { return }
            androidKeysDown.insert(code)
            client?.key(macKeyCode: code, down: true)
        } else {
            if engine.release(.key(code)) { return }
            if androidKeysDown.remove(code) != nil { client?.key(macKeyCode: code, down: false) }
        }
    }

    // MARK: Edit menu (⌘X / ⌘C / ⌘V / ⌘A → Android's Ctrl shortcuts)

    var onPaste: (() -> Void)?

    /// Presses Ctrl+<key> in Android (Mac key codes).
    func sendControlShortcut(_ macKeyCode: UInt16) {
        client?.key(macKeyCode: 59, down: true)
        client?.key(macKeyCode: macKeyCode, down: true)
        client?.key(macKeyCode: macKeyCode, down: false)
        client?.key(macKeyCode: 59, down: false)
    }

    @objc func cut(_ sender: Any?) { sendControlShortcut(7) }
    @objc func copy(_ sender: Any?) { sendControlShortcut(8) }
    @objc func paste(_ sender: Any?) { onPaste?() }
    override func selectAll(_ sender: Any?) { sendControlShortcut(0) }

    /// Lifts every finger and key; used when the window loses focus.
    func releaseAllInput() {
        engine.releaseAll()
        if pointerDown { client?.touch([finger(Self.pointerID, .zero, down: false)]); pointerDown = false }
        if let p = scrollFinger { client?.touch([finger(Self.scrollID, p, down: false)]); scrollFinger = nil }
        for code in androidKeysDown { client?.key(macKeyCode: code, down: false) }
        androidKeysDown.removeAll()
    }

    // MARK: Mouse aim cursor

    private var aimMonitor: Any?

    func setCursorCaptured(_ captured: Bool) {
        if let aimMonitor { NSEvent.removeMonitor(aimMonitor); self.aimMonitor = nil }
        if captured {
            // App-wide listener so every movement reaches the aim, whichever view AppKit
            // would otherwise route mouse-moved events to. Consumed so nothing double-counts.
            aimMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
                guard let self, self.engine.isAiming else { return event }
                self.engine.mouseMoved(dx: event.deltaX, dy: event.deltaY)
                return nil
            }
            // Park the hidden cursor over the game so clicks can't land in another app.
            if let window, let screen = window.screen {
                let r = convert(screenRect, to: nil)
                let centerInScreen = window.convertPoint(toScreen: CGPoint(x: r.midX, y: r.midY))
                let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
                CGWarpMouseCursorPosition(CGPoint(x: centerInScreen.x, y: mainHeight - centerInScreen.y))
            }
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    // MARK: Drag & drop APKs

    private func apkURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "apk" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        apkURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = apkURLs(sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }
}

// MARK: - Metal renderer

private final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    var texture: MTLTexture?
    var viewport = CGRect.zero
    var viewSize = CGSize.zero

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vmain(uint vid [[vertex_id]], constant float4 &r [[buffer(0)]]) {
        // r = (x0, y0, x1, y1) in NDC; the frame's first row is the top of the image.
        float2 p[4]  = { float2(r.x, r.y), float2(r.z, r.y), float2(r.x, r.w), float2(r.z, r.w) };
        float2 uv[4] = { float2(0, 1),     float2(1, 1),     float2(0, 0),     float2(1, 0) };
        VOut o; o.pos = float4(p[vid], 0, 1); o.uv = uv[vid]; return o;
    }
    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(t.sample(s, in.uv).rgb, 1);
    }
    """

    init(device: MTLDevice) {
        self.device = device
        queue = device.makeCommandQueue()!
        let lib = try! device.makeLibrary(source: Self.shader, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: sd)!
    }

    func upload(_ bytes: UnsafeRawPointer, width: Int, height: Int) {
        if texture?.width != width || texture?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            texture = device.makeTexture(descriptor: d)
        }
        texture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let texture, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass),
              viewSize.width > 0, viewSize.height > 0 else { return }
        var r = SIMD4<Float>(Float(viewport.minX / viewSize.width * 2 - 1), Float(viewport.minY / viewSize.height * 2 - 1),
                             Float(viewport.maxX / viewSize.width * 2 - 1), Float(viewport.maxY / viewSize.height * 2 - 1))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&r, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
