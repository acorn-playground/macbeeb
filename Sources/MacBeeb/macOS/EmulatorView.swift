import AppKit
import BeebCore
import BeebHost
import MetalKit
import SwiftUI

/// The BBC's screen. Takes keyboard focus and sends keys to the machine.
final class EmulatorNSView: MTKView {
    var host: EmulatorHost?
    var renderer: Renderer?
    /// The path of the disc image in drive 0, whose own keys apply.
    var keyboardDisc: () -> String? = { nil }
    /// Called when the window becomes key.
    var onBecomeKey: () -> Void = {}
    /// Called when its window closes.
    var onClose: () -> Void = {}
    /// Called with the TV pixel under the mouse (nil when it leaves).
    var onHover: ((Int, Int)?) -> Void = { _ in }
    /// Whether it takes the keyboard when it appears (one of several
    /// screens in a window may not).
    var takesFocus = true
    /// Called when it takes the keyboard.
    var onFocus: () -> Void = {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        if mouseCaptured {
            moveMouse(event)
            return
        }
        onHover(tvPixel(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        onHover(nil)
    }

    // MARK: Zoom

    /// Posted (with the host, and the zoom in userInfo) by View > Zoom.
    static let setZoom = MachineWindowEvent.setZoom
    /// The picture's height at 100%: the default window's.
    static let actualHeight: CGFloat = 720
    /// Called with the zoom the picture's at (its height over
    /// `actualHeight`) when the view's resized.
    var onZoom: (Double) -> Void = { _ in }

    /// The picture's size in the view, allowing for the letterboxing.
    private var pictureSize: CGSize {
        let height = min(bounds.height, bounds.width / Renderer.aspect)
        return CGSize(width: height * Renderer.aspect, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // (Not in the middle of SwiftUI's layout.)
        let zoom = pictureSize.height / Self.actualHeight
        DispatchQueue.main.async { [weak self] in self?.onZoom(zoom) }
    }

    /// Resizes the window so the picture is `zoom` times its actual size,
    /// keeping the window's top left where it is (and on the screen).
    @objc private func applyZoom(_ notification: Notification) {
        guard (notification.object as AnyObject?) === host, let zoom = notification.userInfo?["zoom"] as? Double,
              let window else { return }
        // The view fills the window below the toolbar.
        let content = window.contentLayoutRect.size
        var frame = window.frame
        var height = Self.actualHeight * zoom
        if let screen = window.screen?.visibleFrame {
            // As big as fits, if that's less.
            height = min(height, screen.height - (frame.height - content.height),
                         (screen.width - (frame.width - content.width)) / Renderer.aspect)
        }
        let target = CGSize(width: (height * Renderer.aspect).rounded(), height: height.rounded())
        let size = CGSize(width: frame.width + target.width - content.width,
                          height: frame.height + target.height - content.height)
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - frame.width))
            frame.origin.y = max(screen.minY, min(frame.origin.y, screen.maxY - frame.height))
        }
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: The AMX mouse

    /// Posted (with the host) by Machine > Capture Mouse.
    static let toggleMouseCapture = MachineWindowEvent.toggleMouseCapture
    /// Brings the window showing a host (the notification's object) to the
    /// front.
    static let bringToFront = MachineWindowEvent.bringToFront
    /// Forgets the keys held on the Mac: the machine's been replaced (a
    /// quick load), so they've been released on the BBC.
    static let resetKeys = MachineWindowEvent.resetKeys

    @objc private func bringToFront(_ notification: Notification) {
        guard (notification.object as AnyObject?) === host else { return }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }

    @objc private func resetKeys(_ notification: Notification) {
        guard (notification.object as AnyObject?) === host else { return }
        translator.reset()
    }

    /// While captured, the Mac's mouse is the BBC's: the pointer's hidden
    /// and held still, and its movements and buttons go to the machine.
    private(set) var mouseCaptured = false
    /// Movement not yet a whole count.
    private var mouseRemainder = CGPoint.zero
    private var mouseButtons: AMXMouse.Buttons = []

    func setMouseCaptured(_ captured: Bool) {
        guard captured != mouseCaptured else { return }
        mouseCaptured = captured
        mouseRemainder = .zero
        if captured {
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(0)
            window?.subtitle = "Mouse captured: ⌃⌘M releases it"
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            window?.subtitle = ""
            mouseButtons = []
            host?.send(.mouseButtons([]))
        }
    }

    @objc private func toggleMouseCapture(_ notification: Notification) {
        guard (notification.object as AnyObject?) === host else { return }
        setMouseCaptured(!mouseCaptured)
    }

    /// The Mac's movement, in TV pixels, as counts.
    private func moveMouse(_ event: NSEvent) {
        guard let host else { return }
        let mouse = host.mouse
        let scale = CGFloat(EmulatorHost.Frame.width) / max(1, displayedWidth) / CGFloat(mouse.tvPixelsPerCount)
        // (AppKit's deltaY is positive moving down, as the BBC's is.)
        let x = mouseRemainder.x + event.deltaX * scale
        let y = mouseRemainder.y + event.deltaY * scale
        let dx = Int(x.rounded(.towardZero)), dy = Int(y.rounded(.towardZero))
        mouseRemainder = CGPoint(x: x - CGFloat(dx), y: y - CGFloat(dy))
        if dx != 0 || dy != 0 {
            host.send(.mouseMove(dx: dx, dy: dy))
        }
    }

    /// The width the picture's drawn at, allowing for the letterboxing.
    private var displayedWidth: CGFloat {
        min(bounds.width, bounds.height * Renderer.aspect)
    }

    private func setButton(_ button: AMXMouse.Buttons, down: Bool) {
        if down { mouseButtons.insert(button) } else { mouseButtons.remove(button) }
        host?.send(.mouseButtons(mouseButtons))
    }

    override func mouseDown(with event: NSEvent) {
        if mouseCaptured {
            setButton(.left, down: true)
        } else if host?.mouse.inUse == true {
            // The software's reading the mouse: a click hands it over.
            setMouseCaptured(true)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseCaptured { setButton(.left, down: false) } else { super.mouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if mouseCaptured { setButton(.right, down: true) } else { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if mouseCaptured { setButton(.right, down: false) } else { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if mouseCaptured { setButton(.middle, down: true) } else { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if mouseCaptured { setButton(.middle, down: false) } else { super.otherMouseUp(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseCaptured { moveMouse(event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if mouseCaptured { moveMouse(event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if mouseCaptured { moveMouse(event) }
    }

    /// The TV pixel at a point in the view, allowing for the letterboxing.
    func tvPixel(at point: CGPoint) -> (Int, Int)? {
        let size = bounds.size
        var width = size.width, height = size.width / Renderer.aspect
        if height > size.height {
            height = size.height
            width = height * Renderer.aspect
        }
        let u = (point.x - (size.width - width) / 2) / width
        let v = 1 - (point.y - (size.height - height) / 2) / height
        guard (0..<1).contains(u), (0..<1).contains(v) else { return nil }
        return (Int(u * CGFloat(EmulatorHost.Frame.width)), Int(v * CGFloat(EmulatorHost.Frame.height)))
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        // Keys held down here mustn't stay down on the BBC.
        translator.reset()
        host?.send(.releaseAllKeys)
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if takesFocus {
            window?.makeFirstResponder(self)
        }
        updateTranslator()
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                               name: NSWindow.willCloseNotification, object: window)
        if window?.isKeyWindow == true {
            onBecomeKey()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(toggleMouseCapture),
                                               name: Self.toggleMouseCapture, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyZoom),
                                               name: Self.setZoom, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(bringToFront),
                                               name: Self.bringToFront, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetKeys),
                                               name: Self.resetKeys, object: nil)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        onClose()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        setMouseCaptured(false)
        translator.reset()
        host?.send(.releaseAllKeys)
    }

    /// Rebuilt when the settings change (see `updateTranslator`).
    private var translator = KeyboardSettings.shared.translator()

    /// Picks up keyboard settings changes, and a change of disc; keys held
    /// across a change still release properly.
    func updateTranslator() {
        let settings = KeyboardSettings.shared
        withObservationTracking {
            translator.mode = settings.mode
            translator.customKeys = settings.translator(disc: keyboardDisc()).customKeys
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateTranslator() }
        }
    }

    private func perform(_ actions: [KeyboardTranslator.Action]) {
        for action in actions {
            switch action {
            case .key(let key, let down):
                host?.send(.key(key, down: down))
            case .tapCapsLock:
                host?.send(.key(.capsLock, down: true))
                let host = self.host
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    host?.send(.key(.capsLock, down: false))
                }
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        // Command combinations belong to the menus.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        perform(translator.keyDown(keyCode: event.keyCode, characters: event.characters,
                                   modifiers: .init(event.modifierFlags), isRepeat: event.isARepeat))
    }

    override func keyUp(with event: NSEvent) {
        perform(translator.keyUp(keyCode: event.keyCode))
    }

    override func flagsChanged(with event: NSEvent) {
        perform(translator.flagsChanged(keyCode: event.keyCode, modifiers: .init(event.modifierFlags)))
    }
}

struct EmulatorView: NSViewRepresentable {
    let host: EmulatorHost
    let style: DisplayStyle
    let monitor: Monitor
    /// Called with the renderer once it exists.
    var onRenderer: (Renderer) -> Void = { _ in }
    var onHover: ((Int, Int)?) -> Void = { _ in }
    var onZoom: (Double) -> Void = { _ in }
    var keyboardDisc: () -> String? = { nil }
    var onBecomeKey: () -> Void = {}
    var onClose: () -> Void = {}
    var takesFocus = true
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> EmulatorNSView {
        let device = MTLCreateSystemDefaultDevice()
        let view = EmulatorNSView(frame: .zero, device: device)
        view.host = host
        view.onHover = onHover
        view.onZoom = onZoom
        view.keyboardDisc = keyboardDisc
        view.onBecomeKey = onBecomeKey
        view.onClose = onClose
        view.takesFocus = takesFocus
        view.onFocus = onFocus
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 120
        if let device {
            view.renderer = Renderer(device: device, pixelFormat: view.colorPixelFormat, host: host)
        }
        view.delegate = view.renderer
        if let renderer = view.renderer {
            renderer.style = style
            renderer.monitor = monitor
            onRenderer(renderer)
        }
        return view
    }

    func updateNSView(_ view: EmulatorNSView, context: Context) {
        view.renderer?.style = style
        view.renderer?.monitor = monitor
        view.onFocus = onFocus
        if takesFocus && !view.takesFocus, let window = view.window, window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
        view.takesFocus = takesFocus
    }
}
