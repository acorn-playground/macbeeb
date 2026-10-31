import BeebHost
import BeebNetwork
import CGtk
import Foundation

// The Network Studio's own pieces: its styles, the station badge and state
// light every view shows, and the few GTK things the shared layer hasn't
// got (an overlay split view, an aspect frame, a canvas of placed
// children, parameterised actions, string drags).

// MARK: Styles

@MainActor
enum NetworkStyles {
    private static var installed = false

    /// The studio's CSS, once (light and dark from libadwaita's colours).
    static func install() {
        guard !installed else { return }
        installed = true
        let css = """
        .network-canvas {
            background-color: var(--window-bg-color);
            background-image: linear-gradient(var(--shade-color), var(--shade-color));
        }
        .network-card {
            background-color: var(--window-bg-color);
            background-image: linear-gradient(var(--card-bg-color), var(--card-bg-color));
            border-radius: 14px;
            padding: 10px;
            box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.07), 0 2px 5px rgba(0, 0, 0, 0.10);
        }
        .network-card:focus-visible { outline: none; }
        .network-card.problem { box-shadow: 0 0 0 1px var(--warning-color), 0 2px 5px rgba(0, 0, 0, 0.10); }
        .network-card.selected { box-shadow: 0 0 0 2.5px var(--accent-bg-color), 0 4px 12px rgba(0, 0, 0, 0.18); }
        .network-card.selected:focus-visible { box-shadow: 0 0 0 2.5px var(--accent-bg-color), 0 0 0 5px rgba(53, 132, 228, 0.35), 0 4px 12px rgba(0, 0, 0, 0.18); }
        .network-card.clock-card { padding: 12px; }
        .network-card.remote {
            background-image: linear-gradient(var(--card-bg-color), var(--card-bg-color));
            border: 1.5px dashed rgba(127, 127, 127, 0.55);
            box-shadow: none;
        }
        .network-card.remote.online { border-color: rgba(33, 144, 164, 0.85); }
        .network-screen { background-color: black; border-radius: 6px; box-shadow: inset 0 0 0 1px rgba(0, 0, 0, 0.4); }
        .network-screen-off { color: rgba(255, 255, 255, 0.45); }
        .network-chip {
            background-color: rgba(30, 30, 30, 0.72);
            color: white;
            border-radius: 99px;
            padding: 2px 7px;
            font-size: 7pt;
            font-weight: 800;
        }
        .network-chip.remote-globe { padding: 3px; }
        .station-badge {
            background-color: var(--accent-bg-color);
            color: var(--accent-fg-color);
            border-radius: 6px;
            min-width: 30px;
            min-height: 22px;
            padding: 0 3px;
            font-weight: 800;
            font-feature-settings: "tnum";
        }
        .station-badge.problem { background-color: var(--warning-bg-color); color: var(--warning-fg-color); }
        .station-badge.remote { background-color: #2190a4; color: white; }
        .online-pill {
            border-radius: 99px;
            padding: 1px 6px;
            font-size: 8pt;
            font-weight: 700;
            background-color: rgba(127, 127, 127, 0.18);
        }
        .online-pill.online { background-color: rgba(33, 144, 164, 0.18); }
        .teal { color: #2190a4; }
        .network-floating {
            background-color: var(--window-bg-color);
            background-image: linear-gradient(var(--card-bg-color), var(--card-bg-color));
            border-radius: 12px;
            box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.07), 0 2px 8px rgba(0, 0, 0, 0.14);
        }
        .network-floating.pill { border-radius: 99px; padding: 2px 6px; }
        .network-palette-item { padding: 5px 8px; min-height: 0; border-radius: 7px; font-weight: 400; }
        .network-palette-item label { font-weight: 400; }
        .clock-face { border-radius: 99px; background-color: color-mix(in srgb, var(--accent-bg-color) 14%, transparent); }
        .network-palette-title { font-size: 8pt; font-weight: 700; padding: 4px 8px 2px 8px; }
        .network-tile {
            background-color: var(--window-bg-color);
            background-image: linear-gradient(var(--card-bg-color), var(--card-bg-color));
            border-radius: 10px;
            box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.09);
        }
        .network-tile.focused { box-shadow: 0 0 0 3px var(--accent-bg-color); }
        .network-tile-screen { background-color: black; border-radius: 0 0 10px 10px; }
        .network-thumbnail { padding: 6px; border-radius: 9px; }
        .network-thumbnail.showing { box-shadow: inset 0 0 0 2.5px var(--accent-bg-color); }
        .network-thumbnail picture { border-radius: 5px; }
        .network-backdrop {
            background-color: var(--window-bg-color);
            background-image: linear-gradient(var(--shade-color), var(--shade-color));
        }
        .template-card { padding: 16px; border-radius: 12px; }
        .template-card .template-icon { color: var(--accent-color); }
        .mandelbrot-swatch { border-radius: 3px; min-width: 12px; min-height: 12px; }
        """
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }

    /// Whether the app's showing dark.
    static var isDark: Bool { adw_style_manager_get_dark(adw_style_manager_get_default()) != 0 }

    /// The success green, for the theme.
    static var green: UInt32 { isDark ? 0x57E389 : 0x26A269 }
    static let orange: UInt32 = 0xE66100
    static let teal: UInt32 = 0x2190A4
}

// MARK: The station badge, and the state light

/// A station's number on the accent colour (orange with a problem).
@MainActor
func StationNumberBadge(_ number: Int?, problem: Bool = false, remote: Bool = false) -> Label {
    let label = Label(number.map(String.init) ?? "–").centred()
    label.style("station-badge").align(vertical: GTK_ALIGN_CENTER)
    if problem { label.style("problem") }
    if remote { label.style("remote") }
    label.accessibleLabel(number.map { "Station \($0)" } ?? "No station number")
    return label
}

/// On, off, suspended: a shape as well as a colour, so it doesn't rely on
/// colour alone.
@MainActor
final class StateLight {
    enum State {
        case on, off, suspended, networkPaused, debugger

        var label: String {
            switch self {
            case .on: "On"
            case .off: "Off"
            case .suspended: "Suspended"
            case .networkPaused: "Paused"
            case .debugger: "Stopped in the debugger"
            }
        }

        @MainActor var colour: UInt32 {
            switch self {
            case .on: NetworkStyles.green
            case .off: 0x888888
            case .suspended: NetworkStyles.orange
            case .networkPaused: 0x3584E4
            case .debugger: 0xE01B24
            }
        }
    }

    let area: DrawingArea
    var state = State.off {
        didSet {
            guard state != oldValue else { return }
            update()
        }
    }

    init() {
        area = DrawingArea(width: 16, height: 16) { _, _, _ in }
        area.align(vertical: GTK_ALIGN_CENTER)
        // (The area's draw function keeps the light.)
        area.setDraw { [self] cairo, width, height in
            Self.draw(self.state, cairo, width, height)
        }
        update()
    }

    private func update() {
        area.tooltip(state.label)
        area.accessibleLabel(state.label)
        area.queueDraw()
    }

    static func draw(_ state: State, _ cairo: Cairo, _ width: Double, _ height: Double) {
        let cx = width / 2, cy = height / 2, r = min(width, height) / 2 - 1.5
        cairo.color(hex: state.colour)
        switch state {
        case .on:
            cairo.circle(cx, cy, radius: r)
            cairo.fill()
        case .off:
            cairo.circle(cx, cy, radius: r - 0.75)
            cairo.color(hex: state.colour, alpha: 0.8)
            cairo.stroke(width: 1.5)
        case .suspended, .networkPaused:
            if state == .suspended {
                cairo.circle(cx, cy, radius: r)
                cairo.fill()
                cairo.color(1, 1, 1)
            } else {
                cairo.circle(cx, cy, radius: r - 0.75)
                cairo.stroke(width: 1.5)
            }
            let bar = r * 0.28, gap = r * 0.22, tall = r * 0.95
            cairo.rectangle(cx - gap - bar, cy - tall / 2, bar, tall)
            cairo.rectangle(cx + gap, cy - tall / 2, bar, tall)
            cairo.fill()
        case .debugger:
            // A ladybird: red, a line down its back, and its spots.
            cairo.circle(cx, cy, radius: r)
            cairo.fill()
            cairo.color(1, 1, 1)
            cairo.move(cx, cy - r)
            cairo.line(cx, cy + r)
            cairo.stroke(width: 1.2)
            for (dx, dy) in [(-0.45, -0.2), (0.45, -0.2), (-0.4, 0.4), (0.4, 0.4)] {
                cairo.circle(cx + dx * r, cy + dy * r, radius: r * 0.16)
            }
            cairo.fill()
        }
    }

    /// A machine's state, from the session.
    static func state(of id: UUID, in session: NetworkSession) -> State {
        guard let controller = session.controllers[id] else { return .off }
        if controller.debugStop != nil { return .debugger }
        if session.paused { return .networkPaused }
        if controller.paused { return .suspended }
        return .on
    }
}

// MARK: GTK pieces

/// libadwaita's overlay split view: content, and a sidebar beside it that
/// can be shown and hidden (and floats over the content when collapsed).
final class NetworkSplitView: Widget {
    init(content: Widget, sidebar: Widget, atEnd: Bool = true) {
        super.init(adw_overlay_split_view_new())
        adw_overlay_split_view_set_content(cast(widget), content.widget)
        adw_overlay_split_view_set_sidebar(cast(widget), sidebar.widget)
        adw_overlay_split_view_set_sidebar_position(cast(widget), atEnd ? GTK_PACK_END : GTK_PACK_START)
    }

    var showsSidebar: Bool {
        get { adw_overlay_split_view_get_show_sidebar(cast(widget)) != 0 }
        set {
            guard newValue != showsSidebar else { return }
            adw_overlay_split_view_set_show_sidebar(cast(widget), newValue ? 1 : 0)
        }
    }

    @discardableResult
    func sidebarWidth(minimum: Double, maximum: Double, fraction: Double) -> Self {
        adw_overlay_split_view_set_min_sidebar_width(cast(widget), minimum)
        adw_overlay_split_view_set_max_sidebar_width(cast(widget), maximum)
        adw_overlay_split_view_set_sidebar_width_fraction(cast(widget), fraction)
        return self
    }

    func onShowSidebarChanged(_ body: @escaping @MainActor (Bool) -> Void) {
        let view = widget
        object.onChange("show-sidebar") { body(adw_overlay_split_view_get_show_sidebar(cast(view)) != 0) }
    }
}

/// A child kept at an aspect ratio, centred in the space it has.
final class NetworkAspectFrame: Widget {
    init(_ child: Widget, ratio: Double) {
        super.init(gtk_aspect_frame_new(0.5, 0.5, Float(ratio), 0))
        gtk_aspect_frame_set_child(cast(widget), child.widget)
    }
}

/// Children placed where they're told, each scaled (GtkFixed with child
/// transforms): the canvas's cards.
final class PlacedChildren: Widget {
    init() {
        super.init(gtk_fixed_new())
    }

    func put(_ child: Widget) {
        gtk_fixed_put(cast(widget), child.widget, 0, 0)
    }

    func remove(_ child: Widget) {
        placed[child.widget] = nil
        gtk_fixed_remove(cast(widget), child.widget)
    }

    /// Where each child was put last (so putting it there again does
    /// nothing).
    private var placed: [WidgetPointer: (Float, Float, Float)] = [:]

    /// Puts `child`'s top left at (x, y), scaled by `scale`.
    func place(_ child: Widget, x: Double, y: Double, scale: Double) {
        let place = (Float(x), Float(y), Float(scale))
        if let last = placed[child.widget], last == place { return }
        placed[child.widget] = place
        macbeeb_network_fixed_place(cast(widget), child.widget, place.0, place.1, place.2)
    }

    /// The widget under a point (itself, if nothing else is).
    func pick(_ x: Double, _ y: Double) -> WidgetPointer? {
        gtk_widget_pick(widget, x, y, GTK_PICK_DEFAULT)
    }
}

/// A machine's screen, live: a picture drawn to fill it (redrawn, never
/// resized, as pictures arrive).
@MainActor
final class StationScreenView {
    let area: DrawingArea
    var image: PlatformImage? {
        didSet {
            guard image !== oldValue else { return }
            area.queueDraw()
        }
    }

    init(width: Int32 = -1, height: Int32 = -1) {
        area = DrawingArea(width: width, height: height) { _, _, _ in }
        area.canTarget(false)
        // (The area's draw function keeps the view.)
        area.setDraw { [self] cairo, width, height in
            guard let image = self.image else { return }
            cairo.image(image, x: 0, y: 0, width: width, height: height)
        }
    }
}

/// A widget's natural size.
@MainActor
func networkNaturalSize(of widget: Widget) -> (width: Double, height: Double) {
    var width: Int32 = 0, height: Int32 = 0
    gtk_widget_measure(widget.widget, GTK_ORIENTATION_HORIZONTAL, -1, nil, &width, nil, nil)
    gtk_widget_measure(widget.widget, GTK_ORIENTATION_VERTICAL, width, nil, &height, nil, nil)
    return (Double(width), Double(height))
}

/// Commands with a string parameter, for menus whose items each name what
/// they're for ("canvas.power", target a node's ID), in an action group
/// of a widget's own.
@MainActor
final class NetworkActionGroup {
    let group: OpaquePointer
    private var actions: [String: OpaquePointer] = [:]

    /// Installs a group named `prefix` ("canvas") on `widget`.
    init(_ prefix: String, on widget: Widget) {
        group = OpaquePointer(g_simple_action_group_new())
        gtk_widget_insert_action_group(widget.widget, prefix, cast(group))
        g_object_unref(gpointer(group))
        widget.keep(self)
    }

    /// A command taking a string.
    func add(_ name: String, _ body: @escaping @MainActor (String) -> Void) {
        let action = g_simple_action_new(name, macbeeb_variant_type_string())!
        GObjectRef(action).onPointer("activate") { parameter in
            guard let parameter else { return }
            body(String(cString: g_variant_get_string(OpaquePointer(parameter), nil)))
        }
        g_action_map_add_action(group, action)
        actions[name] = action
        g_object_unref(gpointer(action))
    }

    /// A command without one.
    func add(plain name: String, _ body: @escaping @MainActor () -> Void) {
        let action = Action(name, body)
        g_action_map_add_action(group, action.gAction)
        actions[name] = action.gAction
    }

    func setEnabled(_ name: String, _ on: Bool) {
        guard let action = actions[name] else { return }
        g_simple_action_set_enabled(action, on ? 1 : 0)
    }
}

/// Dragging a string out of a widget (a palette item onto the canvas).
@MainActor
func networkStringDrag(to widget: Widget, _ value: String) {
    let source = gtk_drag_source_new()!
    gtk_drag_source_set_actions(source, GDK_ACTION_COPY)
    let provider = macbeeb_network_content_for_string(value)
    gtk_drag_source_set_content(source, provider)
    g_object_unref(gpointer(provider))
    // The item itself, as it's dragged.
    let button = widget.widget
    GObjectRef(source).onPointer("drag-begin") { _ in
        let paintable = gtk_widget_paintable_new(button)!
        gtk_drag_source_set_icon(source, paintable, Int32(gtk_widget_get_width(button) / 2), Int32(gtk_widget_get_height(button) / 2))
        g_object_unref(gpointer(paintable))
    }
    gtk_widget_add_controller(widget.widget, cast(source))
}

/// Strings dropped on a widget.
@MainActor
func networkStringDrop(to widget: Widget, _ body: @escaping @MainActor (String, Double, Double) -> Bool) {
    let target = DropTarget(type: macbeeb_type_string(), actions: GDK_ACTION_COPY)
    target.object.onDrop { value, x, y in
        guard let value, let string = macbeeb_drop_string(value) else { return false }
        return body(String(cString: string), x, y)
    }
    widget.add(target)
}

/// A pinch on a touchpad or touchscreen: the scale since it began.
@MainActor
func networkOnPinch(_ widget: Widget, begin: @escaping @MainActor () -> Void, changed: @escaping @MainActor (Double) -> Void,
             end: @escaping @MainActor () -> Void) {
    let gesture = EventController(gtk_gesture_zoom_new())
    gesture.object.onPointer("begin") { _ in begin() }
    gesture.object.onPointer("end") { _ in end() }
    typealias Changed = @MainActor (Double) -> Void
    macbeeb_signal_connect(gpointer(gesture.controller), "scale-changed", unsafeBitCast(
        { (_: gpointer?, scale: gdouble, data: gpointer?) in
            nonisolated(unsafe) let data = data
            MainActor.assumeIsolated { Boxed<Changed>.from(data)(scale) }
        } as @convention(c) (gpointer?, gdouble, gpointer?) -> Void, to: GCallback.self),
        Boxed<Changed>(changed).retained, { data, _ in AnyBox.release(data) }, 0)
    widget.add(gesture)
}

/// The keyboard on a widget: keyval and modifiers, true when taken.
@MainActor
func networkOnKey(_ widget: Widget, _ body: @escaping @MainActor (UInt32, GdkModifierType) -> Bool) {
    let keys = KeyController()
    keys.onPressed { keyval, _, state in body(keyval, state) }
    widget.add(keys)
}


/// Live pictures of machines from a network's thumbnail cache, for the
/// widgets showing them: shown while they're on screen, each machine's
/// current host.
@MainActor
final class ThumbnailFeed {
    private let cache: ThumbnailCache
    private var shown: [UUID: EmulatorHost] = [:]

    init(_ cache: ThumbnailCache) {
        self.cache = cache
    }

    /// Shows exactly these.
    func show(_ wanted: [UUID: EmulatorHost]) {
        for (id, host) in shown where wanted[id] !== host {
            cache.hide(id)
            shown[id] = nil
        }
        for (id, host) in wanted where shown[id] == nil {
            cache.show(id, host: host)
            shown[id] = host
        }
    }

    func clear() { show([:]) }
}

/// Runs at most once every `interval` seconds, the latest wins: for
/// readings that change faster than they can be read (the network's
/// speed), which would otherwise lay the window out again each time.
@MainActor
final class NetworkThrottle {
    private let interval: Double
    private var last = Date.distantPast
    private var pending: (@MainActor () -> Void)?

    /// Nothing's run once `owner` has gone (what it would change has).
    init(_ interval: Double = 1, owner: Widget) {
        self.interval = interval
        owner.onDestroy { [self] in self.cancelled = true }
    }

    private var cancelled = false

    func run(_ body: @escaping @MainActor () -> Void) {
        guard !cancelled else { return }
        let now = Date()
        let since = now.timeIntervalSince(last)
        guard since < interval else {
            last = now
            pending = nil
            body()
            return
        }
        let waiting = pending != nil
        pending = body
        guard !waiting else { return }
        MainLoop.after(interval - since) { [self] in
            guard !self.cancelled, let pending = self.pending else { return }
            self.pending = nil
            self.last = Date()
            pending()
        }
    }
}

/// Space that pushes what follows to the end of a row (and only across).
@MainActor
func NetworkRowSpacer() -> Widget {
    Widget(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)).expand(horizontal: true)
}

/// A line of dim, wrapping explanation (the Mac's caption under a group).
@MainActor
func NetworkCaption(_ text: String) -> Label {
    Label(text, style: "caption", "dim-label").wrap().xalign(0)
}

/// A row of buttons, in a group under its rows.
@MainActor
func NetworkButtonStrip(@WidgetList _ buttons: () -> [Widget]) -> Box {
    let box = Box(.horizontal, spacing: 8, buttons)
    box.margin(top: 12)
    return box
}
