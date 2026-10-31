import BeebCore
import BeebHost
import CGtk
import Foundation
import Observation

// What the preferences and the welcome screen build with, beyond the GTK
// layer's widgets: radio rows, combo rows kept in step with state, and
// their styles.

/// The styles the preferences and the welcome screen add to the app's.
@MainActor
enum PreferencesStyles {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }

    /// An accent colour for a part of a window (its buttons, its icons):
    /// one of libadwaita's.
    private static func accent(_ name: String) -> String {
        """
        --accent-bg-color: var(--accent-\(name));
        --accent-fg-color: white;
        --accent-color: oklab(from var(--accent-bg-color) var(--standalone-color-oklab));
        """
    }

    private static var css: String {
        """
        /* Preferences: a gamepad button held, as the Mac's shows it in bold. */
        row.macbeeb-held label.title { font-weight: 800; color: var(--accent-color); }
        .macbeeb-footnote { margin-top: 12px; }
        .macbeeb-empty-row { padding: 14px 12px; }
        .macbeeb-recorder-key { color: var(--accent-color); }

        /* The welcome screen: a glow of the BBC's colours behind it all. */
        .macbeeb-welcome {
            background-color: var(--window-bg-color);
            background-image:
                radial-gradient(circle 560px at 4% 0%, alpha(#e01b24, 0.16), transparent),
                radial-gradient(circle 600px at 100% 14%, alpha(#33c7de, 0.12), transparent),
                radial-gradient(circle 640px at 50% 112%, alpha(#f6d32d, 0.08), transparent);
        }
        .macbeeb-welcome-title { font-size: 46pt; font-weight: 900; letter-spacing: -1px; }
        .macbeeb-welcome-blurb { font-size: 13pt; }
        .macbeeb-welcome-card {
            border-radius: 18px; padding: 16px;
            background-color: var(--card-bg-color);
            border: 1px solid color-mix(in srgb, var(--accent-bg-color) 45%, transparent);
            box-shadow: 0 1px 4px color-mix(in srgb, black 8%, transparent);
            transition: box-shadow 200ms ease-out, border-color 200ms ease-out;
        }
        .macbeeb-welcome-card:hover {
            border-color: color-mix(in srgb, var(--accent-bg-color) 90%, transparent);
            box-shadow: 0 0 22px color-mix(in srgb, var(--accent-bg-color) 30%, transparent);
        }
        .macbeeb-welcome-card.machine, .macbeeb-welcome-tile.red { \(accent("red")) }
        .macbeeb-welcome-card.games, .macbeeb-welcome-tile.orange { \(accent("orange")) }
        .macbeeb-welcome-card.network, .macbeeb-welcome-tile.teal { \(accent("teal")) }
        .macbeeb-welcome-tile.purple { \(accent("purple")) }
        .macbeeb-welcome-tile.green { \(accent("green")) }
        .macbeeb-welcome-tile.pink { \(accent("pink")) }
        .macbeeb-welcome-tile.blue { \(accent("blue")) }
        .macbeeb-welcome-icon { color: var(--accent-color); }
        .macbeeb-welcome-art { border-radius: 12px; }
        .macbeeb-welcome-art.machine {
            background-image: linear-gradient(to bottom right, alpha(#e01b24, 0.34), alpha(#e01b24, 0.07));
        }
        .macbeeb-welcome-art.games {
            background-image: linear-gradient(to bottom right, alpha(#f6d32d, 0.32), alpha(#ff7800, 0.06));
        }
        .macbeeb-welcome-art.network {
            background-image: linear-gradient(to bottom right, alpha(#33c7de, 0.26), alpha(#3584e4, 0.05));
        }
        .macbeeb-welcome-chip {
            font-size: smaller; font-weight: 700; padding: 3px 8px; border-radius: 99px;
            background-color: color-mix(in srgb, currentColor 13%, transparent);
        }
        button.macbeeb-welcome-tile { padding: 12px; border-radius: 12px; }
        .macbeeb-welcome-tile-title { font-weight: 700; font-size: 10.5pt; }
        .macbeeb-welcome-badge {
            font-size: smaller; font-weight: 800; padding: 2px 8px; border-radius: 99px;
            background-color: var(--accent-bg-color); color: var(--accent-fg-color);
        }
        """
    }
}

/// The preferences' and the welcome screen's own pieces (in a namespace,
/// beside the other windows' work).
@MainActor
enum PreferencesUI {
    /// When MacBeeb opens, show…: the setting (`LaunchScreen.preference`),
    /// observable, so the welcome screen and Preferences show it alike.
    @MainActor @Observable
    final class LaunchSetting {
        static let shared = LaunchSetting()

        var value = LaunchScreen.preference {
            didSet {
                if value != oldValue { LaunchScreen.preference = value }
            }
        }
    }

    /// A choice of a few, as rows with radio buttons: GNOME's way with a
    /// handful of options (the Mac's radio-group pickers).
    @MainActor
    final class RadioRows {
        let rows: [ActionRow]
        private let buttons: [Widget]
        private var updating = false

        init(_ options: [(title: String, subtitle: String?)], selected: Int, _ changed: @escaping @MainActor (Int) -> Void) {
            var rows: [ActionRow] = [], buttons: [Widget] = []
            for option in options {
                let check = Widget(gtk_check_button_new())
                check.align(vertical: GTK_ALIGN_CENTER).accessibleLabel(option.title)
                if let first = buttons.first {
                    gtk_check_button_set_group(cast(check.widget), cast(first.widget))
                }
                let row = ActionRow(option.title, subtitle: option.subtitle)
                row.prefix(check).activates(check)
                rows.append(row)
                buttons.append(check)
            }
            self.rows = rows
            self.buttons = buttons
            set(selected)
            for (index, check) in buttons.enumerated() {
                let pointer = check.widget
                // (The widget keeps this, and so the rows' state.)
                check.object.on("toggled") { [self] in
                    guard !updating, gtk_check_button_get_active(cast(pointer)) != 0 else { return }
                    changed(index)
                }
            }
        }

        var selected: Int {
            buttons.firstIndex { gtk_check_button_get_active(cast($0.widget)) != 0 } ?? -1
        }

        /// Shows `index` chosen (without calling back).
        func set(_ index: Int) {
            guard buttons.indices.contains(index), selected != index else { return }
            updating = true
            gtk_check_button_set_active(cast(buttons[index].widget), 1)
            updating = false
        }

        func add(to group: PreferencesGroup) {
            rows.forEach(group.add)
        }
    }

    /// A combo row choosing one of some values, kept in step with the state
    /// it shows (setting it from the state doesn't call back).
    @MainActor
    final class ValuePicker<Value: Equatable> {
        let row: ComboRow
        private(set) var values: [Value] = []
        private var updating = false

        init(_ title: String, subtitle: String? = nil, searchable: Bool = false,
             _ changed: @escaping @MainActor (Value) -> Void) {
            row = ComboRow(title, subtitle: subtitle, items: [])
            macbeeb_preferences_combo_row_full_labels(cast(row.widget))
            if searchable {
                macbeeb_preferences_combo_row_searchable(cast(row.widget))
            }
            row.object.onChange("selected") { [self] in
                guard !updating else { return }
                let index = row.selected
                if values.indices.contains(index) { changed(values[index]) }
            }
        }

        /// The choices, and which is chosen.
        func set(_ choices: [(title: String, value: Value)], selected: Value) {
            updating = true
            defer { updating = false }
            values = choices.map(\.value)
            row.setItems(choices.map(\.title), selected: values.firstIndex(of: selected) ?? 0)
        }

        func select(_ value: Value) {
            guard let index = values.firstIndex(of: value) else { return }
            updating = true
            row.selected = index
            updating = false
        }

        var selected: Value? {
            values.indices.contains(row.selected) ? values[row.selected] : nil
        }
    }

    /// Text under a group's rows, explaining them (the Mac's forms' callouts).
    static func footnote(_ text: String) -> Label {
        Label(text, style: "dim-label", "macbeeb-footnote").wrap()
    }

    /// A row in a list that just says something (that the list is empty, say).
    @MainActor
    final class MessageRow: Widget {
        let label: Label

        init(_ text: String) {
            label = Label(text, style: "dim-label", "macbeeb-empty-row").wrap().centred()
            super.init(cast(adw_preferences_row_new()!) as WidgetPointer)
            gtk_list_box_row_set_child(cast(widget), label.widget)
            gtk_list_box_row_set_activatable(cast(widget), 0)
            gtk_list_box_row_set_selectable(cast(widget), 0)
            adw_preferences_row_set_title(cast(widget), text)
        }

        var text: String {
            get { label.text }
            set {
                label.text = newValue
                adw_preferences_row_set_title(cast(widget), newValue)
            }
        }
    }

    /// A command taking a string: the action of a menu whose items each name
    /// their own (a recent network's path, a saved machine's ID).
    static func addStringAction(to window: Window, _ name: String, _ body: @escaping @MainActor (String) -> Void) {
        let action = g_simple_action_new(name, macbeeb_variant_type_string())!
        GObjectRef(action).onPointer("activate") { parameter in
            guard let parameter else { return }
            body(String(cString: g_variant_get_string(OpaquePointer(parameter), nil)))
        }
        // (The window's, and gone with it.)
        g_action_map_add_action(OpaquePointer(window.widget), action)
        g_object_unref(gpointer(action))
    }

    /// Whether the desktop wants animations (GNOME's Reduce Animation
    /// setting off).
    static var animationsEnabled: Bool {
        guard let settings = gtk_settings_get_default() else { return true }
        return macbeeb_get_bool(gpointer(settings), "gtk-enable-animations") != 0
    }

    /// Narrower than `condition` ("max-width: 900sp"), `setup` changes the
    /// window (through the breakpoint's setters).
    static func addBreakpoint(to window: Window, _ condition: String, _ setup: (OpaquePointer) -> Void) {
        guard let breakpoint = macbeeb_breakpoint(condition) else { return }
        setup(breakpoint)
        adw_application_window_add_breakpoint(cast(window.widget), breakpoint)
    }

    /// GDK's modifier state, as the keyboard translator wants it (as
    /// EmulatorArea reads it).
    static func modifiers(_ state: GdkModifierType) -> KeyboardTranslator.Modifiers {
        var modifiers: KeyboardTranslator.Modifiers = []
        if state.rawValue & GDK_SHIFT_MASK.rawValue != 0 { modifiers.insert(.shift) }
        if state.rawValue & GDK_CONTROL_MASK.rawValue != 0 { modifiers.insert(.control) }
        if state.rawValue & GDK_ALT_MASK.rawValue != 0 { modifiers.insert(.option) }
        if state.rawValue & GDK_SUPER_MASK.rawValue != 0 { modifiers.insert(.command) }
        if state.rawValue & GDK_LOCK_MASK.rawValue != 0 { modifiers.insert(.capsLock) }
        return modifiers
    }
}
