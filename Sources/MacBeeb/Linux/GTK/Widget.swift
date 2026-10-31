import CGtk
import Foundation

// Widgets, as thin Swift wrappers. GTK owns its widgets (a window owns its
// tree, a parent its children); a wrapper just points at one, and is cheap
// to make and drop. Anything a widget needs kept alive (handlers, tracked
// state) is attached to the widget and goes when it does.
//
// Layout reads like SwiftUI's, with chainable modifiers that return the
// widget, and children built with a result builder:
//
//     Box(.vertical, spacing: 12) {
//         Label("Model B").style("title-2")
//         Button("Play") { machine.play() }.style("suggested-action", "pill")
//     }
//     .margin(24)
//     .track { label.text = machine.title }

typealias WidgetPointer = UnsafeMutablePointer<GtkWidget>

@MainActor
class Widget {
    let widget: WidgetPointer

    init(_ widget: WidgetPointer) {
        self.widget = widget
    }

    convenience init(_ pointer: OpaquePointer) {
        self.init(WidgetPointer(pointer))
    }

    /// The widget as another GTK type (GTK's casting macros, unchecked).
    func ptr<T>() -> UnsafeMutablePointer<T> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: T.self)
    }

    /// The widget as an opaque GTK type (a final class's pointer).
    var opaque: OpaquePointer { OpaquePointer(widget) }

    var object: GObjectRef { GObjectRef(widget) }

    // MARK: Layout

    @discardableResult
    func margin(_ all: Int32) -> Self {
        margin(top: all, bottom: all, start: all, end: all)
    }

    @discardableResult
    func margin(horizontal: Int32? = nil, vertical: Int32? = nil) -> Self {
        margin(top: vertical, bottom: vertical, start: horizontal, end: horizontal)
    }

    @discardableResult
    func margin(top: Int32? = nil, bottom: Int32? = nil, start: Int32? = nil, end: Int32? = nil) -> Self {
        if let top { gtk_widget_set_margin_top(widget, top) }
        if let bottom { gtk_widget_set_margin_bottom(widget, bottom) }
        if let start { gtk_widget_set_margin_start(widget, start) }
        if let end { gtk_widget_set_margin_end(widget, end) }
        return self
    }

    @discardableResult
    func expand(horizontal: Bool? = nil, vertical: Bool? = nil) -> Self {
        if let horizontal { gtk_widget_set_hexpand(widget, horizontal ? 1 : 0) }
        if let vertical { gtk_widget_set_vexpand(widget, vertical ? 1 : 0) }
        return self
    }

    @discardableResult
    func expand() -> Self { expand(horizontal: true, vertical: true) }

    @discardableResult
    func align(horizontal: GtkAlign? = nil, vertical: GtkAlign? = nil) -> Self {
        if let horizontal { gtk_widget_set_halign(widget, horizontal) }
        if let vertical { gtk_widget_set_valign(widget, vertical) }
        return self
    }

    /// The smallest it can be (-1: its natural size).
    @discardableResult
    func size(width: Int32 = -1, height: Int32 = -1) -> Self {
        gtk_widget_set_size_request(widget, width, height)
        return self
    }

    // MARK: Appearance

    /// Adds CSS style classes: "title-1", "dim-label", "card", "boxed-list",
    /// "suggested-action", "destructive-action", "flat", "pill", "circular",
    /// "monospace", "caption", "heading", "error", "success", "warning",
    /// "accent", "osd", "toolbar", "linked", "navigation-sidebar"…
    @discardableResult
    func style(_ classes: String...) -> Self {
        for name in classes { gtk_widget_add_css_class(widget, name) }
        return self
    }

    func removeStyle(_ name: String) {
        gtk_widget_remove_css_class(widget, name)
    }

    func setStyle(_ name: String, _ on: Bool) {
        if on { gtk_widget_add_css_class(widget, name) } else { gtk_widget_remove_css_class(widget, name) }
    }

    /// The tooltip (the Mac's help).
    @discardableResult
    func tooltip(_ text: String?) -> Self {
        gtk_widget_set_tooltip_text(widget, text)
        return self
    }

    var isVisible: Bool {
        get { gtk_widget_get_visible(widget) != 0 }
        set { gtk_widget_set_visible(widget, newValue ? 1 : 0) }
    }

    var isEnabled: Bool {
        get { gtk_widget_get_sensitive(widget) != 0 }
        set { gtk_widget_set_sensitive(widget, newValue ? 1 : 0) }
    }

    @discardableResult
    func visible(_ shown: Bool) -> Self {
        isVisible = shown
        return self
    }

    @discardableResult
    func enabled(_ on: Bool) -> Self {
        isEnabled = on
        return self
    }

    @discardableResult
    func opacity(_ value: Double) -> Self {
        gtk_widget_set_opacity(widget, value)
        return self
    }

    /// The accessible name, for a widget without visible text.
    @discardableResult
    func accessibleLabel(_ text: String) -> Self {
        macbeeb_set_accessible_label(widget, text)
        return self
    }

    @discardableResult
    func focusable(_ on: Bool) -> Self {
        gtk_widget_set_focusable(widget, on ? 1 : 0)
        return self
    }

    @discardableResult
    func canTarget(_ on: Bool) -> Self {
        gtk_widget_set_can_target(widget, on ? 1 : 0)
        return self
    }

    func grabFocus() {
        gtk_widget_grab_focus(widget)
    }

    var hasFocus: Bool { gtk_widget_has_focus(widget) != 0 }

    func queueDraw() { gtk_widget_queue_draw(widget) }
    func queueResize() { gtk_widget_queue_resize(widget) }

    var width: Int32 { gtk_widget_get_width(widget) }
    var height: Int32 { gtk_widget_get_height(widget) }

    /// The window it's in, if it's in one.
    var root: WidgetPointer? {
        gtk_widget_get_root(widget).map { cast($0) }
    }

    /// Takes it out of its parent (it's destroyed unless something else
    /// holds it).
    func unparent() {
        gtk_widget_unparent(widget)
    }

    /// The cursor shown over it ("pointer", "grab", "none", "crosshair"…).
    @discardableResult
    func cursor(_ name: String?) -> Self {
        gtk_widget_set_cursor_from_name(widget, name)
        return self
    }

    // MARK: State

    /// Runs `body` now and whenever the @Observable state it reads changes,
    /// for as long as the widget lives.
    @discardableResult
    func track(_ body: @escaping @MainActor () -> Void) -> Self {
        object.track(body)
        return self
    }

    /// Keeps `value` alive for as long as the widget lives.
    @discardableResult
    func keep<T>(_ value: T) -> Self {
        object.keep(value)
        return self
    }

    /// Calls `body` when the widget's destroyed.
    func onDestroy(_ body: @escaping @MainActor () -> Void) {
        object.on("destroy", body)
    }

    func onMap(_ body: @escaping @MainActor () -> Void) {
        object.on("map", body)
    }

    func onUnmap(_ body: @escaping @MainActor () -> Void) {
        object.on("unmap", body)
    }

    /// Calls `body` every frame the widget's shown (GTK's frame clock), with
    /// the frame time in microseconds; false from it stops.
    func onTick(_ body: @escaping @MainActor (Int64) -> Bool) {
        typealias Tick = @MainActor (Int64) -> Bool
        gtk_widget_add_tick_callback(widget, { _, clock, data in
            let time = Int64(gdk_frame_clock_get_frame_time(clock))
            return MainActor.assumeIsolated { Boxed<Tick>.from(data)(time) } ? 1 : 0
        }, Boxed<Tick>(body).retained, { AnyBox.release($0) })
    }

    // MARK: Events

    /// Adds an event controller.
    @discardableResult
    func add(_ controller: EventController) -> Self {
        gtk_widget_add_controller(widget, controller.controller)
        return self
    }

    /// Clicks with `button` (1 primary, 2 middle, 3 secondary; 0 any):
    /// `body` gets the number of presses (2: a double click) and where.
    @discardableResult
    func onClick(button: UInt32 = 1, _ body: @escaping @MainActor (Int32, Double, Double) -> Void) -> Self {
        let gesture = ClickGesture(button: button)
        gesture.onReleased(body)
        return add(gesture)
    }

    /// A secondary click (or long press): a context menu's place.
    @discardableResult
    func onContextClick(_ body: @escaping @MainActor (Double, Double) -> Void) -> Self {
        let gesture = ClickGesture(button: 3)
        gesture.onPressed { _, x, y in body(x, y) }
        add(gesture)
        let press = EventController(gtk_gesture_long_press_new())
        press.object.onPoint("pressed") { x, y in body(x, y) }
        return add(press)
    }

    /// Files dropped on it: `body` gets them and says whether it took them.
    @discardableResult
    func onDropFiles(_ body: @escaping @MainActor ([URL], Double, Double) -> Bool) -> Self {
        add(DropTarget.files(body))
    }
}

/// Builds a list of widgets: children of a container.
@resultBuilder
enum WidgetList {
    @MainActor static func buildExpression(_ widget: Widget) -> [Widget] { [widget] }
    @MainActor static func buildExpression(_ widgets: [Widget]) -> [Widget] { widgets }
    @MainActor static func buildExpression(_ widget: Widget?) -> [Widget] { widget.map { [$0] } ?? [] }
    static func buildBlock(_ parts: [Widget]...) -> [Widget] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [Widget]?) -> [Widget] { part ?? [] }
    static func buildEither(first: [Widget]) -> [Widget] { first }
    static func buildEither(second: [Widget]) -> [Widget] { second }
    static func buildArray(_ parts: [[Widget]]) -> [Widget] { parts.flatMap { $0 } }
    static func buildLimitedAvailability(_ part: [Widget]) -> [Widget] { part }
}

// MARK: Event controllers

@MainActor
class EventController {
    let controller: OpaquePointer

    init(_ controller: OpaquePointer) {
        self.controller = controller
    }

    var object: GObjectRef { GObjectRef(controller) }

    /// When it sees events: GTK_PHASE_CAPTURE (on the way down to the
    /// focused widget, before it), GTK_PHASE_BUBBLE (on the way back up,
    /// the default), GTK_PHASE_TARGET.
    @discardableResult
    func phase(_ phase: GtkPropagationPhase) -> Self {
        gtk_event_controller_set_propagation_phase(controller, phase)
        return self
    }

    /// The event's modifier keys.
    var modifiers: GdkModifierType {
        gtk_event_controller_get_current_event_state(controller)
    }
}

final class KeyController: EventController {
    init() {
        super.init(gtk_event_controller_key_new())
    }

    /// A key pressed: (keyval, hardware keycode, modifiers); true takes it.
    @discardableResult
    func onPressed(_ body: @escaping @MainActor (UInt32, UInt32, GdkModifierType) -> Bool) -> Self {
        object.onKey("key-pressed", body)
        return self
    }

    @discardableResult
    func onReleased(_ body: @escaping @MainActor (UInt32, UInt32, GdkModifierType) -> Void) -> Self {
        object.onKeyUp("key-released", body)
        return self
    }

    @discardableResult
    func onModifiers(_ body: @escaping @MainActor (GdkModifierType) -> Bool) -> Self {
        object.onModifiers("modifiers", body)
        return self
    }
}

final class ClickGesture: EventController {
    /// `button`: 1 primary, 2 middle, 3 secondary, 0 any.
    init(button: UInt32 = 1) {
        super.init(gtk_gesture_click_new())
        gtk_gesture_single_set_button(cast(controller), button)
    }

    /// The button pressed now (with button 0, which it was).
    var currentButton: UInt32 {
        gtk_gesture_single_get_current_button(cast(controller))
    }

    @discardableResult
    func onPressed(_ body: @escaping @MainActor (Int32, Double, Double) -> Void) -> Self {
        object.onClick("pressed", body)
        return self
    }

    @discardableResult
    func onReleased(_ body: @escaping @MainActor (Int32, Double, Double) -> Void) -> Self {
        object.onClick("released", body)
        return self
    }
}

final class MotionController: EventController {
    init() {
        super.init(gtk_event_controller_motion_new())
    }

    @discardableResult
    func onMotion(_ body: @escaping @MainActor (Double, Double) -> Void) -> Self {
        object.onPoint("motion", body)
        return self
    }

    @discardableResult
    func onEnter(_ body: @escaping @MainActor (Double, Double) -> Void) -> Self {
        object.onPoint("enter", body)
        return self
    }

    @discardableResult
    func onLeave(_ body: @escaping @MainActor () -> Void) -> Self {
        object.on("leave", body)
        return self
    }
}

final class ScrollController: EventController {
    init(_ flags: GtkEventControllerScrollFlags = GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES) {
        super.init(gtk_event_controller_scroll_new(flags))
    }

    /// (dx, dy); true takes it.
    @discardableResult
    func onScroll(_ body: @escaping @MainActor (Double, Double) -> Bool) -> Self {
        object.onPointStop("scroll", body)
        return self
    }
}

/// Dragging with the pointer: where it began, then the offset from there.
final class DragGesture: EventController {
    init(button: UInt32 = 1) {
        super.init(gtk_gesture_drag_new())
        gtk_gesture_single_set_button(cast(controller), button)
    }

    @discardableResult
    func onBegin(_ body: @escaping @MainActor (Double, Double) -> Void) -> Self {
        object.onPoint("drag-begin", body)
        return self
    }

    @discardableResult
    func onUpdate(_ body: @escaping @MainActor (Double, Double) -> Void) -> Self {
        object.onPoint("drag-update", body)
        return self
    }

    @discardableResult
    func onEnd(_ body: @escaping @MainActor (Double, Double) -> Void) -> Self {
        object.onPoint("drag-end", body)
        return self
    }
}

final class FocusController: EventController {
    init() {
        super.init(gtk_event_controller_focus_new())
    }

    @discardableResult
    func onEnter(_ body: @escaping @MainActor () -> Void) -> Self {
        object.on("enter", body)
        return self
    }

    @discardableResult
    func onLeave(_ body: @escaping @MainActor () -> Void) -> Self {
        object.on("leave", body)
        return self
    }
}

/// Things dropped on a widget.
final class DropTarget: EventController {
    init(type: GType, actions: GdkDragAction = GDK_ACTION_COPY) {
        super.init(gtk_drop_target_new(type, actions))
    }

    /// Files (from the file manager, or another app).
    static func files(_ body: @escaping @MainActor ([URL], Double, Double) -> Bool) -> DropTarget {
        let target = DropTarget(type: macbeeb_type_file_list(), actions: GDK_ACTION_COPY)
        target.object.onDrop { value, x, y in
            guard let value else { return false }
            var urls: [URL] = []
            let list = macbeeb_drop_files(value)
            var node = list
            while let current = node {
                if let file = current.pointee.data, let url = URL(gFile: OpaquePointer(file)) {
                    urls.append(url)
                }
                node = current.pointee.next
            }
            g_slist_free(list)
            return !urls.isEmpty && body(urls, x, y)
        }
        return target
    }

    /// Calls `body` with whether something's being dragged over it (to
    /// highlight it).
    @discardableResult
    func onHover(_ body: @escaping @MainActor (Bool) -> Void) -> Self {
        let target: OpaquePointer = cast(controller)
        object.onChange("current-drop") {
            body(gtk_drop_target_get_current_drop(target) != nil)
        }
        return self
    }
}

/// Dragging things out of a widget: `content` gives the files when a drag
/// starts (nil: no drag).
final class DragSource: EventController {
    init(_ content: @escaping @MainActor (Double, Double) -> [URL]?) {
        super.init(gtk_drag_source_new())
        gtk_drag_source_set_actions(cast(controller), GDK_ACTION_COPY)
        typealias Prepare = @MainActor (Double, Double) -> [URL]?
        let box = Boxed<Prepare>(content)
        macbeeb_signal_connect(gpointer(controller), "prepare", unsafeBitCast(
            { (_: gpointer?, x: gdouble, y: gdouble, data: gpointer?) -> OpaquePointer? in
                // (As an integer: pointers aren't Sendable.)
                let provider = MainActor.assumeIsolated { () -> UInt in
                    guard let urls = Boxed<Prepare>.from(data)(x, y), !urls.isEmpty else { return 0 }
                    var files: [OpaquePointer?] = urls.map { $0.gFile }
                    defer { files.forEach { g_object_unref(gpointer($0)) } }
                    return files.withUnsafeMutableBufferPointer { buffer in
                        UInt(bitPattern: macbeeb_content_for_files(buffer.baseAddress, gsize(buffer.count)))
                    }
                }
                return OpaquePointer(bitPattern: provider)
            } as @convention(c) (gpointer?, gdouble, gdouble, gpointer?) -> OpaquePointer?, to: GCallback.self),
            box.retained, { data, _ in AnyBox.release(data) }, 0)
    }
}
