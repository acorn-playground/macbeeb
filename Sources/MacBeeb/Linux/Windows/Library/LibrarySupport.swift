import BeebLibrary
import CGtk
import Foundation
import Observation

// What the Game Library's windows share: their styles, following state
// that rebuilds widgets, menus on widgets, and drawn text.

// MARK: Following state

/// Calls `changed` with `value()` now and whenever it changes. Unlike
/// `track`, `changed` runs outside the observation, so what it builds can
/// follow state of its own without rebuilding the lot.
@MainActor
final class LibraryWatch<Value: Equatable> {
    private let value: @MainActor () -> Value
    private let changed: @MainActor (Value) -> Void
    private var last: Value?
    private var stopped = false
    private var scheduled = false

    init(_ value: @escaping @MainActor () -> Value, _ changed: @escaping @MainActor (Value) -> Void) {
        self.value = value
        self.changed = changed
        run()
    }

    private func run() {
        guard !stopped else { return }
        scheduled = false
        let current = withObservationTracking(value) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.changedSoon() }
            }
        }
        guard current != last else { return }
        last = current
        changed(current)
    }

    private func changedSoon() {
        guard !stopped, !scheduled else { return }
        scheduled = true
        run()
    }

    func stop() {
        stopped = true
    }
}

extension Widget {
    /// Calls `changed` with `value()` now and whenever it changes, for as
    /// long as the widget lives (see `LibraryWatch`).
    @discardableResult
    func libraryTrack<T: Equatable>(_ value: @escaping @MainActor () -> T, _ changed: @escaping @MainActor (T) -> Void) -> Self {
        let watch = LibraryWatch(value, changed)
        object.whenFinalised { watch.stop() }
        object.keep(watch)
        return self
    }
}

// MARK: Menus on widgets

/// Actions for a widget's own menus ("prefix.name"), inserted on the
/// widget.
@MainActor
final class LibraryActions {
    let group: OpaquePointer
    let prefix: String

    @discardableResult
    init(on widget: Widget, prefix: String) {
        self.prefix = prefix
        group = OpaquePointer(g_simple_action_group_new())
        gtk_widget_insert_action_group(widget.widget, prefix, cast(group))
        g_object_unref(gpointer(group))
    }

    /// Adds a command; its menu item names "prefix.name".
    @discardableResult
    func add(_ name: String, _ body: @escaping @MainActor () -> Void) -> String {
        let action = Action(name, body)
        g_action_map_add_action(group, action.gAction)
        g_object_unref(gpointer(action.gAction))
        return "\(prefix).\(name)"
    }
}

extension Widget {
    /// A context menu (a secondary click or a long press), made when it's
    /// asked for, so it says what's true then.
    @discardableResult
    func libraryContextMenu(_ menu: @escaping @MainActor () -> Menu) -> Self {
        let target = self
        // One popover, its menu replaced each time.
        let holder = LibraryPopoverHolder()
        let open: LibraryMenuOpener = { x, y in
            let made = menu()
            if let popover = holder.popover {
                gtk_popover_menu_set_menu_model(cast(popover.widget), UnsafeMutablePointer(made.model))
            } else {
                let popover = Popover(menu: made)
                gtk_popover_set_has_arrow(cast(popover.widget), 1)
                holder.popover = popover
            }
            // (The popover holds the menu now.)
            g_object_unref(gpointer(made.model))
            holder.popover?.show(on: target, at: x, y: y)
        }
        object.keep(open, as: Self.contextMenuKey)
        object.keep(holder, as: Self.contextMenuKey + "-holder")
        onContextClick(open)
        // From the keyboard: the Menu key, or Shift-F10.
        let keys = KeyController()
        keys.onPressed { keyval, _, modifiers in
            let shift = modifiers.rawValue & GDK_SHIFT_MASK.rawValue != 0
            guard keyval == UInt32(GDK_KEY_Menu) || (keyval == UInt32(GDK_KEY_F10) && shift) else { return false }
            open(Double(target.width) / 2, Double(target.height) / 2)
            return true
        }
        add(keys)
        return self
    }

    /// Opens the widget's context menu (as the Menu key would); its
    /// popover.
    @discardableResult
    func openLibraryContextMenu() -> Popover? {
        guard let data = g_object_get_data(object.gObject, Self.contextMenuKey) else { return nil }
        Boxed<LibraryMenuOpener>.from(data)(Double(width) / 2, Double(height) / 2)
        return g_object_get_data(object.gObject, Self.contextMenuKey + "-holder")
            .map { Boxed<LibraryPopoverHolder>.from($0).popover } ?? nil
    }

    private static var contextMenuKey: String { "macbeeb-library-context-menu" }
}

typealias LibraryMenuOpener = @MainActor (Double, Double) -> Void

@MainActor
final class LibraryPopoverHolder {
    var popover: Popover?
}

// MARK: Drawn text

@MainActor
enum LibraryText {
    struct Colour {
        var red, green, blue, alpha: Double
        init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    /// Text in `width`, wrapped, with its top left at (x, y); its height.
    @discardableResult
    static func draw(_ cairo: Cairo, _ text: String, font: String, colour: Colour, x: Double, y: Double, width: Double,
                     alignment: PangoAlignment = PANGO_ALIGN_LEFT, measureOnly: Bool = false) -> Double {
        let layout = pango_cairo_create_layout(cairo.context)!
        defer { g_object_unref(gpointer(layout)) }
        let description = pango_font_description_from_string(font)
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, text, -1)
        pango_layout_set_width(layout, Int32(width * Double(PANGO_SCALE)))
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
        pango_layout_set_alignment(layout, alignment)
        var textWidth: Int32 = 0, height: Int32 = 0
        pango_layout_get_pixel_size(layout, &textWidth, &height)
        if !measureOnly {
            cairo.color(colour.red, colour.green, colour.blue, colour.alpha)
            cairo.move(x, y)
            pango_cairo_show_layout(cairo.context, layout)
        }
        return Double(height)
    }

    /// A vertical gradient filling the current path.
    static func fillGradient(_ cairo: Cairo, top: Colour, bottom: Colour, height: Double) {
        let pattern = cairo_pattern_create_linear(0, 0, 0, height)!
        cairo_pattern_add_color_stop_rgba(pattern, 0, top.red, top.green, top.blue, top.alpha)
        cairo_pattern_add_color_stop_rgba(pattern, 1, bottom.red, bottom.green, bottom.blue, bottom.alpha)
        cairo_set_source(cairo.context, pattern)
        cairo_fill(cairo.context)
        cairo_pattern_destroy(pattern)
    }
}

// MARK: Dates

enum LibraryDates {
    /// "Thu 22 Oct, 14:32".
    static let snapshotFormat = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()

    static func snapshot(_ date: Date) -> String {
        date.formatted(snapshotFormat)
    }

    /// For screen readers: "22 Oct 2026 at 14:32".
    static func spoken(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: Styles, and what the library needs set up

@MainActor
enum LibraryStyles {
    private static var installed = false

    /// The library's styles, and GDK deciding which pictures can be
    /// covers (so pictures it can't show are refused, as on the Mac).
    static func install() {
        guard !installed else { return }
        installed = true
        MyGames.coverDecodes = { data in PlatformImage(encoded: data) != nil }
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }

    private static let css = """
    /* The shelves: the grid's children are plain, their tiles show
       what's selected, focused, hovered or dropped on. */
    flowbox.shelf > flowboxchild {
        padding: 0;
        background: none;
        outline: none;
        border-radius: 14px;
    }
    flowbox.shelf > flowboxchild > clamp > .shelf-tile {
        padding: 10px 8px 8px 8px;
        border-radius: 14px;
        outline: 0 solid transparent;
        outline-offset: -2px;
        transition: background-color 150ms ease-out, outline-color 200ms ease-out;
    }
    flowbox.shelf > flowboxchild:hover > clamp > .shelf-tile {
        background-color: color-mix(in srgb, currentColor 5%, transparent);
    }
    flowbox.shelf > flowboxchild:selected > clamp > .shelf-tile {
        background-color: color-mix(in srgb, var(--accent-bg-color) 25%, transparent);
    }
    flowbox.shelf > flowboxchild:selected:hover > clamp > .shelf-tile {
        background-color: color-mix(in srgb, var(--accent-bg-color) 32%, transparent);
    }
    flowbox.shelf > flowboxchild:focus-visible > clamp > .shelf-tile {
        outline-color: color-mix(in srgb, var(--accent-color) 50%, transparent);
        outline-width: 2px;
    }
    flowbox.shelf > flowboxchild > clamp > .shelf-tile.drop-hover {
        background-color: color-mix(in srgb, var(--accent-bg-color) 30%, transparent);
    }

    /* Covers: rounded, standing out from the shelf, old box scans given
       a little more colour and contrast. */
    .shelf-cover {
        border-radius: 4px;
        box-shadow: 0 1px 2px alpha(black, 0.18), 0 4px 10px alpha(black, 0.28);
        transition: transform 400ms cubic-bezier(0.34, 1.56, 0.64, 1), filter 300ms ease-out;
    }
    .shelf-cover.pop { filter: saturate(1.2) contrast(1.1); }
    .shelf-cover.pop.not-installed { filter: saturate(1.2) contrast(1.1) brightness(0.94); }
    .shelf-cover.just-installed { transform: scale(1.04); }

    .shelf-tile .tile-title { font-weight: 700; }
    .shelf-tile .tile-status { font-size: 0.82em; }
    .shelf-tile button.tile-link {
        padding: 0 4px;
        min-height: 0;
        font-size: 0.82em;
        color: var(--accent-color);
    }
    .shelf-tile button.tile-link:hover { text-decoration: underline; }

    /* The empty book that adds a game. */
    .add-game-well {
        border: 2px dashed color-mix(in srgb, currentColor 50%, transparent);
        border-radius: 8px;
        color: color-mix(in srgb, currentColor 60%, transparent);
        transition: border-color 150ms ease-out, background-color 150ms ease-out;
    }
    .shelf-tile.drop-hover .add-game-well, .add-game-well.drop-hover {
        border-color: var(--accent-color);
        background-color: color-mix(in srgb, var(--accent-bg-color) 12%, transparent);
    }

    .library-header .library-subtitle { font-size: 1.15em; }
    /* Links flush with the text around them. */
    button.link.library-link { padding-left: 0; padding-right: 0; }
    .library-credit { font-size: 0.92em; }

    /* A command typed to start a game: in the BBC's own type. */
    row.command-row .subtitle { font-family: monospace; }

    /* The details panel's smaller actions, as links. */
    .library-details button.detail-link {
        padding: 2px 6px;
        min-height: 24px;
        font-weight: normal;
        color: var(--accent-color);
    }

    /* Snapshots: screenshots to carry on from. */
    button.snapshot-card {
        padding: 0;
        background: none;
        border-radius: 8px;
    }
    button.snapshot-card .snapshot-picture {
        border-radius: 6px;
        background-color: black;
        box-shadow: 0 0 0 1px color-mix(in srgb, currentColor 18%, transparent);
        transition: box-shadow 150ms ease-out;
    }
    button.snapshot-card:hover .snapshot-picture,
    button.snapshot-card:focus-visible .snapshot-picture {
        box-shadow: 0 0 0 2px var(--accent-color);
    }
    button.snapshot-card .snapshot-play {
        padding: 10px;
        border-radius: 999px;
        color: white;
        background-color: alpha(black, 0.55);
        opacity: 0;
        transition: opacity 150ms ease-out;
    }
    button.snapshot-card:hover .snapshot-play,
    button.snapshot-card:focus-visible .snapshot-play { opacity: 1; }

    /* The game details dialog's cover well. */
    button.cover-well {
        padding: 4px;
        border: 1.5px dashed color-mix(in srgb, currentColor 30%, transparent);
        border-radius: 8px;
        background: none;
    }
    button.cover-well:hover { background-color: color-mix(in srgb, currentColor 5%, transparent); }
    button.cover-well.drop-hover { border-color: var(--accent-color); }
    textview.notes-view, textview.notes-view > text { background: none; }
    """
}

/// Breakpoints changing properties (libadwaita's setters).
@MainActor
enum LibraryBreakpoints {
    static func make(_ condition: String) -> OpaquePointer {
        macbeeb_breakpoint(condition)!
    }

    static func set(_ breakpoint: OpaquePointer, _ widget: Widget, _ property: String, _ value: Bool) {
        macbeeb_library_breakpoint_set_bool(breakpoint, gpointer(widget.widget), property, value ? 1 : 0)
    }

    static func set(_ breakpoint: OpaquePointer, _ widget: Widget, _ property: String, _ value: String) {
        macbeeb_library_breakpoint_set_string(breakpoint, gpointer(widget.widget), property, value)
    }

    static func add(_ breakpoint: OpaquePointer, to window: Window) {
        adw_application_window_add_breakpoint(cast(window.widget), breakpoint)
    }
}
