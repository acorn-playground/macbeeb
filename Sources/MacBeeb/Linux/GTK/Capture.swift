import CGtk
import Foundation

/// A widget (a window, say) drawn to a PNG, as it looks: for self-tests
/// and documentation captures (the Mac's use cacheDisplay).
@MainActor
enum Capture {
    static func png(of widget: Widget) -> Data? {
        let width = gtk_widget_get_width(widget.widget), height = gtk_widget_get_height(widget.widget)
        guard width > 0, height > 0, let native = gtk_widget_get_native(widget.widget),
              let renderer = gtk_native_get_renderer(native) else { return nil }
        let paintable = gtk_widget_paintable_new(widget.widget)!
        defer { g_object_unref(gpointer(paintable)) }
        let snapshot = gtk_snapshot_new()!
        gdk_paintable_snapshot(paintable, cast(snapshot), Double(width), Double(height))
        guard let node = gtk_snapshot_free_to_node(snapshot) else { return nil }
        defer { gsk_render_node_unref(node) }
        var viewport = graphene_rect_t(origin: graphene_point_t(x: 0, y: 0),
                                       size: graphene_size_t(width: Float(width), height: Float(height)))
        guard let texture = gsk_renderer_render_texture(renderer, node, &viewport) else { return nil }
        defer { g_object_unref(gpointer(texture)) }
        guard let bytes = gdk_texture_save_to_png_bytes(texture) else { return nil }
        defer { g_bytes_unref(bytes) }
        var size: gsize = 0
        guard let data = g_bytes_get_data(bytes, &size) else { return nil }
        return Data(bytes: data, count: Int(size))
    }

    /// The PNG after the widget's next paint, when its picture is fresh:
    /// a capture between a redraw being asked for and the paint comes back
    /// empty, which a window that's always redrawing (a live screen) often
    /// is.
    static func pngAfterPaint(of widget: Widget) async -> Data? {
        guard let clock = gtk_widget_get_frame_clock(widget.widget) else { return png(of: widget) }
        let reference = GObjectRef(clock)
        return await withCheckedContinuation { continuation in
            var finished = false
            var handler: gulong = 0
            handler = reference.on("after-paint") {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: png(of: widget))
                // (Not while the signal's being emitted.)
                MainLoop.after(0) { reference.disconnect(handler) }
            }
            gtk_widget_queue_draw(widget.widget)
        }
    }

    static func writeAfterPaint(_ widget: Widget, to path: String) async {
        if let png = await pngAfterPaint(of: widget) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    static func write(_ widget: Widget, to path: String) {
        if let png = png(of: widget) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
