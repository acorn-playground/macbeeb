import AppKit
import BeebHost

extension KeyboardSettings {
    /// A name for a Mac key, for the settings list.
    static func name(of event: NSEvent) -> String {
        name(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
    }
}

extension KeyboardTranslator.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.capsLock) { insert(.capsLock) }
    }
}
