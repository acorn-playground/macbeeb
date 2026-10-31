import CGtk
import Foundation

// libadwaita: GNOME's own building blocks, for the app to look and behave
// as a modern GNOME app does.

/// A window's content with bars above and below (libadwaita's toolbar view).
final class ToolbarView: Widget {
    init(content: Widget? = nil) {
        super.init(adw_toolbar_view_new())
        if let content { self.content = content }
    }

    var content: Widget? {
        get { adw_toolbar_view_get_content(cast(widget)).map(Widget.init) }
        set { adw_toolbar_view_set_content(cast(widget), newValue?.widget) }
    }

    @discardableResult
    func top(_ bar: Widget) -> Self {
        adw_toolbar_view_add_top_bar(cast(widget), bar.widget)
        return self
    }

    @discardableResult
    func bottom(_ bar: Widget) -> Self {
        adw_toolbar_view_add_bottom_bar(cast(widget), bar.widget)
        return self
    }

    /// Raised bars with a shadow, as over scrolling content.
    @discardableResult
    func raisedTop() -> Self {
        adw_toolbar_view_set_top_bar_style(cast(widget), ADW_TOOLBAR_RAISED)
        return self
    }

    /// The bars over the content (for the emulator's picture in
    /// fullscreen, say), and whether they're shown.
    @discardableResult
    func extendContentToTop(_ on: Bool) -> Self {
        adw_toolbar_view_set_extend_content_to_top_edge(cast(widget), on ? 1 : 0)
        return self
    }

    var revealsTopBars: Bool {
        get { adw_toolbar_view_get_reveal_top_bars(cast(widget)) != 0 }
        set { adw_toolbar_view_set_reveal_top_bars(cast(widget), newValue ? 1 : 0) }
    }
}

final class HeaderBar: Widget {
    init(title: Widget? = nil) {
        super.init(adw_header_bar_new())
        if let title { adw_header_bar_set_title_widget(cast(widget), title.widget) }
    }

    @discardableResult
    func start(_ child: Widget) -> Self {
        adw_header_bar_pack_start(cast(widget), child.widget)
        return self
    }

    @discardableResult
    func end(_ child: Widget) -> Self {
        adw_header_bar_pack_end(cast(widget), child.widget)
        return self
    }

    var title: Widget? {
        get { adw_header_bar_get_title_widget(cast(widget)).map(Widget.init) }
        set { adw_header_bar_set_title_widget(cast(widget), newValue?.widget) }
    }

    /// Without the window's own buttons (in a dialog, say).
    @discardableResult
    func showsWindowButtons(start: Bool = true, end: Bool = true) -> Self {
        adw_header_bar_set_show_start_title_buttons(cast(widget), start ? 1 : 0)
        adw_header_bar_set_show_end_title_buttons(cast(widget), end ? 1 : 0)
        return self
    }
}

/// A header bar's title and subtitle.
final class WindowTitle: Widget {
    init(_ title: String, subtitle: String = "") {
        super.init(adw_window_title_new(title, subtitle))
    }

    var title: String {
        get { String(cString: adw_window_title_get_title(cast(widget))) }
        set {
            guard newValue != title else { return }
            adw_window_title_set_title(cast(widget), newValue)
        }
    }

    var subtitle: String {
        get { String(cString: adw_window_title_get_subtitle(cast(widget))) }
        set {
            guard newValue != subtitle else { return }
            adw_window_title_set_subtitle(cast(widget), newValue)
        }
    }
}

/// An empty state, or a welcome: an icon, a title, a description, and
/// what to do.
final class StatusPage: Widget {
    init(icon: String? = nil, title: String, description: String? = nil, child: Widget? = nil) {
        super.init(adw_status_page_new())
        if let icon { adw_status_page_set_icon_name(cast(widget), icon) }
        adw_status_page_set_title(cast(widget), title)
        if let description { adw_status_page_set_description(cast(widget), description) }
        if let child { adw_status_page_set_child(cast(widget), child.widget) }
    }

    var title: String {
        get { String(cString: adw_status_page_get_title(cast(widget))) }
        set { adw_status_page_set_title(cast(widget), newValue) }
    }

    var detail: String {
        get { String(gBorrowed: adw_status_page_get_description(cast(widget))) ?? "" }
        set { adw_status_page_set_description(cast(widget), newValue) }
    }

    @discardableResult
    func compact() -> Self { style("compact") }
}

/// Brief messages over a child.
final class ToastOverlay: Widget {
    init(_ child: Widget) {
        super.init(adw_toast_overlay_new())
        adw_toast_overlay_set_child(cast(widget), child.widget)
    }

    /// Shows a toast for a few seconds (with a button, if `action`).
    func show(_ message: String, timeout: UInt32 = 3, button: String? = nil,
              action: (@MainActor () -> Void)? = nil) {
        let toast = adw_toast_new(message)!
        adw_toast_set_timeout(toast, timeout)
        if let button, let action {
            adw_toast_set_button_label(toast, button)
            GObjectRef(toast).on("button-clicked", action)
        }
        adw_toast_overlay_add_toast(cast(widget), toast)
    }
}

/// A banner across the top of a window's content, with a button.
final class Banner: Widget {
    init(_ title: String = "", button: String? = nil, _ action: (@MainActor () -> Void)? = nil) {
        super.init(adw_banner_new(title))
        if let button { adw_banner_set_button_label(cast(widget), button) }
        if let action { object.on("button-clicked", action) }
    }

    var title: String {
        get { String(cString: adw_banner_get_title(cast(widget))) }
        set { adw_banner_set_title(cast(widget), newValue) }
    }

    var isRevealed: Bool {
        get { adw_banner_get_revealed(cast(widget)) != 0 }
        set {
            guard newValue != isRevealed else { return }
            adw_banner_set_revealed(cast(widget), newValue ? 1 : 0)
        }
    }
}

/// Pages switched between by a view switcher (libadwaita's view stack).
final class ViewStack: Widget {
    init() {
        super.init(adw_view_stack_new())
    }

    @discardableResult
    func add(_ child: Widget, name: String, title: String, icon: String) -> Self {
        adw_view_stack_add_titled_with_icon(cast(widget), child.widget, name, title, icon)
        return self
    }

    var visible: String? {
        get { String(gBorrowed: adw_view_stack_get_visible_child_name(cast(widget))) }
        set {
            guard let newValue, newValue != visible else { return }
            adw_view_stack_set_visible_child_name(cast(widget), newValue)
        }
    }

    @discardableResult
    func onSwitch(_ body: @escaping @MainActor (String) -> Void) -> Self {
        let stack = widget
        object.onChange("visible-child-name") {
            body(String(gBorrowed: adw_view_stack_get_visible_child_name(cast(stack))) ?? "")
        }
        return self
    }

    /// A switcher for a header bar's title.
    func switcher() -> Widget {
        let switcher = adw_view_switcher_new()!
        adw_view_switcher_set_stack(OpaquePointer(switcher), opaque)
        adw_view_switcher_set_policy(OpaquePointer(switcher), ADW_VIEW_SWITCHER_POLICY_WIDE)
        return Widget(switcher)
    }

    /// A smaller switcher, inline in content.
    func inlineSwitcher() -> Widget {
        let switcher = adw_inline_view_switcher_new()!
        adw_inline_view_switcher_set_stack(OpaquePointer(switcher), opaque)
        return Widget(switcher)
    }
}

/// A choice of a few, as linked toggles (libadwaita's toggle group: the
/// Mac's segmented control).
final class ToggleGroup: Widget {
    init(_ labels: [String], icons: [String?]? = nil, selected: Int = 0, _ changed: @escaping @MainActor (Int) -> Void) {
        super.init(adw_toggle_group_new())
        for (index, label) in labels.enumerated() {
            let toggle = adw_toggle_new()!
            if let icon = icons?[index] {
                adw_toggle_set_icon_name(toggle, icon)
                adw_toggle_set_tooltip(toggle, label)
            } else {
                adw_toggle_set_label(toggle, label)
            }
            adw_toggle_set_name(toggle, "\(index)")
            adw_toggle_group_add(cast(widget), toggle)
        }
        adw_toggle_group_set_active(cast(widget), guint(selected))
        let group = widget
        object.onChange("active") { changed(Int(adw_toggle_group_get_active(cast(group)))) }
    }

    var selected: Int {
        get { Int(adw_toggle_group_get_active(cast(widget))) }
        set {
            guard newValue != selected else { return }
            adw_toggle_group_set_active(cast(widget), guint(newValue))
        }
    }

    @discardableResult
    func homogeneous(_ on: Bool = true) -> Self {
        adw_toggle_group_set_homogeneous(cast(widget), on ? 1 : 0)
        return self
    }
}

/// A sidebar and content side by side, collapsing to one at a time when
/// narrow (libadwaita's navigation split view).
final class NavigationSplitView: Widget {
    init(sidebar: Widget, sidebarTitle: String, content: Widget, contentTitle: String) {
        super.init(adw_navigation_split_view_new())
        adw_navigation_split_view_set_sidebar(cast(widget), adw_navigation_page_new(sidebar.widget, sidebarTitle))
        adw_navigation_split_view_set_content(cast(widget), adw_navigation_page_new(content.widget, contentTitle))
    }

    @discardableResult
    func sidebarWidth(minimum: Double, maximum: Double, fraction: Double = 0.25) -> Self {
        adw_navigation_split_view_set_min_sidebar_width(cast(widget), minimum)
        adw_navigation_split_view_set_max_sidebar_width(cast(widget), maximum)
        adw_navigation_split_view_set_sidebar_width_fraction(cast(widget), fraction)
        return self
    }

    /// The content shown (when collapsed).
    func showContent(_ on: Bool = true) {
        adw_navigation_split_view_set_show_content(cast(widget), on ? 1 : 0)
    }
}

// MARK: Preferences

/// A page of preference groups, scrolling.
final class PreferencesPage: Widget {
    init(title: String = "", icon: String? = nil, @WidgetList _ groups: () -> [Widget] = { [] }) {
        super.init(adw_preferences_page_new())
        adw_preferences_page_set_title(cast(widget), title)
        if let icon { adw_preferences_page_set_icon_name(cast(widget), icon) }
        for group in groups() { add(group) }
    }

    func add(_ group: Widget) {
        adw_preferences_page_add(cast(widget), cast(group.widget))
    }

    @discardableResult
    func description(_ text: String) -> Self {
        adw_preferences_page_set_description(cast(widget), text)
        return self
    }
}

/// A titled group of rows, as GNOME's settings have them.
final class PreferencesGroup: Widget {
    init(title: String? = nil, description: String? = nil, @WidgetList _ rows: () -> [Widget] = { [] }) {
        super.init(adw_preferences_group_new())
        if let title { adw_preferences_group_set_title(cast(widget), title) }
        if let description { adw_preferences_group_set_description(cast(widget), description) }
        for row in rows() { add(row) }
    }

    func add(_ row: Widget) {
        adw_preferences_group_add(cast(widget), row.widget)
    }

    func remove(_ row: Widget) {
        adw_preferences_group_remove(cast(widget), row.widget)
    }

    /// A widget beside the title (a button, say).
    @discardableResult
    func headerSuffix(_ child: Widget) -> Self {
        adw_preferences_group_set_header_suffix(cast(widget), child.widget)
        return self
    }

    var title: String {
        get { String(gBorrowed: adw_preferences_group_get_title(cast(widget))) ?? "" }
        set { adw_preferences_group_set_title(cast(widget), newValue) }
    }

    var detail: String {
        get { String(gBorrowed: adw_preferences_group_get_description(cast(widget))) ?? "" }
        set { adw_preferences_group_set_description(cast(widget), newValue) }
    }
}

/// A row with a title and subtitle, and widgets before and after.
class ActionRow: Widget {
    init(_ title: String, subtitle: String? = nil, icon: String? = nil) {
        super.init(adw_action_row_new())
        setTitle(title)
        if let subtitle { self.subtitle = subtitle }
        if let icon { adw_action_row_set_icon_name(cast(widget), icon) }
    }

    override init(_ widget: WidgetPointer) {
        super.init(widget)
    }

    func setTitle(_ title: String) {
        // (Plain text: a row's title is markup unless told otherwise, and
        // "&" would break it.)
        adw_preferences_row_set_use_markup(cast(widget), 0)
        adw_preferences_row_set_use_markup(cast(widget), 0)
        adw_preferences_row_set_title(cast(widget), title)
    }

    var title: String {
        get { String(cString: adw_preferences_row_get_title(cast(widget))) }
        set { setTitle(newValue) }
    }

    var subtitle: String {
        get { String(gBorrowed: adw_action_row_get_subtitle(cast(widget))) ?? "" }
        set {
            guard newValue != subtitle else { return }
            adw_action_row_set_subtitle(cast(widget), newValue)
        }
    }

    @discardableResult
    func suffix(_ child: Widget) -> Self {
        adw_action_row_add_suffix(cast(widget), child.widget)
        return self
    }

    @discardableResult
    func prefix(_ child: Widget) -> Self {
        adw_action_row_add_prefix(cast(widget), child.widget)
        return self
    }

    /// Clicking the row works `widget` (a switch or check beside it), or
    /// with a chevron, it goes somewhere.
    @discardableResult
    func activates(_ child: Widget) -> Self {
        adw_action_row_set_activatable_widget(cast(widget), child.widget)
        return self
    }

    @discardableResult
    func onActivated(_ body: @escaping @MainActor () -> Void) -> Self {
        gtk_list_box_row_set_activatable(cast(widget), 1)
        object.on("activated", body)
        return self
    }

    @discardableResult
    func subtitleLines(_ lines: Int32) -> Self {
        adw_action_row_set_subtitle_lines(cast(widget), lines)
        return self
    }

    /// The subtitle can be selected (and copied).
    @discardableResult
    func subtitleSelectable() -> Self {
        adw_action_row_set_subtitle_selectable(cast(widget), 1)
        return self
    }

    /// Titles that look like properties: the subtitle prominent.
    @discardableResult
    func property() -> Self { style("property") }
}

/// A row that's a switch.
final class SwitchRow: Widget {
    init(_ title: String, subtitle: String? = nil, isOn: Bool = false, _ changed: (@MainActor (Bool) -> Void)? = nil) {
        super.init(adw_switch_row_new())
        adw_preferences_row_set_use_markup(cast(widget), 0)
        adw_preferences_row_set_title(cast(widget), title)
        if let subtitle { adw_action_row_set_subtitle(cast(widget), subtitle) }
        self.isOn = isOn
        if let changed {
            let row = widget
            object.onChange("active") { changed(adw_switch_row_get_active(cast(row)) != 0) }
        }
    }

    var isOn: Bool {
        get { adw_switch_row_get_active(cast(widget)) != 0 }
        set {
            guard newValue != isOn else { return }
            adw_switch_row_set_active(cast(widget), newValue ? 1 : 0)
        }
    }

    var subtitle: String {
        get { String(gBorrowed: adw_action_row_get_subtitle(cast(widget))) ?? "" }
        set { adw_action_row_set_subtitle(cast(widget), newValue) }
    }
}

/// A row with a pop-up of choices.
final class ComboRow: Widget {
    private(set) var items: [String]

    init(_ title: String, subtitle: String? = nil, items: [String], selected: Int = 0,
         _ changed: (@MainActor (Int) -> Void)? = nil) {
        self.items = items
        super.init(adw_combo_row_new())
        adw_preferences_row_set_use_markup(cast(widget), 0)
        adw_preferences_row_set_title(cast(widget), title)
        if let subtitle { adw_action_row_set_subtitle(cast(widget), subtitle) }
        let list = withCStringArray(items) { gtk_string_list_new($0) }
        adw_combo_row_set_model(cast(widget), cast(list!))
        g_object_unref(gpointer(list))
        self.selected = selected
        if let changed {
            let row = widget
            object.onChange("selected") {
                let index = adw_combo_row_get_selected(cast(row))
                if index != GTK_INVALID_LIST_POSITION { changed(Int(index)) }
            }
        }
    }

    var selected: Int {
        get {
            let index = adw_combo_row_get_selected(cast(widget))
            return index == GTK_INVALID_LIST_POSITION ? -1 : Int(index)
        }
        set {
            guard newValue != selected, newValue >= 0, newValue < items.count else { return }
            adw_combo_row_set_selected(cast(widget), guint(newValue))
        }
    }

    var subtitle: String {
        get { String(gBorrowed: adw_action_row_get_subtitle(cast(widget))) ?? "" }
        set { adw_action_row_set_subtitle(cast(widget), newValue) }
    }

    func setItems(_ new: [String], selected index: Int) {
        guard new != items else {
            selected = index
            return
        }
        items = new
        let list = withCStringArray(new) { gtk_string_list_new($0) }
        adw_combo_row_set_model(cast(widget), cast(list!))
        g_object_unref(gpointer(list))
        adw_combo_row_set_selected(cast(widget), guint(max(0, index)))
    }
}

/// A row that's a text field.
final class EntryRow: Widget {
    init(_ title: String, text: String = "", _ changed: (@MainActor (String) -> Void)? = nil) {
        super.init(adw_entry_row_new())
        adw_preferences_row_set_use_markup(cast(widget), 0)
        adw_preferences_row_set_title(cast(widget), title)
        self.text = text
        if let changed {
            let editable = widget
            object.on("changed") { changed(String(cString: gtk_editable_get_text(cast(editable)))) }
        }
    }

    var text: String {
        get { String(cString: gtk_editable_get_text(cast(widget))) }
        set {
            guard newValue != text else { return }
            gtk_editable_set_text(cast(widget), newValue)
        }
    }

    /// An Apply button, and Return, confirm the text.
    @discardableResult
    func onApply(_ body: @escaping @MainActor (String) -> Void) -> Self {
        adw_entry_row_set_show_apply_button(cast(widget), 1)
        let editable = widget
        object.on("apply") { body(String(cString: gtk_editable_get_text(cast(editable)))) }
        object.on("entry-activated") { body(String(cString: gtk_editable_get_text(cast(editable)))) }
        return self
    }

    @discardableResult
    func suffix(_ child: Widget) -> Self {
        adw_entry_row_add_suffix(cast(widget), child.widget)
        return self
    }
}

/// A row that's a number.
final class SpinRow: Widget {
    init(_ title: String, subtitle: String? = nil, value: Double, range: ClosedRange<Double>, step: Double = 1,
         _ changed: (@MainActor (Double) -> Void)? = nil) {
        super.init(adw_spin_row_new_with_range(range.lowerBound, range.upperBound, step))
        adw_preferences_row_set_use_markup(cast(widget), 0)
        adw_preferences_row_set_title(cast(widget), title)
        if let subtitle { adw_action_row_set_subtitle(cast(widget), subtitle) }
        adw_spin_row_set_value(cast(widget), value)
        if let changed {
            let row = widget
            object.onChange("value") { changed(adw_spin_row_get_value(cast(row))) }
        }
    }

    var value: Double {
        get { adw_spin_row_get_value(cast(widget)) }
        set {
            guard newValue != value else { return }
            adw_spin_row_set_value(cast(widget), newValue)
        }
    }
}

/// A row that opens to show more rows.
final class ExpanderRow: Widget {
    init(_ title: String, subtitle: String? = nil, expanded: Bool = false) {
        super.init(adw_expander_row_new())
        adw_preferences_row_set_use_markup(cast(widget), 0)
        adw_preferences_row_set_title(cast(widget), title)
        if let subtitle { adw_expander_row_set_subtitle(cast(widget), subtitle) }
        adw_expander_row_set_expanded(cast(widget), expanded ? 1 : 0)
    }

    func add(_ row: Widget) {
        adw_expander_row_add_row(cast(widget), row.widget)
    }

    @discardableResult
    func suffix(_ child: Widget) -> Self {
        adw_expander_row_add_suffix(cast(widget), child.widget)
        return self
    }
}

/// A row that's a button.
final class ButtonRow: Widget {
    init(_ title: String, icon: String? = nil, _ action: @escaping @MainActor () -> Void) {
        super.init(adw_button_row_new())
        adw_preferences_row_set_use_markup(cast(widget), 0)
        adw_preferences_row_set_title(cast(widget), title)
        if let icon { adw_button_row_set_start_icon_name(cast(widget), icon) }
        object.on("activated", action)
    }
}

// MARK: Dialogs

/// libadwaita's dialog: floats over its window (or is a bottom sheet when
/// the window is narrow).
class Dialog: Widget {
    init(title: String, content: Widget, width: Int32 = -1, height: Int32 = -1) {
        super.init(cast(adw_dialog_new()!) as WidgetPointer)
        adw_dialog_set_title(cast(widget), title)
        adw_dialog_set_child(cast(widget), content.widget)
        adw_dialog_set_content_width(cast(widget), width)
        adw_dialog_set_content_height(cast(widget), height)
    }

    override init(_ widget: WidgetPointer) {
        super.init(widget)
    }

    /// Shows it over `parent`'s window (or on its own).
    func present(over parent: Widget?) {
        adw_dialog_present(cast(widget), parent?.widget)
    }

    func close() {
        adw_dialog_close(cast(widget))
    }

    @discardableResult
    func onClosed(_ body: @escaping @MainActor () -> Void) -> Self {
        object.on("closed", body)
        return self
    }

    /// Whether Escape and the close button close it.
    @discardableResult
    func canClose(_ on: Bool) -> Self {
        adw_dialog_set_can_close(cast(widget), on ? 1 : 0)
        return self
    }

    /// A widget that gets focus when it opens.
    @discardableResult
    func focus(_ child: Widget) -> Self {
        adw_dialog_set_focus(cast(widget), child.widget)
        return self
    }

    @discardableResult
    func defaultWidget(_ child: Widget) -> Self {
        adw_dialog_set_default_widget(cast(widget), child.widget)
        return self
    }
}

/// libadwaita's alert: a heading, a body, and responses.
final class AlertDialog: Dialog {
    enum Appearance {
        case normal, suggested, destructive
    }

    init(_ heading: String, body: String? = nil) {
        super.init(cast(adw_alert_dialog_new(heading, body)!) as WidgetPointer)
        adw_alert_dialog_set_prefer_wide_layout(cast(widget), 0)
    }

    /// Adds a response (its label, with mnemonics: "_Remove").
    @discardableResult
    func response(_ id: String, _ label: String, _ appearance: Appearance = .normal) -> Self {
        adw_alert_dialog_add_response(cast(widget), id, label)
        switch appearance {
        case .normal: break
        case .suggested: adw_alert_dialog_set_response_appearance(cast(widget), id, ADW_RESPONSE_SUGGESTED)
        case .destructive: adw_alert_dialog_set_response_appearance(cast(widget), id, ADW_RESPONSE_DESTRUCTIVE)
        }
        return self
    }

    /// The response for Return, and for Escape.
    @discardableResult
    func defaults(default id: String?, close: String?) -> Self {
        if let id { adw_alert_dialog_set_default_response(cast(widget), id) }
        if let close { adw_alert_dialog_set_close_response(cast(widget), close) }
        return self
    }

    /// Extra content under the body.
    @discardableResult
    func extra(_ child: Widget) -> Self {
        adw_alert_dialog_set_extra_child(cast(widget), child.widget)
        return self
    }

    /// Shows it, calling `completion` with the response chosen.
    func choose(over parent: Widget?, _ completion: @escaping @MainActor (String) -> Void) {
        object.onString("response", completion)
        present(over: parent)
    }
}
