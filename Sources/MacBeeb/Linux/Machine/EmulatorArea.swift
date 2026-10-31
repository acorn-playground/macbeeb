import BeebCore
import BeebHost
import CGtk
import Foundation
import Observation

/// The BBC's screen: draws the machine's frames, takes the keyboard and
/// sends keys to the machine, and hands the mouse to the AMX mouse. (The
/// Mac's is EmulatorNSView.)
@MainActor
final class EmulatorArea {
    let area = GLArea()
    let host: EmulatorHost
    let renderer: Renderer

    /// The path of the disc image in drive 0, whose own keys apply.
    var keyboardDisc: () -> String? = { nil }
    /// Called with the TV pixel under the mouse (nil when it leaves).
    var onHover: ((Int, Int)?) -> Void = { _ in }
    /// Called with the zoom the picture's at when it's resized.
    var onZoom: (Double) -> Void = { _ in }
    /// Called when it takes the keyboard.
    var onFocus: () -> Void = {}
    /// Called when the mouse is captured or released, with what to say.
    var onMouseCapture: (Bool) -> Void = { _ in }

    /// The picture's height at 100% (the Mac's, in points).
    static let actualHeight = 720.0

    private var observers: [NSObjectProtocol] = []

    init(host: EmulatorHost) {
        self.host = host
        renderer = Renderer(host: host)
        area.focusable(true).expand()
        gtk_widget_set_can_focus(area.widget, 1)
        area.size(width: 368, height: 288)

        area.onRealize { [weak self] in
            guard let self else { return }
            self.area.makeCurrent()
            if let error = self.area.errorMessage {
                NSLog("MacBeeb: no OpenGL: \(error)")
                return
            }
            self.renderer.setUp()
        }
        area.onUnrealize { [weak self] in
            guard let self else { return }
            self.area.makeCurrent()
            self.renderer.tearDown()
        }
        area.onRender { [weak self] in
            guard let self else { return false }
            let scale = self.area.scale
            self.renderer.draw(width: self.area.width * scale, height: self.area.height * scale)
            return true
        }
        area.onResize { [weak self] _, _ in
            guard let self else { return }
            let zoom = self.pictureSize.height / Self.actualHeight
            MainLoop.after(0) { self.onZoom(zoom) }
        }
        // A new frame drawn on the display's own clock (as the Mac's view
        // draws at the display's rate); nothing's drawn while it's still.
        area.onTick { [weak self] _ in
            guard let self else { return false }
            if self.renderer.hasNewFrame {
                self.area.queueRender()
            }
            return true
        }

        setUpKeyboard()
        setUpMouse()
        updateTranslator()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: MachineWindowEvent.toggleMouseCapture, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender == ObjectIdentifier(self.host) else { return }
                self.setMouseCaptured(!self.mouseCaptured)
            }
        })
        observers.append(center.addObserver(forName: MachineWindowEvent.resetKeys, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender == ObjectIdentifier(self.host) else { return }
                self.translator.reset()
            }
        })
        area.onDestroy { [observers] in
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }

    /// Redraws now (a display setting changed).
    func redraw() {
        area.queueRender()
    }

    /// The picture's size in the area, allowing for the letterboxing.
    var pictureSize: (width: Double, height: Double) {
        let width = Double(area.width), height = Double(area.height)
        let pictureHeight = min(height, width / Renderer.aspect)
        return (pictureHeight * Renderer.aspect, pictureHeight)
    }

    /// The TV pixel at a point in the area, allowing for the letterboxing.
    func tvPixel(x: Double, y: Double) -> (Int, Int)? {
        let width = Double(area.width), height = Double(area.height)
        var pictureWidth = width, pictureHeight = width / Renderer.aspect
        if pictureHeight > height {
            pictureHeight = height
            pictureWidth = pictureHeight * Renderer.aspect
        }
        let u = (x - (width - pictureWidth) / 2) / pictureWidth
        let v = (y - (height - pictureHeight) / 2) / pictureHeight
        guard (0..<1).contains(u), (0..<1).contains(v) else { return nil }
        return (Int(u * Double(EmulatorHost.Frame.width)), Int(v * Double(EmulatorHost.Frame.height)))
    }

    // MARK: The keyboard

    /// Rebuilt when the settings change (see `updateTranslator`).
    private var translator = KeyboardSettings.shared.translator()
    /// Keys held, by hardware code, as Mac key codes (a release needs the
    /// same code as its press, whatever's happened since).
    private var heldKeys: [UInt32: UInt16] = [:]

    /// Picks up keyboard settings changes, and a change of disc; keys held
    /// across a change still release properly.
    func updateTranslator() {
        let settings = KeyboardSettings.shared
        withObservationTracking {
            translator.mode = settings.mode
            translator.customKeys = settings.translator(disc: keyboardDisc()).customKeys
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateTranslator() } }
        }
    }

    /// Right Alt's held: it's the BBC's Shift Lock, not a shortcut key.
    private var rightAltHeld = false

    /// Whether a key press with these modifiers is the app's (a shortcut),
    /// not the BBC's: Alt (Left Alt: MacBeeb's Command key) or Super held,
    /// or F11 (full screen).
    private func isShortcut(keyval: UInt32, state: GdkModifierType) -> Bool {
        let alt = state.rawValue & GDK_ALT_MASK.rawValue != 0 && !rightAltHeld
        return alt || state.rawValue & GDK_SUPER_MASK.rawValue != 0 || keyval == UInt32(GDK_KEY_F11)
    }

    private func setUpKeyboard() {
        let keys = KeyController()
        keys.onPressed { [weak self] keyval, keycode, state in
            guard let self else { return false }
            return self.keyDown(keyval: keyval, keycode: keycode, state: state)
        }
        keys.onReleased { [weak self] _, keycode, state in
            self?.keyUp(keycode: keycode, state: state)
        }
        area.add(keys)
        let focus = FocusController()
        focus.onEnter { [weak self] in self?.onFocus() }
        focus.onLeave { [weak self] in
            // Keys held down here mustn't stay down on the BBC.
            self?.releaseAll()
        }
        area.add(focus)
    }

    /// Lets go of everything (focus went elsewhere).
    func releaseAll() {
        translator.reset()
        heldKeys = [:]
        rightAltHeld = false
        host.send(.releaseAllKeys)
    }

    private func modifiers(_ state: GdkModifierType) -> KeyboardTranslator.Modifiers {
        var modifiers: KeyboardTranslator.Modifiers = []
        if state.rawValue & GDK_SHIFT_MASK.rawValue != 0 { modifiers.insert(.shift) }
        if state.rawValue & GDK_CONTROL_MASK.rawValue != 0 { modifiers.insert(.control) }
        if state.rawValue & GDK_ALT_MASK.rawValue != 0 { modifiers.insert(.option) }
        if state.rawValue & GDK_SUPER_MASK.rawValue != 0 { modifiers.insert(.command) }
        if state.rawValue & GDK_LOCK_MASK.rawValue != 0 { modifiers.insert(.capsLock) }
        return modifiers
    }

    /// The modifier a modifier key is.
    private func flag(_ code: UInt16) -> KeyboardTranslator.Modifiers {
        switch code {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        case 0x37, 0x36: .command
        case MacKeyMap.capsLock: .capsLock
        default: .option
        }
    }

    /// MACBEEB_DEBUG_KEYS=1 logs the keys the screen hears.
    private static let debugKeys = ProcessInfo.processInfo.environment["MACBEEB_DEBUG_KEYS"] != nil

    private func keyDown(keyval: UInt32, keycode: UInt32, state: GdkModifierType) -> Bool {
        if Self.debugKeys {
            print("key down: keyval \(keyval) keycode \(keycode) state \(state.rawValue) -> \(LinuxKeyMap.macKeyCode(keycode).map { String($0, radix: 16) } ?? "none")")
        }
        if mouseCaptured, keyval == UInt32(GDK_KEY_Escape), state.rawValue & GDK_ALT_MASK.rawValue != 0 {
            setMouseCaptured(false)
            return true
        }
        guard let code = LinuxKeyMap.macKeyCode(keycode) else { return false }
        // Left Alt, and Super, are the app's.
        if code == LinuxKeyMap.reservedForShortcuts || code == 0x37 || code == 0x36 { return false }
        // Shortcuts belong to the menus.
        if !LinuxKeyMap.modifierKeys.contains(code), isShortcut(keyval: keyval, state: state) { return false }
        if LinuxKeyMap.modifierKeys.contains(code) {
            guard heldKeys[keycode] == nil else { return true }
            heldKeys[keycode] = code
            if code == 0x3D { rightAltHeld = true }
            // (GDK's state is as it was before this key.)
            perform(translator.flagsChanged(keyCode: code, modifiers: modifiers(state).union(flag(code))))
            return true
        }
        let unicode = gdk_keyval_to_unicode(keyval)
        let characters = unicode > 0 && unicode < 0x11_0000 ? UnicodeScalar(unicode).map { String(Character($0)) } : nil
        heldKeys[keycode] = code
        perform(translator.keyDown(keyCode: code, characters: characters, modifiers: modifiers(state), isRepeat: false))
        return true
    }

    private func keyUp(keycode: UInt32, state: GdkModifierType) {
        if Self.debugKeys { print("key up: keycode \(keycode)") }
        guard let code = heldKeys.removeValue(forKey: keycode) else { return }
        if code == 0x3D { rightAltHeld = false }
        if LinuxKeyMap.modifierKeys.contains(code) {
            // Caps Lock's a toggle: its press tapped the BBC's.
            guard code != MacKeyMap.capsLock else { return }
            perform(translator.flagsChanged(keyCode: code, modifiers: modifiers(state).subtracting(flag(code))))
            return
        }
        perform(translator.keyUp(keyCode: code))
    }

    private func perform(_ actions: [KeyboardTranslator.Action]) {
        if Self.debugKeys { print("actions: \(actions)") }
        for action in actions {
            switch action {
            case .key(let key, let down):
                host.send(.key(key, down: down))
            case .tapCapsLock:
                host.send(.key(.capsLock, down: true))
                let host = self.host
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    host.send(.key(.capsLock, down: false))
                }
            }
        }
    }

    // MARK: The AMX mouse

    /// While captured, the computer's mouse is the BBC's: the pointer's
    /// hidden, and its movements and buttons go to the machine.
    private(set) var mouseCaptured = false
    /// Movement not yet a whole count.
    private var mouseRemainder = (x: 0.0, y: 0.0)
    private var lastPointer: (x: Double, y: Double)?
    private var mouseButtons: AMXMouse.Buttons = []

    func setMouseCaptured(_ captured: Bool) {
        guard captured != mouseCaptured else { return }
        mouseCaptured = captured
        mouseRemainder = (0, 0)
        lastPointer = nil
        if captured {
            area.cursor("none")
            area.grabFocus()
        } else {
            area.cursor(nil)
            mouseButtons = []
            host.send(.mouseButtons([]))
        }
        onMouseCapture(captured)
    }

    private func setUpMouse() {
        let motion = MotionController()
        motion.onMotion { [weak self] x, y in
            guard let self else { return }
            if self.mouseCaptured {
                self.moveMouse(x: x, y: y)
            } else {
                self.onHover(self.tvPixel(x: x, y: y))
            }
        }
        motion.onLeave { [weak self] in
            guard let self else { return }
            self.lastPointer = nil
            if !self.mouseCaptured { self.onHover(nil) }
        }
        area.add(motion)

        let clicks = ClickGesture(button: 0)
        clicks.onPressed { [weak self, weak clicks] _, x, y in
            guard let self, let clicks else { return }
            self.area.grabFocus()
            let button = clicks.currentButton
            if self.mouseCaptured {
                self.setButton(button, down: true)
            } else if button == 1, self.host.mouse.inUse {
                // The software's reading the mouse: a click hands it over.
                self.setMouseCaptured(true)
                self.lastPointer = (x, y)
            }
        }
        clicks.onReleased { [weak self, weak clicks] _, _, _ in
            guard let self, let clicks, self.mouseCaptured else { return }
            self.setButton(clicks.currentButton, down: false)
        }
        area.add(clicks)
        area.keep(clicks)
    }

    private func setButton(_ button: UInt32, down: Bool) {
        let which: AMXMouse.Buttons = switch button {
        case 1: .left
        case 2: .middle
        default: .right
        }
        if down { mouseButtons.insert(which) } else { mouseButtons.remove(which) }
        host.send(.mouseButtons(mouseButtons))
    }

    /// The pointer's movement, in TV pixels, as counts. (GTK can't hold
    /// the pointer still on Wayland, so it's followed while it's over the
    /// picture.)
    private func moveMouse(x: Double, y: Double) {
        defer { lastPointer = (x, y) }
        guard let last = lastPointer else { return }
        let mouse = host.mouse
        let scale = Double(EmulatorHost.Frame.width) / max(1, pictureSize.width) / mouse.tvPixelsPerCount
        let mx = mouseRemainder.x + (x - last.x) * scale
        let my = mouseRemainder.y + (y - last.y) * scale
        let dx = Int(mx.rounded(.towardZero)), dy = Int(my.rounded(.towardZero))
        mouseRemainder = (mx - Double(dx), my - Double(dy))
        if dx != 0 || dy != 0 {
            host.send(.mouseMove(dx: dx, dy: dy))
        }
    }
}
