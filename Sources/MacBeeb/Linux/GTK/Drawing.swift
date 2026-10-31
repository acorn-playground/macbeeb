import CGtk
import Foundation

// Drawn widgets: Cairo drawing areas, OpenGL areas, and text views.

/// A widget drawn with Cairo: `draw` gets a context and the size.
final class DrawingArea: Widget {
    typealias Draw = @MainActor (Cairo, Double, Double) -> Void

    init(width: Int32 = -1, height: Int32 = -1, _ draw: @escaping Draw) {
        super.init(gtk_drawing_area_new())
        if width > 0 { gtk_drawing_area_set_content_width(cast(widget), width) }
        if height > 0 { gtk_drawing_area_set_content_height(cast(widget), height) }
        setDraw(draw)
    }

    func setDraw(_ draw: @escaping Draw) {
        gtk_drawing_area_set_draw_func(cast(widget), { _, cairo, width, height, data in
            guard let cairo else { return }
            MainActor.assumeIsolated { Boxed<Draw>.from(data)(Cairo(cairo), Double(width), Double(height)) }
        }, Boxed<Draw>(draw).retained, { AnyBox.release($0) })
    }

    @discardableResult
    func contentSize(width: Int32? = nil, height: Int32? = nil) -> Self {
        if let width { gtk_drawing_area_set_content_width(cast(widget), width) }
        if let height { gtk_drawing_area_set_content_height(cast(widget), height) }
        return self
    }
}

/// Cairo drawing, with Pango for text.
@MainActor
struct Cairo {
    let context: OpaquePointer

    init(_ context: OpaquePointer) {
        self.context = context
    }

    func save() { cairo_save(context) }
    func restore() { cairo_restore(context) }

    func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        cairo_set_source_rgba(context, red, green, blue, alpha)
    }

    /// 0xRRGGBB.
    func color(hex: UInt32, alpha: Double = 1) {
        color(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    /// The widget's foreground colour (the theme's text), at `alpha`.
    func foreground(of widget: Widget, alpha: Double = 1) {
        var rgba = GdkRGBA()
        gtk_widget_get_color(widget.widget, &rgba)
        color(Double(rgba.red), Double(rgba.green), Double(rgba.blue), Double(rgba.alpha) * alpha)
    }

    /// The theme's accent colour.
    func accent(alpha: Double = 1) {
        var rgba = adw_style_manager_get_accent_color_rgba(adw_style_manager_get_default())!
        color(Double(rgba.pointee.red), Double(rgba.pointee.green), Double(rgba.pointee.blue), alpha)
        gdk_rgba_free(rgba)
        _ = rgba
    }

    func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        cairo_rectangle(context, x, y, width, height)
    }

    func roundedRectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double, radius: Double) {
        let r = min(radius, width / 2, height / 2)
        cairo_new_sub_path(context)
        cairo_arc(context, x + width - r, y + r, r, -Double.pi / 2, 0)
        cairo_arc(context, x + width - r, y + height - r, r, 0, Double.pi / 2)
        cairo_arc(context, x + r, y + height - r, r, Double.pi / 2, Double.pi)
        cairo_arc(context, x + r, y + r, r, Double.pi, 3 * Double.pi / 2)
        cairo_close_path(context)
    }

    func circle(_ x: Double, _ y: Double, radius: Double) {
        cairo_new_sub_path(context)
        cairo_arc(context, x, y, radius, 0, 2 * Double.pi)
    }

    func move(_ x: Double, _ y: Double) { cairo_move_to(context, x, y) }
    func line(_ x: Double, _ y: Double) { cairo_line_to(context, x, y) }
    func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) {
        cairo_curve_to(context, x1, y1, x2, y2, x3, y3)
    }

    func fill() { cairo_fill(context) }
    func fillPreserve() { cairo_fill_preserve(context) }
    func stroke(width: Double = 1) {
        cairo_set_line_width(context, width)
        cairo_stroke(context)
    }

    func dash(_ lengths: [Double]) {
        cairo_set_dash(context, lengths, Int32(lengths.count), 0)
    }

    func paint() { cairo_paint(context) }
    func clip() { cairo_clip(context) }

    func translate(_ x: Double, _ y: Double) { cairo_translate(context, x, y) }
    func scale(_ x: Double, _ y: Double) { cairo_scale(context, x, y) }

    /// Text drawn with its top left at (x, y). `font` is Pango's: "Monospace
    /// 10", "Sans Bold 9", "Cantarell 11"… Returns its size.
    @discardableResult
    func text(_ string: String, x: Double, y: Double, font: String = "Sans 10", width: Double? = nil,
              alignment: PangoAlignment = PANGO_ALIGN_LEFT) -> (width: Double, height: Double) {
        let layout = Self.layout(context, string, font: font, width: width, alignment: alignment)
        defer { g_object_unref(gpointer(layout)) }
        cairo_move_to(context, x, y)
        pango_cairo_show_layout(context, layout)
        return Self.size(layout)
    }

    /// The size text would be.
    func measure(_ string: String, font: String = "Sans 10", width: Double? = nil) -> (width: Double, height: Double) {
        let layout = Self.layout(context, string, font: font, width: width, alignment: PANGO_ALIGN_LEFT)
        defer { g_object_unref(gpointer(layout)) }
        return Self.size(layout)
    }

    private static func layout(_ context: OpaquePointer, _ string: String, font: String, width: Double?,
                               alignment: PangoAlignment) -> OpaquePointer {
        let layout = pango_cairo_create_layout(context)!
        let description = pango_font_description_from_string(font)
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, string, -1)
        if let width {
            pango_layout_set_width(layout, Int32(width * Double(PANGO_SCALE)))
            pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
        }
        pango_layout_set_alignment(layout, alignment)
        return layout
    }

    private static func size(_ layout: OpaquePointer) -> (width: Double, height: Double) {
        var width: Int32 = 0, height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        return (Double(width), Double(height))
    }

    /// A picture drawn into a rectangle.
    func image(_ image: PlatformImage, x: Double, y: Double, width: Double, height: Double, smooth: Bool = true) {
        guard let surface = image.cairoSurface else { return }
        save()
        rectangle(x, y, width, height)
        clip()
        translate(x, y)
        scale(width / Double(image.width), height / Double(image.height))
        cairo_set_source_surface(context, surface, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(context), smooth ? CAIRO_FILTER_GOOD : CAIRO_FILTER_NEAREST)
        paint()
        restore()
    }
}

/// An OpenGL area (the emulator's picture).
final class GLArea: Widget {
    init() {
        super.init(gtk_gl_area_new())
        // GL 3.2 core, or GLES 3.0: GTK picks.
        gtk_gl_area_set_required_version(cast(widget), 3, 2)
        gtk_gl_area_set_has_depth_buffer(cast(widget), 0)
        gtk_gl_area_set_auto_render(cast(widget), 1)
    }

    func makeCurrent() {
        gtk_gl_area_make_current(cast(widget))
    }

    var hasError: Bool { gtk_gl_area_get_error(cast(widget)) != nil }

    var errorMessage: String? {
        gtk_gl_area_get_error(cast(widget)).map { String(cString: $0.pointee.message) }
    }

    func queueRender() {
        gtk_gl_area_queue_render(cast(widget))
    }

    func onRealize(_ body: @escaping @MainActor () -> Void) {
        object.on("realize", after: true, body)
    }

    func onUnrealize(_ body: @escaping @MainActor () -> Void) {
        object.on("unrealize", body)
    }

    /// Draw: true when drawn.
    func onRender(_ body: @escaping @MainActor () -> Bool) {
        typealias Render = @MainActor () -> Bool
        macbeeb_signal_connect(gpointer(widget), "render", unsafeBitCast(
            { (_: gpointer?, _: gpointer?, data: gpointer?) -> gboolean in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated { Boxed<Render>.from(data)() ? 1 : 0 }
            } as @convention(c) (gpointer?, gpointer?, gpointer?) -> gboolean, to: GCallback.self),
            Boxed<Render>(body).retained, { data, _ in AnyBox.release(data) }, 0)
    }

    /// The size in device pixels.
    func onResize(_ body: @escaping @MainActor (Int32, Int32) -> Void) {
        object.onSize("resize", body)
    }

    /// Device pixels per logical pixel.
    var scale: Int32 { gtk_widget_get_scale_factor(widget) }
}

/// Text, many lines of it, perhaps editable.
final class TextView: Widget {
    init(text: String = "", editable: Bool = false, monospace: Bool = false) {
        super.init(gtk_text_view_new())
        gtk_text_view_set_editable(cast(widget), editable ? 1 : 0)
        gtk_text_view_set_cursor_visible(cast(widget), editable ? 1 : 0)
        gtk_text_view_set_wrap_mode(cast(widget), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_monospace(cast(widget), monospace ? 1 : 0)
        self.text = text
    }

    var buffer: UnsafeMutablePointer<GtkTextBuffer> { gtk_text_view_get_buffer(cast(widget)) }

    var text: String {
        get {
            var start = GtkTextIter(), end = GtkTextIter()
            gtk_text_buffer_get_bounds(buffer, &start, &end)
            return String(gOwned: gtk_text_buffer_get_text(buffer, &start, &end, 0)) ?? ""
        }
        set {
            guard newValue != text else { return }
            gtk_text_buffer_set_text(buffer, newValue, -1)
        }
    }

    /// Appends text, in a named tag's style (see `tag`).
    func append(_ string: String, tag: String? = nil) {
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        if let tag {
            withCStringArray([tag]) { names in
                gtk_text_buffer_insert_with_tags_by_name_shim(buffer, &end, string, names[0])
            }
        } else {
            gtk_text_buffer_insert(buffer, &end, string, -1)
        }
    }

    /// A named style for `append`: Pango properties, as "weight" (700
    /// bold), "scale" (1.4), "family" ("monospace"), "foreground"
    /// ("#888"), "pixels-above-lines" (8)…
    func tag(_ name: String, _ properties: [String: Any]) {
        let tag = gtk_text_tag_new(name)!
        let object = GObjectRef(tag)
        for (key, value) in properties {
            switch value {
            case let v as Int: object.set(key, Int32(v))
            case let v as Double: object.set(key, v)
            case let v as Bool: object.set(key, v)
            case let v as String: object.set(key, v)
            default: break
            }
        }
        gtk_text_tag_table_add(gtk_text_buffer_get_tag_table(buffer), tag)
        g_object_unref(gpointer(tag))
    }

    @discardableResult
    func margins(_ value: Int32) -> Self {
        gtk_text_view_set_left_margin(cast(widget), value)
        gtk_text_view_set_right_margin(cast(widget), value)
        gtk_text_view_set_top_margin(cast(widget), value)
        gtk_text_view_set_bottom_margin(cast(widget), value)
        return self
    }

    @discardableResult
    func onChanged(_ body: @escaping @MainActor (String) -> Void) -> Self {
        let view = self
        GObjectRef(buffer).on("changed") { body(view.text) }
        return self
    }
}

/// Inserts text with one tag (GTK's own is variadic).
@MainActor
private func gtk_text_buffer_insert_with_tags_by_name_shim(_ buffer: UnsafeMutablePointer<GtkTextBuffer>, _ iter: UnsafeMutablePointer<GtkTextIter>,
                                                          _ text: String, _ tag: UnsafePointer<CChar>?) {
    let start = gtk_text_buffer_create_mark(buffer, nil, iter, 1)
    gtk_text_buffer_insert(buffer, iter, text, -1)
    var from = GtkTextIter()
    gtk_text_buffer_get_iter_at_mark(buffer, &from, start)
    gtk_text_buffer_apply_tag_by_name(buffer, tag, &from, iter)
    gtk_text_buffer_delete_mark(buffer, start)
}
