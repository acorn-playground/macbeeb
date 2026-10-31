import CGtk
import Foundation

// Labels, buttons, switches, text fields and pictures.

final class Label: Widget {
    init(_ text: String = "", style: String...) {
        super.init(gtk_label_new(text))
        for name in style { gtk_widget_add_css_class(widget, name) }
        gtk_label_set_xalign(cast(widget), 0)
    }

    /// Text with Pango markup: <b>, <i>, <tt>, <small>, <a href>…
    convenience init(markup: String) {
        self.init()
        self.markup = markup
    }

    var text: String {
        get { String(cString: gtk_label_get_text(cast(widget))) }
        set {
            guard newValue != text else { return }
            gtk_label_set_text(cast(widget), newValue)
        }
    }

    var markup: String {
        get { text }
        set { gtk_label_set_markup(cast(widget), newValue) }
    }

    /// Wraps, at word boundaries, as needed.
    @discardableResult
    func wrap(_ on: Bool = true) -> Self {
        gtk_label_set_wrap(cast(widget), on ? 1 : 0)
        gtk_label_set_wrap_mode(cast(widget), PANGO_WRAP_WORD_CHAR)
        return self
    }

    /// 0 left, 0.5 centred, 1 right.
    @discardableResult
    func xalign(_ value: Float) -> Self {
        gtk_label_set_xalign(cast(widget), value)
        return self
    }

    @discardableResult
    func justify(_ justification: GtkJustification) -> Self {
        gtk_label_set_justify(cast(widget), justification)
        return self
    }

    @discardableResult
    func centred() -> Self {
        gtk_label_set_xalign(cast(widget), 0.5)
        gtk_label_set_justify(cast(widget), GTK_JUSTIFY_CENTER)
        return self
    }

    @discardableResult
    func ellipsize(_ mode: PangoEllipsizeMode = PANGO_ELLIPSIZE_END) -> Self {
        gtk_label_set_ellipsize(cast(widget), mode)
        return self
    }

    @discardableResult
    func selectable(_ on: Bool = true) -> Self {
        gtk_label_set_selectable(cast(widget), on ? 1 : 0)
        return self
    }

    @discardableResult
    func lines(_ count: Int32) -> Self {
        gtk_label_set_lines(cast(widget), count)
        return self
    }

    @discardableResult
    func maxWidthChars(_ count: Int32) -> Self {
        gtk_label_set_max_width_chars(cast(widget), count)
        return self
    }

    @discardableResult
    func widthChars(_ count: Int32) -> Self {
        gtk_label_set_width_chars(cast(widget), count)
        return self
    }

    /// Links in markup open with the handler (true: handled).
    @discardableResult
    func onLink(_ body: @escaping @MainActor (String) -> Bool) -> Self {
        typealias Handler = @MainActor (String) -> Bool
        macbeeb_signal_connect(gpointer(widget), "activate-link", unsafeBitCast(
            { (_: gpointer?, uri: UnsafePointer<CChar>?, data: gpointer?) -> gboolean in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated { Boxed<Handler>.from(data)(uri.map { String(cString: $0) } ?? "") ? 1 : 0 }
            } as @convention(c) (gpointer?, UnsafePointer<CChar>?, gpointer?) -> gboolean, to: GCallback.self),
            Boxed<Handler>(body).retained, { data, _ in AnyBox.release(data) }, 0)
        return self
    }
}

class Button: Widget {
    /// A button with a label, an icon (a symbolic icon name, e.g.
    /// "media-playback-pause-symbolic"), or both.
    init(_ label: String? = nil, icon: String? = nil, _ action: (@MainActor () -> Void)? = nil) {
        super.init(gtk_button_new())
        if let label, let icon {
            let content = adw_button_content_new()!
            adw_button_content_set_label(OpaquePointer(content), label)
            adw_button_content_set_icon_name(OpaquePointer(content), icon)
            gtk_button_set_child(cast(widget), content)
        } else if let icon {
            gtk_button_set_icon_name(cast(widget), icon)
        } else if let label {
            gtk_button_set_label(cast(widget), label)
            gtk_button_set_use_underline(cast(widget), 1)
        }
        if let action { onClicked(action) }
    }

    /// A button holding any widget.
    init(child: Widget, _ action: (@MainActor () -> Void)? = nil) {
        super.init(gtk_button_new())
        gtk_button_set_child(cast(widget), child.widget)
        if let action { onClicked(action) }
    }

    override init(_ widget: WidgetPointer) {
        super.init(widget)
    }

    @discardableResult
    func onClicked(_ action: @escaping @MainActor () -> Void) -> Self {
        object.on("clicked", action)
        return self
    }

    var label: String {
        get { String(gBorrowed: gtk_button_get_label(cast(widget))) ?? "" }
        set { gtk_button_set_label(cast(widget), newValue) }
    }

    var iconName: String {
        get { String(gBorrowed: gtk_button_get_icon_name(cast(widget))) ?? "" }
        set { gtk_button_set_icon_name(cast(widget), newValue) }
    }

    /// Runs a GAction ("win.pause", "app.quit"), enabled as it is.
    @discardableResult
    func action(_ name: String, target: String? = nil) -> Self {
        gtk_actionable_set_action_name(OpaquePointer(widget), name)
        if let target {
            gtk_actionable_set_action_target_value(OpaquePointer(widget), g_variant_new_string(target))
        }
        return self
    }

    @discardableResult
    func hasFrame(_ on: Bool) -> Self {
        gtk_button_set_has_frame(cast(widget), on ? 1 : 0)
        return self
    }

    /// Makes it the window's default (Return presses it).
    @discardableResult
    func isDefault(in window: Window) -> Self {
        gtk_window_set_default_widget(window.window, widget)
        return self
    }
}

final class ToggleButton: Button {
    init(_ label: String? = nil, icon: String? = nil, isOn: Bool = false,
         _ changed: (@MainActor (Bool) -> Void)? = nil) {
        super.init(gtk_toggle_button_new())
        if let icon { gtk_button_set_icon_name(cast(widget), icon) } else if let label { gtk_button_set_label(cast(widget), label) }
        self.isOn = isOn
        if let changed {
            let button = self.widget
            object.on("toggled") { changed(gtk_toggle_button_get_active(UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkToggleButton.self)) != 0) }
        }
    }

    var isOn: Bool {
        get { gtk_toggle_button_get_active(cast(widget)) != 0 }
        set {
            guard newValue != isOn else { return }
            gtk_toggle_button_set_active(cast(widget), newValue ? 1 : 0)
        }
    }
}

/// A checkbox, or (grouped) a radio button.
final class CheckButton: Widget {
    init(_ label: String, isOn: Bool = false, _ changed: (@MainActor (Bool) -> Void)? = nil) {
        super.init(gtk_check_button_new_with_mnemonic(label))
        self.isOn = isOn
        if let changed {
            let button = opaqueButton
            object.on("toggled") { changed(gtk_check_button_get_active(button) != 0) }
        }
    }

    private var opaqueButton: UnsafeMutablePointer<GtkCheckButton> { ptr() }

    var isOn: Bool {
        get { gtk_check_button_get_active(cast(widget)) != 0 }
        set {
            guard newValue != isOn else { return }
            gtk_check_button_set_active(cast(widget), newValue ? 1 : 0)
        }
    }

    /// Makes it a radio button in `other`'s group.
    @discardableResult
    func group(with other: CheckButton) -> Self {
        gtk_check_button_set_group(cast(widget), other.ptr())
        return self
    }
}

final class Switch: Widget {
    init(isOn: Bool = false, _ changed: (@MainActor (Bool) -> Void)? = nil) {
        super.init(gtk_switch_new())
        self.isOn = isOn
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        if let changed {
            let toggle = widget
            object.onChange("active") { changed(gtk_switch_get_active(cast(toggle)) != 0) }
        }
    }

    var isOn: Bool {
        get { gtk_switch_get_active(cast(widget)) != 0 }
        set {
            guard newValue != isOn else { return }
            gtk_switch_set_active(cast(widget), newValue ? 1 : 0)
        }
    }
}

class Entry: Widget {
    init(text: String = "", placeholder: String? = nil, _ changed: (@MainActor (String) -> Void)? = nil) {
        super.init(gtk_entry_new())
        self.text = text
        if let placeholder { gtk_entry_set_placeholder_text(cast(widget), placeholder) }
        if let changed { onChanged(changed) }
    }

    override init(_ widget: WidgetPointer) {
        super.init(widget)
    }

    var text: String {
        get { String(cString: gtk_editable_get_text(cast(widget))) }
        set {
            guard newValue != text else { return }
            gtk_editable_set_text(cast(widget), newValue)
        }
    }

    @discardableResult
    func onChanged(_ body: @escaping @MainActor (String) -> Void) -> Self {
        let editable = widget
        object.on("changed") { body(String(cString: gtk_editable_get_text(cast(editable)))) }
        return self
    }

    /// Return pressed.
    @discardableResult
    func onActivate(_ body: @escaping @MainActor () -> Void) -> Self {
        object.on("activate", body)
        return self
    }

    @discardableResult
    func monospace() -> Self {
        style("monospace")
    }

    @discardableResult
    func widthChars(_ count: Int32) -> Self {
        gtk_editable_set_width_chars(cast(widget), count)
        return self
    }

    @discardableResult
    func maxLength(_ count: Int32) -> Self {
        gtk_entry_set_max_length(cast(widget), count)
        return self
    }

    func selectAll() {
        gtk_editable_select_region(cast(widget), 0, -1)
    }
}

final class SearchEntry: Widget {
    init(placeholder: String? = nil, _ changed: @escaping @MainActor (String) -> Void) {
        super.init(gtk_search_entry_new())
        if let placeholder { gtk_search_entry_set_placeholder_text(cast(widget), placeholder) }
        let editable = widget
        object.on("search-changed") { changed(String(cString: gtk_editable_get_text(cast(editable)))) }
    }

    var text: String {
        get { String(cString: gtk_editable_get_text(cast(widget))) }
        set { gtk_editable_set_text(cast(widget), newValue) }
    }
}

final class PasswordEntry: Widget {
    init(placeholder: String? = nil, _ changed: (@MainActor (String) -> Void)? = nil) {
        super.init(gtk_password_entry_new())
        gtk_password_entry_set_show_peek_icon(cast(widget), 1)
        if let placeholder { GObjectRef(widget).set("placeholder-text", placeholder) }
        if let changed {
            let editable = widget
            object.on("changed") { changed(String(cString: gtk_editable_get_text(cast(editable)))) }
        }
    }

    var text: String {
        get { String(cString: gtk_editable_get_text(cast(widget))) }
        set { gtk_editable_set_text(cast(widget), newValue) }
    }
}

final class SpinButton: Widget {
    init(value: Double, range: ClosedRange<Double>, step: Double = 1, digits: UInt32 = 0,
         _ changed: (@MainActor (Double) -> Void)? = nil) {
        super.init(gtk_spin_button_new_with_range(range.lowerBound, range.upperBound, step))
        gtk_spin_button_set_digits(cast(widget), digits)
        gtk_spin_button_set_value(cast(widget), value)
        if let changed {
            let spin = widget
            object.on("value-changed") { changed(gtk_spin_button_get_value(cast(spin))) }
        }
    }

    var value: Double {
        get { gtk_spin_button_get_value(cast(widget)) }
        set {
            guard newValue != value else { return }
            gtk_spin_button_set_value(cast(widget), newValue)
        }
    }
}

/// A pop-up list of choices (the Mac's Picker in a menu style).
final class DropDown: Widget {
    private(set) var items: [String]

    init(_ items: [String], selected: Int = 0, _ changed: (@MainActor (Int) -> Void)? = nil) {
        self.items = items
        let list = withCStringArray(items) { gtk_string_list_new($0) }
        super.init(gtk_drop_down_new(cast(list!), nil))
        self.selected = selected
        if let changed {
            let dropDown = widget
            object.onChange("selected") {
                let index = gtk_drop_down_get_selected(cast(dropDown))
                if index != GTK_INVALID_LIST_POSITION { changed(Int(index)) }
            }
        }
    }

    var selected: Int {
        get {
            let index = gtk_drop_down_get_selected(cast(widget))
            return index == GTK_INVALID_LIST_POSITION ? -1 : Int(index)
        }
        set {
            guard newValue != selected, newValue >= 0, newValue < items.count else { return }
            gtk_drop_down_set_selected(cast(widget), guint(newValue))
        }
    }

    /// Replaces the choices, keeping the selection if it's still there.
    func setItems(_ new: [String], selected index: Int) {
        guard new != items else {
            selected = index
            return
        }
        items = new
        let list = withCStringArray(new) { gtk_string_list_new($0) }
        gtk_drop_down_set_model(cast(widget), cast(list!))
        g_object_unref(gpointer(list))
        gtk_drop_down_set_selected(cast(widget), guint(max(0, index)))
    }
}

final class Scale: Widget {
    init(value: Double, range: ClosedRange<Double>, step: Double = 1, _ changed: (@MainActor (Double) -> Void)? = nil) {
        super.init(gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, range.lowerBound, range.upperBound, step))
        gtk_range_set_value(cast(widget), value)
        if let changed {
            let range: UnsafeMutablePointer<GtkRange> = ptr()
            object.on("value-changed") { changed(gtk_range_get_value(range)) }
        }
    }

    var value: Double {
        get { gtk_range_get_value(cast(widget)) }
        set { gtk_range_set_value(cast(widget), newValue) }
    }

    @discardableResult
    func drawValue(_ on: Bool) -> Self {
        gtk_scale_set_draw_value(cast(widget), on ? 1 : 0)
        return self
    }

    @discardableResult
    func mark(_ value: Double, _ label: String? = nil) -> Self {
        gtk_scale_add_mark(cast(widget), value, GTK_POS_BOTTOM, label)
        return self
    }
}

/// An icon (a theme's symbolic icon, by name).
final class Icon: Widget {
    init(_ name: String, size: Int32 = 16) {
        super.init(gtk_image_new_from_icon_name(name))
        gtk_image_set_pixel_size(cast(widget), size)
    }

    var name: String {
        get { String(gBorrowed: gtk_image_get_icon_name(cast(widget))) ?? "" }
        set { gtk_image_set_from_icon_name(cast(widget), newValue) }
    }
}

/// A picture: a texture, a file, or a platform image, scaled to fit.
final class Picture: Widget {
    init() {
        super.init(gtk_picture_new())
        gtk_picture_set_content_fit(cast(widget), GTK_CONTENT_FIT_CONTAIN)
    }

    convenience init(file url: URL) {
        self.init()
        setFile(url)
    }

    convenience init(_ image: PlatformImage?) {
        self.init()
        self.image = image
        gtk_picture_set_paintable(cast(widget), image.map { $0.texture })
    }

    func setFile(_ url: URL?) {
        if let url {
            gtk_picture_set_filename(cast(widget), url.path)
        } else {
            gtk_picture_set_paintable(cast(widget), nil)
        }
    }

    var image: PlatformImage? {
        didSet {
            gtk_picture_set_paintable(cast(widget), image.map { $0.texture })
        }
    }

    @discardableResult
    func fit(_ fit: GtkContentFit) -> Self {
        gtk_picture_set_content_fit(cast(widget), fit)
        return self
    }

    @discardableResult
    func canShrink(_ on: Bool) -> Self {
        gtk_picture_set_can_shrink(cast(widget), on ? 1 : 0)
        return self
    }

    /// Pixels drawn as pixels, not smoothed (the BBC's pictures).
    @discardableResult
    func pixelated() -> Self {
        gtk_widget_add_css_class(widget, "pixelated")
        return self
    }
}

/// libadwaita's spinner.
final class Spinner: Widget {
    init() {
        super.init(adw_spinner_new())
    }
}

final class ProgressBar: Widget {
    init() {
        super.init(gtk_progress_bar_new())
    }

    var fraction: Double {
        get { gtk_progress_bar_get_fraction(cast(widget)) }
        set { gtk_progress_bar_set_fraction(cast(widget), newValue) }
    }

    func pulse() { gtk_progress_bar_pulse(cast(widget)) }
}

final class Separator: Widget {
    init(_ orientation: GtkOrientation = GTK_ORIENTATION_HORIZONTAL) {
        super.init(gtk_separator_new(orientation))
    }
}

/// A button that opens a menu (or a popover).
final class MenuButton: Widget {
    init(icon: String? = nil, label: String? = nil, menu: Menu? = nil) {
        super.init(gtk_menu_button_new())
        if let icon { gtk_menu_button_set_icon_name(cast(widget), icon) }
        if let label { gtk_menu_button_set_label(cast(widget), label) }
        if let icon, let label {
            gtk_menu_button_set_always_show_arrow(cast(widget), 1)
            let content = adw_button_content_new()!
            adw_button_content_set_label(OpaquePointer(content), label)
            adw_button_content_set_icon_name(OpaquePointer(content), icon)
            gtk_menu_button_set_child(cast(widget), content)
        }
        if let menu {
            self.menu = menu
            // (Observers don't run in an initialiser.)
            gtk_menu_button_set_menu_model(cast(widget), UnsafeMutablePointer(menu.model))
        }
    }

    var menu: Menu? {
        didSet { gtk_menu_button_set_menu_model(cast(widget), menu.map { UnsafeMutablePointer($0.model) }) }
    }

    @discardableResult
    func popover(_ content: Widget) -> Self {
        let popover = gtk_popover_new()!
        gtk_popover_set_child(cast(popover), content.widget)
        gtk_menu_button_set_popover(cast(widget), popover)
        return self
    }

    @discardableResult
    func primary() -> Self {
        gtk_menu_button_set_primary(cast(widget), 1)
        return self
    }

    func popup() { gtk_menu_button_popup(cast(widget)) }
    func popdown() { gtk_menu_button_popdown(cast(widget)) }
}

/// A popover of a widget, pointing at a widget.
final class Popover: Widget {
    init(_ content: Widget) {
        super.init(gtk_popover_new())
        gtk_popover_set_child(cast(widget), content.widget)
    }

    /// A menu, as a popover.
    init(menu: Menu) {
        super.init(gtk_popover_menu_new_from_model(UnsafeMutablePointer(menu.model)))
        gtk_popover_set_has_arrow(cast(widget), 0)
    }

    /// Shows it pointing at `x`, `y` in `parent`.
    func show(on parent: Widget, at x: Double? = nil, y: Double? = nil) {
        if gtk_widget_get_parent(widget) == nil {
            gtk_widget_set_parent(widget, parent.widget)
            let popover = widget
            parent.onDestroy { gtk_widget_unparent(popover) }
        }
        if let x, let y {
            var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
            gtk_popover_set_pointing_to(cast(widget), &rect)
        }
        gtk_popover_popup(cast(widget))
    }

    func dismiss() { gtk_popover_popdown(cast(widget)) }
}

/// A link, opened in the browser.
final class LinkButton: Widget {
    init(_ label: String, url: URL) {
        super.init(gtk_link_button_new_with_label(url.absoluteString, label))
    }
}

/// libadwaita's split button: an action, and a menu beside it.
final class SplitButton: Widget {
    init(_ label: String? = nil, icon: String? = nil, menu: Menu, _ action: @escaping @MainActor () -> Void) {
        super.init(adw_split_button_new())
        if let label { adw_split_button_set_label(cast(widget), label) }
        if let icon { adw_split_button_set_icon_name(cast(widget), icon) }
        adw_split_button_set_menu_model(cast(widget), UnsafeMutablePointer(menu.model))
        object.on("clicked", action)
    }
}
