import BeebCore
import BeebNetwork
import CGtk
import Foundation

// What the Hardware, ROM Library and Machine Configurations windows share:
// their styles, and a few pieces the GTK layer hasn't got.

@MainActor
enum HardwareStyles {
    private static var installed = false

    /// Installs the windows' styles (once), with darker text colours while
    /// libadwaita's dark style is on.
    static func install() {
        guard !installed else { return }
        installed = true
        let display = gdk_display_get_default()
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(display, OpaquePointer(provider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        let dark = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(dark, darkCSS)
        let manager = adw_style_manager_get_default()!
        var added = false
        func follow() {
            let on = adw_style_manager_get_dark(manager) != 0
            guard on != added else { return }
            added = on
            if on {
                gtk_style_context_add_provider_for_display(display, OpaquePointer(dark), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION) + 1)
            } else {
                gtk_style_context_remove_provider_for_display(display, OpaquePointer(dark))
            }
        }
        follow()
        GObjectRef(manager).onChange("dark") { follow() }
    }

    private static let darkCSS = """
    :root {
        --hw-blue-fg: var(--blue-2);
        --hw-green-fg: var(--green-3);
        --hw-purple-fg: var(--purple-2);
    }
    """

    // libadwaita's palette, with text colours that read in light and dark.
    private static let css = """
    :root {
        --hw-blue-fg: var(--blue-4);
        --hw-green-fg: var(--green-5);
        --hw-purple-fg: var(--purple-3);
    }

    .hw-badge {
        padding: 1px 8px;
        border-radius: 999px;
        font-size: 0.83em;
        font-weight: 700;
        font-feature-settings: "tnum";
        color: var(--hw-green-fg);
        background-color: color-mix(in srgb, var(--green-4) 18%, transparent);
    }
    .hw-fitted { color: var(--accent-color); font-size: 0.83em; font-weight: 600; }

    .hw-number { font-size: 1.45em; font-weight: 700; font-feature-settings: "tnum"; min-width: 34px; }
    .hw-number.rom { color: var(--hw-blue-fg); }
    .hw-number.ram { color: var(--hw-green-fg); }
    .hw-number.taken { opacity: 0.45; }

    row.hw-problem label.subtitle { color: var(--warning-color); opacity: 1; }
    row.hw-group-header label.title { font-weight: 700; }
    row.hw-quiet label.title { opacity: 0.55; }
    row.hw-mono label.subtitle { font-family: monospace; font-size: 0.8em; }
    row.hw-note { min-height: 0; }
    row.hw-note label.subtitle { font-size: 0.9em; }
    .hw-note-icon { opacity: 0.55; }
    .hw-purple-note { color: var(--hw-purple-fg); }

    .hw-drop:drop(active) { box-shadow: inset 0 0 0 2px var(--accent-color); border-radius: 12px; }
    row.hw-drop:drop(active) { box-shadow: inset 0 0 0 2px var(--accent-color); border-radius: 0; }

    .hw-header-title { font-size: 2em; font-weight: 800; }

    .hw-card { padding: 14px; }

    .hw-block { border-radius: 6px; color: white; font-weight: 600; min-height: 34px; }
    .hw-block.blue { background-image: linear-gradient(to bottom, var(--blue-2), var(--blue-3)); }
    .hw-block.green { background-image: linear-gradient(to bottom, var(--green-4), var(--green-5)); }
    .hw-block.purple { background-image: linear-gradient(to bottom, var(--purple-2), var(--purple-3)); }
    .hw-block.clear { background-image: none; background-color: color-mix(in srgb, currentColor 7%, transparent); color: inherit; }
    .hw-block label { text-shadow: 0 1px 1px rgba(0, 0, 0, 0.18); }
    .hw-block.clear label { text-shadow: none; }
    .hw-block .hw-address { font-family: monospace; font-size: 0.68em; font-weight: 400; opacity: 0.85; margin: 2px 4px; }
    .hw-block .hw-size { opacity: 0.8; font-weight: 400; }
    .hw-block .hw-range { font-family: monospace; font-size: 0.72em; font-weight: 400; opacity: 0.9; }
    .hw-tall { min-height: 46px; }

    .hw-bank { border-radius: 7px; min-height: 46px; border: 1px solid transparent; }
    .hw-bank .hw-bank-number { font-weight: 700; font-feature-settings: "tnum"; font-size: 1.05em; }
    .hw-bank .hw-bank-kind { font-size: 0.62em; font-weight: 800; letter-spacing: 0.04em; }
    .hw-bank.rom { color: var(--hw-blue-fg); background-color: color-mix(in srgb, var(--blue-3) 14%, transparent);
                   border-color: color-mix(in srgb, var(--blue-3) 50%, transparent); }
    .hw-bank.ram { color: var(--hw-green-fg); background-color: color-mix(in srgb, var(--green-4) 14%, transparent);
                   border-color: color-mix(in srgb, var(--green-4) 50%, transparent); }
    .hw-bank.empty { border: 1px dashed color-mix(in srgb, currentColor 40%, transparent); }
    .hw-bank.empty label { opacity: 0.7; }
    .hw-bank.not-fitted { border: 1px dashed color-mix(in srgb, currentColor 14%, transparent); }
    .hw-bank.not-fitted label { opacity: 0.3; }
    .hw-dot { min-width: 5px; min-height: 5px; border-radius: 999px; }
    .hw-dot.selected { background-color: var(--accent-bg-color); }
    .hw-status-dot { min-width: 8px; min-height: 8px; border-radius: 999px; }
    .hw-status-dot.blue { background-color: var(--blue-3); }
    .hw-status-dot.purple { background-color: var(--purple-3); }

    .hw-swatch-number { font-size: 0.75em; font-weight: 700; font-feature-settings: "tnum"; }
    .hw-swatch-hex { font-family: monospace; font-size: 0.68em; }

    popover.hw-menu > contents { padding: 6px; }
    popover.hw-menu button { padding: 6px 10px; min-height: 26px; font-weight: 400; }
    popover.hw-menu .hw-menu-heading { font-size: 0.83em; font-weight: 700; opacity: 0.55; margin: 6px 10px 2px 10px; }
    popover.hw-menu separator { margin: 6px 0; }

    .hw-restart-icon { color: var(--warning-color); }
    .hw-capture { background-color: var(--window-bg-color); }
    """
}

// MARK: Section headers

/// The guide page link beside a section's title: the Mac's Learn More.
@MainActor
func learnMoreButton(_ page: @escaping @MainActor () -> String) -> Button {
    Button("Learn More") { GuideWindow.show(page: page()) }
        .style("flat")
        .tooltip("Open the Hardware Expansion Guide")
        .align(vertical: GTK_ALIGN_CENTER)
}

/// A preferences group whose title and description are text (libadwaita
/// reads them as markup: "&FE30" would be an entity).
@MainActor
func textGroup(_ title: String? = nil, _ description: String? = nil) -> PreferencesGroup {
    PreferencesGroup(title: title.map(Markup.escape), description: description.map(Markup.escape))
}

extension PreferencesGroup {
    /// Sets the title and description as text.
    func setText(title: String, description: String) {
        let title = Markup.escape(title), description = Markup.escape(description)
        if self.title != title { self.title = title }
        if detail != description { detail = description }
    }
}

/// Rows' titles and subtitles as text, not markup.
@MainActor
func plainText<W: Widget>(_ row: W) -> W {
    adw_preferences_row_set_use_markup(cast(row.widget), 0)
    return row
}

// MARK: Rows

/// A row of the window's own: any widget, in a boxed list.
final class CustomRow: Widget {
    init(_ child: Widget, title: String = "") {
        super.init(adw_preferences_row_new())
        gtk_list_box_row_set_child(cast(widget), child.widget)
        gtk_list_box_row_set_activatable(cast(widget), 0)
        adw_preferences_row_set_title(cast(widget), title)
    }
}

/// A note in a list of rows: an icon and quiet text.
@MainActor
func noteRow(_ text: String, icon: String) -> ActionRow {
    let row = ActionRow("")
    row.subtitle = text
    row.prefix(Icon(icon).style("hw-note-icon"))
    row.style("hw-note")
    return row
}

extension ToggleGroup {
    /// Its labels in full, however long a row's text beside it.
    @discardableResult
    func fullWidth() -> Self {
        adw_toggle_group_set_can_shrink(cast(widget), 0)
        return self
    }

    /// Relabels one of its toggles.
    func setLabel(_ label: String, at index: Int) {
        guard let toggle = adw_toggle_group_get_toggle(cast(widget), guint(index)) else { return }
        if String(gBorrowed: adw_toggle_get_label(toggle)) != label {
            adw_toggle_set_label(toggle, label)
        }
    }
}

extension ActionRow {
    /// The title and subtitle, set only when they change.
    func set(title: String, subtitle: String) {
        if self.title != title { self.title = title }
        self.subtitle = subtitle
    }
}

// MARK: Actions for one widget

/// Actions for one widget and what's in it (its menus), under a prefix:
/// "bank.save" for a bank's row.
@MainActor
final class WidgetActions {
    private let group: OpaquePointer

    init(on widget: Widget, prefix: String) {
        let group = g_simple_action_group_new()!
        self.group = OpaquePointer(group)
        gtk_widget_insert_action_group(widget.widget, prefix, OpaquePointer(group))
        g_object_unref(gpointer(group))
    }

    @discardableResult
    func add(_ name: String, enabled: Bool = true, _ body: @escaping @MainActor () -> Void) -> Action {
        let action = Action(name, body)
        action.isEnabled = enabled
        g_action_map_add_action(group, action.gAction)
        return action
    }
}

// MARK: Popovers made as they open

extension MenuButton {
    /// Fills `content` each time the button opens its popover (so it shows
    /// what's there now).
    func popover(_ content: Box, filling fill: @escaping @MainActor (Box, Popover) -> Void) {
        let popover = Popover(content)
        popover.style("hw-menu")
        gtk_menu_button_set_popover(cast(widget), popover.widget)
        typealias Fill = @MainActor () -> Void
        let box = Boxed<Fill>({ fill(content, popover) })
        gtk_menu_button_set_create_popup_func(cast(widget), { _, data in
            nonisolated(unsafe) let data = data
            MainActor.assumeIsolated { Boxed<Fill>.from(data)() }
        }, box.retained, { AnyBox.release($0) })
    }
}

/// A menu-like popover's item: a flat button, closing the popover.
@MainActor
func popoverItem(_ label: String, detail: String? = nil, enabled: Bool = true, in popover: Popover,
                 _ action: @escaping @MainActor () -> Void) -> Button {
    let text = Box(.horizontal, spacing: 10) {
        Label(label).ellipsize()
        if let detail {
            Label(detail, style: "dim-label").ellipsize()
        }
    }
    let button = Button(child: text) {
        popover.dismiss()
        action()
    }
    button.style("flat")
    button.isEnabled = enabled
    return button
}

// MARK: Choosing files

private func hardwareFileDialogFinished(_ source: UnsafeMutablePointer<GObject>?, _ result: OpaquePointer?, _ data: gpointer?) {
    guard let source, let result else { return }
    let dialog = UInt(bitPattern: source), outcome = UInt(bitPattern: result), box = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        Boxed<ROMFileDialog.Done>.from(UnsafeMutableRawPointer(bitPattern: box))(OpaquePointer(bitPattern: dialog)!,
                                                                                OpaquePointer(bitPattern: outcome)!)
    }
    AnyBox.release(data)
}

/// GTK's file chooser for ROM images, with the Mac's prompts as its
/// button ("Load", "Use", "Add").
@MainActor
enum ROMFileDialog {
    typealias Done = @MainActor (OpaquePointer, OpaquePointer) -> Void

    private static var parent: UnsafeMutablePointer<GtkWindow>? {
        Application.shared.activeWindow.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self) }
    }

    private static func dialog(title: String, accept: String?) -> OpaquePointer {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        gtk_file_dialog_set_modal(dialog, 1)
        if let accept { gtk_file_dialog_set_accept_label(dialog, accept) }
        let store = g_list_store_new(gtk_file_filter_get_type())!
        let roms = gtk_file_filter_new()!
        gtk_file_filter_set_name(roms, "ROM images")
        for suffix in ["rom", "bin"] { gtk_file_filter_add_suffix(roms, suffix) }
        g_list_store_append(store, gpointer(roms))
        let all = gtk_file_filter_new()!
        gtk_file_filter_set_name(all, "All files")
        gtk_file_filter_add_pattern(all, "*")
        g_list_store_append(store, gpointer(all))
        gtk_file_dialog_set_filters(dialog, store)
        gtk_file_dialog_set_default_filter(dialog, roms)
        g_object_unref(gpointer(roms))
        g_object_unref(gpointer(all))
        g_object_unref(gpointer(store))
        return dialog
    }

    /// Asks for ROM images; `completion` gets them (none if cancelled).
    static func open(title: String, accept: String, multiple: Bool = false, _ completion: @escaping @MainActor ([URL]) -> Void) {
        let dialog = dialog(title: title, accept: accept)
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            defer {
                if let error { g_error_free(error) }
                g_object_unref(gpointer(dialog))
            }
            if multiple {
                guard let files = gtk_file_dialog_open_multiple_finish(dialog, result, &error) else { return completion([]) }
                var urls: [URL] = []
                for index in 0..<g_list_model_get_n_items(files) {
                    if let file = g_list_model_get_item(files, index) {
                        if let url = URL(gFile: OpaquePointer(file)) { urls.append(url) }
                        g_object_unref(file)
                    }
                }
                g_object_unref(gpointer(files))
                completion(urls)
            } else {
                guard let file = gtk_file_dialog_open_finish(dialog, result, &error) else { return completion([]) }
                let url = URL(gFile: file)
                g_object_unref(gpointer(file))
                completion(url.map { [$0] } ?? [])
            }
        }
        if multiple {
            gtk_file_dialog_open_multiple(dialog, parent, nil, hardwareFileDialogFinished, Boxed<Done>(done).retained)
        } else {
            gtk_file_dialog_open(dialog, parent, nil, hardwareFileDialogFinished, Boxed<Done>(done).retained)
        }
    }

    /// Asks where to save a bank's contents.
    static func save(title: String, suggestedName: String, _ completion: @escaping @MainActor (URL?) -> Void) {
        let dialog = dialog(title: title, accept: nil)
        gtk_file_dialog_set_initial_name(dialog, suggestedName)
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            let file = gtk_file_dialog_save_finish(dialog, result, &error)
            if let error { g_error_free(error) }
            let url = URL(gFile: file)
            if let file { g_object_unref(gpointer(file)) }
            g_object_unref(gpointer(dialog))
            completion(url)
        }
        gtk_file_dialog_save(dialog, parent, nil, hardwareFileDialogFinished, Boxed<Done>(done).retained)
    }
}

// MARK: Alerts

@MainActor
enum HardwareAlerts {
    /// The Mac's alert of a title and a message, with OK.
    static func show(_ title: String, _ message: String, over parent: Widget?) {
        AlertDialog(title, body: message)
            .response("ok", "_OK", .suggested)
            .defaults(default: "ok", close: "ok")
            .present(over: parent)
    }

    /// Asks before something that can't be undone.
    static func confirm(_ title: String, _ message: String, action: String, over parent: Widget?,
                        _ completion: @escaping @MainActor () -> Void) {
        AlertDialog(title, body: message)
            .response("cancel", "_Cancel")
            .response("action", action, .destructive)
            .defaults(default: "cancel", close: "cancel")
            .choose(over: parent) { if $0 == "action" { completion() } }
    }
}

// MARK: Keeping focus across a rebuild

/// A part of a window rebuilt as what it shows changes: rebuilt only when
/// its key does, keeping the keyboard focus on the same item.
@MainActor
final class Rebuilding<Key: Equatable> {
    private var key: Key?
    /// The rebuilt widgets that can take focus, by item.
    private var focusable: [AnyHashable: Widget] = [:]

    /// Rebuilds with `build` if `key` changed; `build` registers its
    /// items' focusable widgets with `register`.
    func update(_ key: Key, in container: Widget, _ build: (_ register: (AnyHashable, Widget) -> Void) -> Void) {
        guard key != self.key else { return }
        self.key = key
        // What had the focus, to give it back.
        var focused: AnyHashable?
        if let root = gtk_widget_get_root(container.widget),
           let focus = gtk_root_get_focus(root) {
            for (item, widget) in focusable where focus == widget.widget || gtk_widget_is_ancestor(focus, widget.widget) != 0 {
                focused = item
            }
        }
        focusable = [:]
        build { item, widget in focusable[item] = widget }
        if let focused, let widget = focusable[focused] {
            // (Once it's laid out.)
            MainLoop.after(0) { widget.grabFocus() }
        }
    }

    /// Forgets the key, so the next update rebuilds.
    func invalidate() { key = nil }
}
