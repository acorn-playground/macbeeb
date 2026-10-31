import CGtk
import Foundation

/// A scrolling view of rows of the same height, drawn with Cairo and Pango
/// (the disassembly, memory, trace, listing…): fast to redraw many times a
/// second, as the machine runs.
///
/// It's drawn as big as what's in view, and no bigger: a spacer as tall as
/// all the rows gives the scrolled window its extent (so it scrolls as any
/// other does, kinetically, with its overlay scrollbars), and the drawing
/// area is kept over the part in view (by its overlay's child position),
/// drawing the rows there.
@MainActor
final class CodeCanvas {
    let area: DrawingArea
    let scroller: ScrolledWindow
    private let extent: Widget
    private let overlay: Overlay
    /// The view's own top and bottom margin.
    let padding: Double
    private(set) var rowHeight: Double
    private(set) var rowCount = 0
    /// Where the drawing area is, in the rows' coordinates.
    private var placedTop = 0.0

    /// Draws row `row` with its top at `y` (in the drawing area), in a view
    /// `width` wide.
    var drawRow: (@MainActor (TextPainter, Palette, Int, Double, Double) -> Void)?
    /// A press on a row: (row, x, y, presses, button, modifiers), x and y in
    /// the drawing area. The row is -1 for a press below the last.
    var onPress: (@MainActor (Int, Double, Double, Int32, UInt32, GdkModifierType) -> Void)?
    /// A row's tooltip at x, if it has one there.
    var tooltip: (@MainActor (Int, Double) -> String?)?
    /// The pointer's cursor at x over a row ("pointer" over a gutter).
    var cursor: (@MainActor (Int, Double) -> String?)?

    private var pendingScroll: (@MainActor () -> Bool)?
    private var shownCursor: String?

    init(rowHeight: Double, padding: Double = 4) {
        self.rowHeight = rowHeight
        self.padding = padding
        area = DrawingArea { _, _, _ in }
        extent = Widget(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        extent.expand(horizontal: true, vertical: true)
        overlay = Overlay(extent)
        overlay.add(area)
        scroller = ScrolledWindow(overlay, horizontal: GTK_POLICY_NEVER, vertical: GTK_POLICY_AUTOMATIC)
        scroller.expand()
        area.setDraw { [unowned self] cairo, width, height in
            self.draw(cairo, width: width, height: height)
        }

        // The drawing area over what's in view.
        typealias Place = @MainActor () -> GdkRectangle
        let place: Place = { [unowned self] in self.placement() }
        macbeeb_signal_connect(gpointer(overlay.widget), "get-child-position", unsafeBitCast(
            { (_: gpointer?, _: gpointer?, allocation: UnsafeMutablePointer<GdkRectangle>?, data: gpointer?) -> gboolean in
                nonisolated(unsafe) let allocation = allocation, data = data
                return MainActor.assumeIsolated {
                    guard let allocation else { return 0 }
                    allocation.pointee = Boxed<Place>.from(data)()
                    return 1
                }
            } as @convention(c) (gpointer?, gpointer?, UnsafeMutablePointer<GdkRectangle>?, gpointer?) -> gboolean,
            to: GCallback.self),
            Boxed<Place>(place).retained, { data, _ in AnyBox.release(data) }, 0)
        let adjustment = GObjectRef(scroller.vadjustment)
        let view = area, holder = overlay
        adjustment.on("value-changed") {
            gtk_widget_queue_allocate(holder.widget)
            view.queueDraw()
        }
        adjustment.on("changed") { [unowned self] in
            // (Laid out: a scroll waiting for that can go, after the layout:
            // a scroll during it leaves the view where it was.)
            if self.pendingScroll != nil {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let pending = self.pendingScroll, pending() else { return }
                        self.pendingScroll = nil
                    }
                }
            }
            gtk_widget_queue_allocate(holder.widget)
            view.queueDraw()
        }

        let click = ClickGesture(button: 0)
        click.onPressed { [unowned self] presses, x, y in
            view.grabFocus()
            self.onPress?(self.row(at: y), x, y, presses, click.currentButton, click.modifiers)
        }
        area.add(click)

        // The keyboard scrolls it, as a text view's would.
        area.focusable(true).style("debugger-canvas")
        let keys = KeyController()
        keys.onPressed { [unowned self] key, _, modifiers in
            guard modifiers.rawValue & (GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue) == 0 else { return false }
            let page = gtk_adjustment_get_page_size(self.adjustment)
            let value = gtk_adjustment_get_value(self.adjustment)
            let target: Double
            switch Int32(key) {
            case GDK_KEY_Up, GDK_KEY_KP_Up: target = value - self.rowHeight
            case GDK_KEY_Down, GDK_KEY_KP_Down: target = value + self.rowHeight
            case GDK_KEY_Page_Up, GDK_KEY_KP_Page_Up: target = value - max(self.rowHeight, page - self.rowHeight)
            case GDK_KEY_Page_Down, GDK_KEY_KP_Page_Down, GDK_KEY_space: target = value + max(self.rowHeight, page - self.rowHeight)
            case GDK_KEY_Home, GDK_KEY_KP_Home: target = 0
            case GDK_KEY_End, GDK_KEY_KP_End: target = self.contentHeight
            default: return false
            }
            gtk_adjustment_set_value(self.adjustment, max(0, min(target, gtk_adjustment_get_upper(self.adjustment) - page)))
            return true
        }
        area.add(keys)

        let motion = MotionController()
        motion.onMotion { [unowned self] x, y in
            let name = self.cursor?(self.row(at: y), x)
            if name != self.shownCursor {
                self.shownCursor = name
                view.cursor(name)
            }
        }
        area.add(motion)

        gtk_widget_set_has_tooltip(area.widget, 1)
        typealias Query = @MainActor (Double, Double) -> (String, GdkRectangle)?
        let query: Query = { [unowned self] x, y in
            let row = self.row(at: y)
            guard row >= 0, let text = self.tooltip?(row, x) else { return nil }
            return (text, GdkRectangle(x: 0, y: Int32(self.localTop(of: row).rounded(.down)), width: Int32(view.width),
                                       height: Int32(self.rowHeight.rounded(.up))))
        }
        macbeeb_signal_connect(gpointer(area.widget), "query-tooltip", unsafeBitCast(
            { (_: gpointer?, x: gint, y: gint, _: gboolean, tooltip: OpaquePointer?, data: gpointer?) -> gboolean in
                nonisolated(unsafe) let tooltip = tooltip, data = data
                return MainActor.assumeIsolated {
                    guard let tooltip, let (text, area) = Boxed<Query>.from(data)(Double(x), Double(y)) else { return 0 }
                    gtk_tooltip_set_text(tooltip, text)
                    var rect = area
                    gtk_tooltip_set_tip_area(tooltip, &rect)
                    return 1
                }
            } as @convention(c) (gpointer?, gint, gint, gboolean, OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self),
            Boxed<Query>(query).retained, { data, _ in AnyBox.release(data) }, 0)

        // Light or dark, the accent or the font changed.
        let observer = NotificationCenter.default.addObserver(forName: DebuggerStyles.themeChanged, object: nil,
                                                              queue: .main) { _ in
            MainActor.assumeIsolated { view.queueDraw() }
        }
        area.onDestroy { NotificationCenter.default.removeObserver(observer) }
        // (The view keeps its canvas.)
        area.keep(self)
    }

    /// The canvas, in its scrolled window, as a widget.
    var widget: Widget { scroller }

    private var adjustment: UnsafeMutablePointer<GtkAdjustment> { cast(scroller.vadjustment) }

    /// Where the drawing area goes: over what's in view (a pixel more, for
    /// a scroll position between pixels).
    private func placement() -> GdkRectangle {
        let height = Double(overlay.height)
        let page = gtk_adjustment_get_page_size(adjustment)
        let shown = page > 0 ? min(page, height) : height
        let top = max(0, min(gtk_adjustment_get_value(adjustment), height - shown)).rounded(.down)
        placedTop = top
        return GdkRectangle(x: 0, y: Int32(top), width: overlay.width, height: Int32(min(shown + 1, height - top).rounded(.up)))
    }

    /// The row at y (in the drawing area), or -1 if there's none there.
    func row(at y: Double) -> Int {
        let row = Int(floor((y + placedTop - padding) / rowHeight))
        return row >= 0 && row < rowCount ? row : -1
    }

    /// The top of row `row`, among all the rows.
    func top(of row: Int) -> Double {
        padding + Double(row) * rowHeight
    }

    /// The top of row `row` in the drawing area (to point a popover at it).
    func localTop(of row: Int) -> Double {
        top(of: row) - placedTop
    }

    var contentHeight: Double { (Double(rowCount) * rowHeight + 2 * padding).rounded(.up) }

    /// Shows `count` rows, redrawing.
    func setRows(_ count: Int, rowHeight: Double? = nil) {
        if let rowHeight { self.rowHeight = rowHeight }
        if count != rowCount || rowHeight != nil {
            rowCount = count
            extent.size(height: Int32(contentHeight))
        }
        area.queueDraw()
    }

    func redraw() { area.queueDraw() }

    /// Scrolls row `row` into view, `anchor` of the way down (0 the top, 1
    /// the bottom); `onlyIfHidden` leaves it be if it's already in view.
    func scroll(to row: Int, anchor: Double, onlyIfHidden: Bool = false) {
        pendingScroll = { [unowned self] in
            let adjustment = self.adjustment
            let page = gtk_adjustment_get_page_size(adjustment)
            // Not laid out yet: when it is.
            guard page > 0, gtk_adjustment_get_upper(adjustment) >= self.contentHeight - 1 else { return false }
            let top = self.top(of: row)
            let value = gtk_adjustment_get_value(adjustment)
            if onlyIfHidden && top >= value && top + self.rowHeight <= value + page { return true }
            let target = top - anchor * (page - self.rowHeight)
            gtk_adjustment_set_value(adjustment, max(0, min(target, self.contentHeight - page)))
            return true
        }
        if let pending = pendingScroll, pending() { pendingScroll = nil }
    }

    func scrollToEnd() {
        guard rowCount > 0 else { return }
        scroll(to: rowCount - 1, anchor: 1)
    }

    /// Whether the last row is in view (so new rows should keep it there).
    var isAtEnd: Bool {
        let page = gtk_adjustment_get_page_size(adjustment)
        return page <= 0 || gtk_adjustment_get_value(adjustment) + page >= contentHeight - rowHeight
    }

    private func draw(_ cairo: Cairo, width: Double, height: Double) {
        guard let drawRow, rowCount > 0 else { return }
        let first = max(0, Int(floor((placedTop - padding) / rowHeight)))
        let last = min(rowCount - 1, Int(ceil((placedTop + height - padding) / rowHeight)))
        guard first <= last else { return }
        let palette = Palette(area)
        TextPainter.paint(cairo) { painter in
            for row in first...last {
                drawRow(painter, palette, row, self.top(of: row) - self.placedTop, width)
            }
        }
    }
}
