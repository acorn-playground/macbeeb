import BeebCore
import BeebHost
import CGtk
import Foundation
import Observation

private typealias RadioRows = PreferencesUI.RadioRows
private typealias ValuePicker<Value: Equatable> = PreferencesUI.ValuePicker<Value>

/// How PC keys become BBC keys: by position or by character, and custom
/// keys (for all discs, or a disc's own), each recorded by pressing it.
@MainActor
final class KeyboardPreferences {
    let page = PreferencesPage(title: "Keyboard", icon: "input-keyboard-symbolic")
    weak var dialog: PreferencesDialog?
    private let settings = KeyboardSettings.shared

    private let custom = PreferencesGroup(title: "Custom keys")
    private let discs = DiscPicker()
    private let empty = PreferencesUI.MessageRow("")
    private let add: ButtonRow
    private let removeAll = Button("Remove All").style("flat")
    /// The mapping rows shown, in order.
    private var rows: [MappingRow] = []
    /// The disc whose keys are shown (nil: all discs').
    private var shownDisc: String?
    private var recorder: KeyRecorder?
    /// A key just added: its row takes the focus.
    private var added: UInt16?

    init() {
        add = ButtonRow("Add Mapping…", icon: "list-add-symbolic") {}
        let modes = KeyboardMode.allCases
        let keyboard = Platform.keyboardName
        let choices = RadioRows(modes.map { mode in
            (mode.name, mode == .physical
                ? "Each \(keyboard) key is the BBC key in the same place: Shift-8 types “(” as on a BBC. Best for games."
                : "Keys type what the \(keyboard)'s layout says: Shift-8 types “*”. Best for typing. Control, the arrows and function keys still go by position, and Right Alt types characters rather than being Shift Lock.")
        }, selected: modes.firstIndex(of: settings.mode) ?? 0) { [settings] index in
            settings.mode = modes[index]
        }
        let keys = PreferencesGroup(title: "Keys")
        choices.add(to: keys)
        page.add(keys)

        custom.headerSuffix(removeAll)
        custom.add(discs.picker.row)
        custom.add(empty)
        custom.add(add)
        page.add(custom)

        add.object.on("activated") { [self] in startRecording() }
        // (Taken out and put back after the rows as they change: held, so it
        // lasts while it's out.)
        let addRow = gpointer(add.widget)
        g_object_ref(addRow)
        page.onDestroy { g_object_unref(addRow) }
        removeAll.onClicked { [self] in removeAllMappings() }
        page.track { [settings] in choices.set(modes.firstIndex(of: settings.mode) ?? 0) }
        page.track { [self] in update() }
        page.keep(self)
    }

    /// The disc whose keys are showing (nil: all discs').
    private var disc: String? { settings.editingDisc }

    /// Shows the mappings as they are: rows made, or updated in place (so
    /// the focus stays where it is).
    private func update() {
        let disc = disc
        let mappings = settings.mappings(for: disc)
        let sameRows = disc == shownDisc && rows.map(\.keyCode) == mappings.map(\.keyCode)
            && rows.map(\.name) == mappings.map(\.macKeyName)
        if sameRows {
            for (row, mapping) in zip(rows, mappings) {
                row.picker.select(mapping.key)
            }
        } else {
            for row in rows {
                custom.remove(row.picker.row)
            }
            custom.remove(add)
            shownDisc = disc
            rows = mappings.map { mapping in
                MappingRow(mapping, disc: disc, settings: settings)
            }
            for row in rows {
                custom.add(row.picker.row)
            }
            custom.add(add)
        }
        empty.isVisible = mappings.isEmpty
        empty.text = disc == nil
            ? "No custom keys. Add one to put any BBC key on any \(Platform.keyboardName) key (it takes priority in both modes)."
            : "No keys for this disc. Keys added here apply while it's in drive 0, on top of the keys for all discs."
        removeAll.isEnabled = !mappings.isEmpty
        if let added, let row = rows.first(where: { $0.keyCode == added }) {
            self.added = nil
            row.picker.row.grabFocus()
        }
    }

    /// Remove All, which a toast can undo.
    private func removeAllMappings() {
        let disc = disc
        let removed = settings.mappings(for: disc)
        guard !removed.isEmpty else { return }
        settings.removeAllMappings(disc: disc)
        dialog?.toast(removed.count == 1 ? "Removed 1 custom key" : "Removed \(removed.count) custom keys", button: "_Undo") {
            [settings] in
            for mapping in removed {
                settings.setMapping(keyCode: mapping.keyCode, macKeyName: mapping.macKeyName, to: mapping.key, disc: disc)
            }
        }
    }

    // MARK: Recording a key

    func startRecording() {
        guard recorder == nil else { return }
        let disc = disc
        let recorder = KeyRecorder { [self] code, name, characters, modifiers in
            // Start from what the key does now, then let the user pick.
            let current = settings.translator(disc: disc).translate(keyCode: code, characters: characters,
                                                                    modifiers: modifiers)?.key ?? .space
            added = code
            settings.setMapping(keyCode: code, macKeyName: name, to: current, disc: disc)
        }
        recorder.onClosed = { [self] in self.recorder = nil }
        self.recorder = recorder
        recorder.present(over: page)
        // `-MacBeebSelfTestPreferencesRecordKey 52`: a window capture's key
        // press (a hardware keycode: 52 is Z), with its own configuration
        // folder (XDG_CONFIG_HOME), as the keys are saved.
        let keycode = UserDefaults.standard.integer(forKey: "MacBeebSelfTestPreferencesRecordKey")
        if LaunchScreen.isSelfTest, keycode > 0,
           ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?.hasPrefix("/tmp") == true {
            MainLoop.after(1) {
                var keyval: guint = 0
                if let display = gdk_display_get_default() {
                    gdk_display_translate_key(display, guint(keycode), GdkModifierType(rawValue: 0), 0, &keyval, nil, nil, nil)
                }
                _ = recorder.handle(keyval: keyval, keycode: UInt32(keycode), state: GdkModifierType(rawValue: 0), layout: 0)
            }
        }
    }

    func stopRecording() {
        recorder?.close()
        recorder = nil
    }
}

/// A custom key: the PC key, the BBC key it is (to choose), and Remove.
@MainActor
private final class MappingRow {
    let keyCode: UInt16
    let name: String
    let picker: ValuePicker<BeebKey>

    init(_ mapping: KeyboardSettings.Mapping, disc: String?, settings: KeyboardSettings) {
        keyCode = mapping.keyCode
        name = mapping.macKeyName
        let keyCode = mapping.keyCode, name = mapping.macKeyName
        picker = ValuePicker(name, searchable: true) { key in
            guard settings.mappings(for: disc).first(where: { $0.keyCode == keyCode })?.key != key else { return }
            settings.setMapping(keyCode: keyCode, macKeyName: name, to: key, disc: disc)
        }
        picker.set(BeebKey.catalogue.map { ($0.name, $0.key) }, selected: mapping.key)
        macbeeb_set_accessible_description(picker.row.widget, "The BBC key it is")
        let remove = Button(icon: "list-remove-symbolic") { settings.removeMapping(keyCode: keyCode, disc: disc) }
            .style("flat", "circular")
            .align(vertical: GTK_ALIGN_CENTER)
            .tooltip("Remove")
            .accessibleLabel("Remove \(name)")
        adw_action_row_add_suffix(cast(picker.row.widget), remove.widget)
    }
}

/// Which settings the keyboard and gamepad pages show: all discs', or a
/// disc image's own (`KeyboardSettings.editingDisc`, shared by both, set by
/// Controls for This Disc…).
@MainActor
final class DiscPicker {
    let picker: PreferencesUI.ValuePicker<String?>

    init() {
        picker = ValuePicker("For") { disc in
            if KeyboardSettings.shared.editingDisc != disc { KeyboardSettings.shared.editingDisc = disc }
        }
        let picker = picker
        picker.row.track {
            let discs = Self.discs
            picker.set([("All discs", nil)] + discs.map { (Self.discName($0), $0) },
                       selected: KeyboardSettings.shared.editingDisc)
        }
    }

    /// Discs to choose from: those in the machines' drive 0, those with
    /// settings of their own, and the one showing.
    static var discs: [String] {
        let settings = KeyboardSettings.shared
        let all = MachineController.all.values.compactMap(\.bootDiscPath) + settings.discMappings.keys
            + GamepadSettings.shared.discConfigs.keys + [settings.editingDisc].compactMap { $0 }
        return Set(all).sorted { discName($0).localizedStandardCompare(discName($1)) == .orderedAscending }
    }

    /// "Elite.ssd (Games)": the image's name and its folder's.
    static func discName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return "\(url.lastPathComponent) (\(url.deletingLastPathComponent().lastPathComponent))"
    }
}

/// Add Mapping…: waits for a key press (any key, modifier keys too, as
/// the Mac's KeyRecorder does), then hands it over by its Mac key code,
/// the BBC's keys being by position. Escape cancels, as in GNOME's own
/// shortcut settings.
@MainActor
final class KeyRecorder {
    typealias Recorded = @MainActor (_ code: UInt16, _ name: String, _ characters: String?,
                                     _ modifiers: KeyboardTranslator.Modifiers) -> Void

    private let dialog: Dialog
    private let problem: Label
    private let recorded: Recorded
    var onClosed: () -> Void = {}

    init(_ recorded: @escaping Recorded) {
        let keyboard = Platform.keyboardName
        let art = Icon("input-keyboard-symbolic", size: 64).style("macbeeb-recorder-key")
        let prompt = Label("Press the \(keyboard) key to map…", style: "title-2").wrap().centred()
        let detail = Label("Then choose the BBC key it becomes. Press Esc to cancel.",
                           style: "dim-label").wrap().centred()
        let problem = Label("", style: "warning").wrap().centred()
        problem.isVisible = false
        self.problem = problem
        let body = Box(.vertical, spacing: 12) {
            art.margin(bottom: 6)
            prompt
            detail
            problem
        }
        .margin(top: 12, bottom: 30, start: 30, end: 30)
        body.focusable(true)
        body.accessibleLabel("Press the \(keyboard) key to map")
        dialog = Dialog(title: "Add Mapping", content: ToolbarView(content: body).top(HeaderBar()), width: 420)
        dialog.focus(body)
        self.recorded = recorded
        let keys = KeyController().phase(GTK_PHASE_CAPTURE)
        let controller = keys.controller
        keys.onPressed { [self] keyval, keycode, state in
            handle(keyval: keyval, keycode: keycode, state: state,
                   layout: gtk_event_controller_get_current_event(controller).map { Int32(gdk_key_event_get_layout($0)) })
        }
        dialog.add(keys)
        dialog.onClosed { [self] in onClosed() }
        dialog.onDestroy { [self] in onClosed() }
        dialog.keep(self)
    }

    func present(over widget: Widget) {
        dialog.present(over: widget)
    }

    /// A key pressed (`layout`: the keyboard layout it was pressed in):
    /// true when it's taken.
    func handle(keyval: UInt32, keycode: UInt32, state: GdkModifierType, layout: Int32?) -> Bool {
        // Escape (alone) cancels: the dialog's own shortcut.
        let modifiers = GDK_SHIFT_MASK.rawValue | GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue
        if keyval == UInt32(GDK_KEY_Escape) && state.rawValue & modifiers == 0 {
            return false
        }
        guard let code = LinuxKeyMap.macKeyCode(keycode) else {
            say("MacBeeb can’t tell which key that is. Try another.")
            return true
        }
        // Left Alt and Super are the app's (its shortcuts, in a machine
        // window, as Command is on the Mac).
        if code == LinuxKeyMap.reservedForShortcuts || code == 0x37 || code == 0x36 {
            say("Left Alt and Super are for MacBeeb’s own shortcuts, so they can’t be BBC keys. Try another.")
            return true
        }
        let name = Self.name(code: code, keycode: keycode, keyval: keyval, layout: layout)
        let unicode = gdk_keyval_to_unicode(keyval)
        let characters = unicode > 0 && unicode < 0x11_0000 ? UnicodeScalar(unicode).map { String(Character($0)) } : nil
        recorded(code, name, characters, PreferencesUI.modifiers(state))
        dialog.close()
        return true
    }

    func close() {
        dialog.close()
    }

    private func say(_ text: String) {
        problem.text = text
        problem.isVisible = true
        macbeeb_announce(problem.widget, text)
        gtk_widget_error_bell(problem.widget)
    }

    /// The key's name for the list: as a PC's keycap has it where the Mac's
    /// differs, else as the Mac app names it (by key code, or the character
    /// it types without modifiers).
    static func name(code: UInt16, keycode: UInt32, keyval: UInt32, layout: Int32?) -> String {
        if keycode >= 8, let name = pcNames[UInt16(keycode - 8)] {
            return name
        }
        // What it types without modifiers: in the layout it was pressed in,
        // else (lower case) what it typed.
        var plain = gdk_keyval_to_lower(keyval)
        if let layout, let display = gdk_display_get_default() {
            var translated: guint = 0
            if gdk_display_translate_key(display, keycode, GdkModifierType(rawValue: 0), layout, &translated, nil, nil, nil) != 0 {
                plain = translated
            }
        }
        let unicode = gdk_keyval_to_unicode(plain)
        var characters: String?
        if unicode > 0x20, unicode < 0x11_0000, let scalar = UnicodeScalar(unicode) {
            characters = String(Character(scalar))
        }
        return KeyboardSettings.name(keyCode: code, characters: characters)
    }

    /// PC keys whose Mac names would be wrong on a PC (Delete is the PC's
    /// Backspace; Help, its Insert), by evdev code.
    static let pcNames: [UInt16: String] = [
        14: "Backspace", 111: "Delete", 110: "Insert", 69: "Num Lock",
        56: "Left Alt", 100: "Right Alt", 125: "Super", 126: "Right Super",
        99: "Print Screen", 70: "Scroll Lock", 119: "Pause", 29: "Control", 97: "Right Control",
    ]
}
