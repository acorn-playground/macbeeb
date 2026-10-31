import CGtk
import Foundation

// Boxes, grids, scrolling, stacks and lists.

final class Box: Widget {
    enum Axis {
        case horizontal, vertical
        var orientation: GtkOrientation {
            self == .horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL
        }
    }

    init(_ axis: Axis, spacing: Int32 = 0, @WidgetList _ children: () -> [Widget] = { [] }) {
        super.init(gtk_box_new(axis.orientation, spacing))
        for child in children() { append(child) }
    }

    func append(_ child: Widget) {
        gtk_box_append(cast(widget), child.widget)
    }

    func prepend(_ child: Widget) {
        gtk_box_prepend(cast(widget), child.widget)
    }

    func remove(_ child: Widget) {
        gtk_box_remove(cast(widget), child.widget)
    }

    /// Takes every child out.
    func removeAll() {
        while let child = gtk_widget_get_first_child(widget) {
            gtk_box_remove(cast(widget), child)
        }
    }

    /// Replaces the children (for content rebuilt as state changes).
    func set(@WidgetList _ children: () -> [Widget]) {
        removeAll()
        for child in children() { append(child) }
    }

    /// Makes the children one control ("linked" style).
    @discardableResult
    func linked() -> Self { style("linked") }

    @discardableResult
    func homogeneous(_ on: Bool = true) -> Self {
        gtk_box_set_homogeneous(cast(widget), on ? 1 : 0)
        return self
    }
}

/// A flexible space that pushes what follows to the far end of a box.
@MainActor
func Spacer() -> Widget {
    Widget(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)).expand(horizontal: true, vertical: true)
}

final class Grid: Widget {
    init(rowSpacing: UInt32 = 6, columnSpacing: UInt32 = 12) {
        super.init(gtk_grid_new())
        gtk_grid_set_row_spacing(cast(widget), rowSpacing)
        gtk_grid_set_column_spacing(cast(widget), columnSpacing)
    }

    @discardableResult
    func attach(_ child: Widget, column: Int32, row: Int32, width: Int32 = 1, height: Int32 = 1) -> Self {
        gtk_grid_attach(cast(widget), child.widget, column, row, width, height)
        return self
    }

    /// A row of label and control, as in a form.
    @discardableResult
    func row(_ row: Int32, _ label: String, _ control: Widget) -> Self {
        attach(Label(label).xalign(1).style("dim-label"), column: 0, row: row)
        attach(control, column: 1, row: row)
        return self
    }

    func removeAll() {
        while let child = gtk_widget_get_first_child(widget) {
            gtk_grid_remove(cast(widget), child)
        }
    }
}

final class ScrolledWindow: Widget {
    init(_ child: Widget? = nil, horizontal: GtkPolicyType = GTK_POLICY_AUTOMATIC,
         vertical: GtkPolicyType = GTK_POLICY_AUTOMATIC) {
        super.init(gtk_scrolled_window_new())
        gtk_scrolled_window_set_policy(cast(widget), horizontal, vertical)
        if let child { gtk_scrolled_window_set_child(cast(widget), child.widget) }
    }

    var child: Widget? {
        didSet { gtk_scrolled_window_set_child(cast(widget), child?.widget) }
    }

    /// Its own size follows its content's, up to the limits.
    @discardableResult
    func propagateNaturalHeight(_ on: Bool = true) -> Self {
        gtk_scrolled_window_set_propagate_natural_height(cast(widget), on ? 1 : 0)
        return self
    }

    @discardableResult
    func propagateNaturalWidth(_ on: Bool = true) -> Self {
        gtk_scrolled_window_set_propagate_natural_width(cast(widget), on ? 1 : 0)
        return self
    }

    @discardableResult
    func maxContentHeight(_ height: Int32) -> Self {
        gtk_scrolled_window_set_max_content_height(cast(widget), height)
        return self
    }

    @discardableResult
    func minContentHeight(_ height: Int32) -> Self {
        gtk_scrolled_window_set_min_content_height(cast(widget), height)
        return self
    }

    var vadjustment: OpaquePointer { OpaquePointer(gtk_scrolled_window_get_vadjustment(cast(widget))) }
    var hadjustment: OpaquePointer { OpaquePointer(gtk_scrolled_window_get_hadjustment(cast(widget))) }

    /// Scrolls to the bottom.
    func scrollToEnd() {
        let adjustment = gtk_scrolled_window_get_vadjustment(cast(widget))
        gtk_adjustment_set_value(adjustment, gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
    }

    func scrollToTop() {
        gtk_adjustment_set_value(gtk_scrolled_window_get_vadjustment(cast(widget)), 0)
    }
}

/// One child shown at a time, by name, with a transition.
final class Stack: Widget {
    init(transition: GtkStackTransitionType = GTK_STACK_TRANSITION_TYPE_CROSSFADE) {
        super.init(gtk_stack_new())
        gtk_stack_set_transition_type(cast(widget), transition)
    }

    @discardableResult
    func add(_ child: Widget, name: String, title: String? = nil) -> Self {
        if let title {
            gtk_stack_add_titled(cast(widget), child.widget, name, title)
        } else {
            gtk_stack_add_named(cast(widget), child.widget, name)
        }
        return self
    }

    var visible: String? {
        get { String(gBorrowed: gtk_stack_get_visible_child_name(cast(widget))) }
        set {
            guard let newValue, newValue != visible else { return }
            gtk_stack_set_visible_child_name(cast(widget), newValue)
        }
    }

    func remove(named name: String) {
        if let child = gtk_stack_get_child_by_name(cast(widget), name) {
            gtk_stack_remove(cast(widget), child)
        }
    }

    /// The child sizes to the one shown, not the largest.
    @discardableResult
    func sizesToVisible() -> Self {
        gtk_stack_set_hhomogeneous(cast(widget), 0)
        gtk_stack_set_vhomogeneous(cast(widget), 0)
        return self
    }
}

/// A child with others laid over it.
final class Overlay: Widget {
    init(_ child: Widget, @WidgetList overlays: () -> [Widget] = { [] }) {
        super.init(gtk_overlay_new())
        gtk_overlay_set_child(cast(widget), child.widget)
        for overlay in overlays() { add(overlay) }
    }

    func add(_ overlay: Widget) {
        gtk_overlay_add_overlay(cast(widget), overlay.widget)
    }
}

/// Two children side by side (or one above the other), divided where the
/// user drags.
final class Paned: Widget {
    init(_ axis: Box.Axis, start: Widget, end: Widget, position: Int32? = nil) {
        super.init(gtk_paned_new(axis.orientation))
        gtk_paned_set_start_child(cast(widget), start.widget)
        gtk_paned_set_end_child(cast(widget), end.widget)
        gtk_paned_set_shrink_start_child(cast(widget), 0)
        gtk_paned_set_shrink_end_child(cast(widget), 0)
        if let position { gtk_paned_set_position(cast(widget), position) }
    }

    @discardableResult
    func resizes(start: Bool, end: Bool) -> Self {
        gtk_paned_set_resize_start_child(cast(widget), start ? 1 : 0)
        gtk_paned_set_resize_end_child(cast(widget), end ? 1 : 0)
        return self
    }

    var position: Int32 {
        get { gtk_paned_get_position(cast(widget)) }
        set { gtk_paned_set_position(cast(widget), newValue) }
    }
}

/// Children flowing in rows (a grid of tiles).
final class FlowBox: Widget {
    init(spacing: UInt32 = 12, minColumns: UInt32 = 1, maxColumns: UInt32 = 8) {
        super.init(gtk_flow_box_new())
        gtk_flow_box_set_selection_mode(cast(widget), GTK_SELECTION_NONE)
        gtk_flow_box_set_row_spacing(cast(widget), spacing)
        gtk_flow_box_set_column_spacing(cast(widget), spacing)
        gtk_flow_box_set_min_children_per_line(cast(widget), minColumns)
        gtk_flow_box_set_max_children_per_line(cast(widget), maxColumns)
        gtk_flow_box_set_homogeneous(cast(widget), 1)
        gtk_widget_set_valign(widget, GTK_ALIGN_START)
    }

    func append(_ child: Widget) {
        gtk_flow_box_append(cast(widget), child.widget)
    }

    func removeAll() {
        gtk_flow_box_remove_all(cast(widget))
    }

    func set(_ children: [Widget]) {
        removeAll()
        children.forEach(append)
    }
}

/// libadwaita's wrapping box: children in lines, each its own width.
final class WrapBox: Widget {
    init(spacing: Int32 = 6, lineSpacing: Int32 = 6) {
        super.init(adw_wrap_box_new())
        adw_wrap_box_set_child_spacing(cast(widget), spacing)
        adw_wrap_box_set_line_spacing(cast(widget), lineSpacing)
    }

    func append(_ child: Widget) {
        adw_wrap_box_append(cast(widget), child.widget)
    }

    func removeAll() {
        adw_wrap_box_remove_all(cast(widget))
    }
}

/// A vertical list of rows: "boxed-list" for settings-like lists,
/// "navigation-sidebar" for a sidebar.
final class ListBox: Widget {
    /// Each row's own value, by row widget.
    private var rows: [WidgetPointer] = []

    init(selection: GtkSelectionMode = GTK_SELECTION_NONE) {
        super.init(gtk_list_box_new())
        gtk_list_box_set_selection_mode(cast(widget), selection)
    }

    func append(_ row: Widget) {
        gtk_list_box_append(cast(widget), row.widget)
        if let wrapper = gtk_widget_get_parent(row.widget), gtk_widget_get_parent(wrapper) == widget {
            rows.append(wrapper)
        } else {
            rows.append(row.widget)
        }
    }

    func removeAll() {
        gtk_list_box_remove_all(cast(widget))
        rows = []
    }

    func set(_ children: [Widget]) {
        removeAll()
        children.forEach(append)
    }

    var count: Int { rows.count }

    /// A row activated (clicked, or Return): its index.
    @discardableResult
    func onActivate(_ body: @escaping @MainActor (Int) -> Void) -> Self {
        object.onPointer("row-activated") { row in
            guard let row else { return }
            body(Int(gtk_list_box_row_get_index(row.assumingMemoryBound(to: GtkListBoxRow.self))))
        }
        return self
    }

    /// The selection changed: the selected row's index, or nil.
    @discardableResult
    func onSelect(_ body: @escaping @MainActor (Int?) -> Void) -> Self {
        let list = widget
        object.on("selected-rows-changed") {
            body(gtk_list_box_get_selected_row(cast(list)).map { Int(gtk_list_box_row_get_index($0)) })
        }
        return self
    }

    /// Selects row `index` (nil: none).
    func select(_ index: Int?) {
        guard let index, let row = gtk_list_box_get_row_at_index(cast(widget), Int32(index)) else {
            gtk_list_box_unselect_all(cast(widget))
            return
        }
        gtk_list_box_select_row(cast(widget), row)
    }

    var selectedIndex: Int? {
        gtk_list_box_get_selected_row(cast(widget)).map { Int(gtk_list_box_row_get_index($0)) }
    }

    /// What's shown with no rows.
    @discardableResult
    func placeholder(_ child: Widget) -> Self {
        gtk_list_box_set_placeholder(cast(widget), child.widget)
        return self
    }
}

/// A frame around a child (libadwaita's "card" style is often better).
final class Frame: Widget {
    init(_ child: Widget, label: String? = nil) {
        super.init(gtk_frame_new(label))
        gtk_frame_set_child(cast(widget), child.widget)
    }
}

/// A child, centred, at most `maximum` wide (libadwaita's clamp).
final class Clamp: Widget {
    init(_ child: Widget, maximum: Int32 = 600) {
        super.init(adw_clamp_new())
        adw_clamp_set_maximum_size(cast(widget), maximum)
        adw_clamp_set_child(cast(widget), child.widget)
    }
}

/// Start, centre and end children.
final class CenterBox: Widget {
    init(start: Widget? = nil, center: Widget? = nil, end: Widget? = nil) {
        super.init(gtk_center_box_new())
        if let start { gtk_center_box_set_start_widget(cast(widget), start.widget) }
        if let center { gtk_center_box_set_center_widget(cast(widget), center.widget) }
        if let end { gtk_center_box_set_end_widget(cast(widget), end.widget) }
    }
}

/// A child shown or hidden with an animation.
final class Revealer: Widget {
    init(_ child: Widget, transition: GtkRevealerTransitionType = GTK_REVEALER_TRANSITION_TYPE_CROSSFADE) {
        super.init(gtk_revealer_new())
        gtk_revealer_set_child(cast(widget), child.widget)
        gtk_revealer_set_transition_type(cast(widget), transition)
    }

    var isRevealed: Bool {
        get { gtk_revealer_get_reveal_child(cast(widget)) != 0 }
        set {
            guard newValue != isRevealed else { return }
            gtk_revealer_set_reveal_child(cast(widget), newValue ? 1 : 0)
        }
    }
}

/// One child, swappable (libadwaita's bin).
final class Bin: Widget {
    init(_ child: Widget? = nil) {
        super.init(adw_bin_new())
        if let child { adw_bin_set_child(cast(widget), child.widget) }
    }

    var child: Widget? {
        get { adw_bin_get_child(cast(widget)).map(Widget.init) }
        set { adw_bin_set_child(cast(widget), newValue?.widget) }
    }
}
