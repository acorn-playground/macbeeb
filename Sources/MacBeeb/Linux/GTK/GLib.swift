import CGtk
import Foundation
import Observation

// The bridge between Swift and GLib: the main queue run from GLib's main
// loop, closures as signal handlers, and @Observable state driving widgets.

// MARK: The main loop

enum MainLoop {
    /// Runs libdispatch's main queue (and so the main actor, and
    /// DispatchQueue.main) from GLib's main loop, as Foundation's run loop
    /// does on the Mac: libdispatch pokes an eventfd when it has work.
    static func install() {
        g_unix_fd_add(_dispatch_get_main_queue_handle_4CF(), G_IO_IN, { fd, _, _ in
            var count: UInt64 = 0
            _ = read(fd, &count, 8)
            _dispatch_main_queue_callback_4CF(nil)
            return 1
        }, nil)
    }

    /// Calls `body` once after `seconds`, on the main thread.
    static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated(body)
        }
    }
}

// MARK: Closures for C

/// What every `Boxed` is, so C callbacks (which can't be generic) can
/// release one.
class AnyBox {
    /// Releases a box passed as a `gpointer` (GDestroyNotify's shape).
    static func release(_ pointer: gpointer?) {
        if let pointer { Unmanaged<AnyBox>.fromOpaque(pointer).release() }
    }
}

/// A Swift value behind a C `gpointer`, retained until GLib's destroy
/// notification releases it.
final class Boxed<T>: AnyBox {
    let value: T
    init(_ value: T) { self.value = value }

    var retained: gpointer { Unmanaged.passRetained(self).toOpaque() }

    static func from(_ pointer: gpointer?) -> T {
        Unmanaged<Boxed<T>>.fromOpaque(pointer!).takeUnretainedValue().value
    }
}

/// Connects `handler` (a C function) to `signal`, with `closure` boxed as
/// its data and released when the handler goes.
@discardableResult
private func connect<T>(_ instance: gpointer, _ signal: String, _ closure: T, after: Bool = false,
                        _ handler: GCallback) -> gulong {
    macbeeb_signal_connect(instance, signal, handler, Boxed(closure).retained, { data, _ in AnyBox.release(data) },
                           after ? 1 : 0)
}

/// A GObject (of any class), for signals, properties and data.
struct GObjectRef: @unchecked Sendable {
    let pointer: gpointer

    init(_ pointer: gpointer) { self.pointer = pointer }
    init<T>(_ pointer: UnsafeMutablePointer<T>) { self.pointer = gpointer(pointer) }
    init(_ pointer: OpaquePointer) { self.pointer = gpointer(pointer) }

    typealias Handler = @MainActor () -> Void

    /// `void handler(instance, data)`.
    @discardableResult
    func on(_ signal: String, after: Bool = false, _ body: @escaping Handler) -> gulong {
        connect(pointer, signal, body, after: after, unsafeBitCast(
            { (_: gpointer?, data: gpointer?) in nonisolated(unsafe) let data = data; return MainActor.assumeIsolated { Boxed<Handler>.from(data)() } }
                as @convention(c) (gpointer?, gpointer?) -> Void, to: GCallback.self))
    }

    /// `gboolean handler(instance, data)`: true stops the signal.
    @discardableResult
    func onStop(_ signal: String, _ body: @escaping @MainActor () -> Bool) -> gulong {
        connect(pointer, signal, body, unsafeBitCast(
            { (_: gpointer?, data: gpointer?) -> gboolean in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated { Boxed<@MainActor () -> Bool>.from(data)() ? 1 : 0 }
            } as @convention(c) (gpointer?, gpointer?) -> gboolean, to: GCallback.self))
    }

    /// `void handler(instance, pointer, data)`, the pointer given.
    @discardableResult
    func onPointer(_ signal: String, _ body: @escaping @MainActor (gpointer?) -> Void) -> gulong {
        connect(pointer, signal, body, unsafeBitCast(
            { (_: gpointer?, argument: gpointer?, data: gpointer?) in
                nonisolated(unsafe) let argument = argument; nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated { Boxed<@MainActor (gpointer?) -> Void>.from(data)(argument) }
            } as @convention(c) (gpointer?, gpointer?, gpointer?) -> Void, to: GCallback.self))
    }

    /// `void handler(instance, char *, data)`, the string given.
    @discardableResult
    func onString(_ signal: String, _ body: @escaping @MainActor (String) -> Void) -> gulong {
        onPointer(signal) { argument in
            body(argument.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? "")
        }
    }

    /// `void handler(instance, int, data)`.
    @discardableResult
    func onInt(_ signal: String, _ body: @escaping @MainActor (Int32) -> Void) -> gulong {
        connect(pointer, signal, body, unsafeBitCast(
            { (_: gpointer?, value: gint, data: gpointer?) in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated { Boxed<@MainActor (Int32) -> Void>.from(data)(value) }
            } as @convention(c) (gpointer?, gint, gpointer?) -> Void, to: GCallback.self))
    }

    /// `void handler(instance, double, double, data)` (motion, drag
    /// updates, scrolls).
    @discardableResult
    func onPoint(_ signal: String, _ body: @escaping @MainActor (Double, Double) -> Void) -> gulong {
        connect(pointer, signal, body, unsafeBitCast(
            { (_: gpointer?, x: gdouble, y: gdouble, data: gpointer?) in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated { Boxed<@MainActor (Double, Double) -> Void>.from(data)(x, y) }
            } as @convention(c) (gpointer?, gdouble, gdouble, gpointer?) -> Void, to: GCallback.self))
    }

    /// `gboolean handler(instance, double, double, data)` (scroll).
    @discardableResult
    func onPointStop(_ signal: String, _ body: @escaping @MainActor (Double, Double) -> Bool) -> gulong {
        connect(pointer, signal, body, unsafeBitCast(
            { (_: gpointer?, x: gdouble, y: gdouble, data: gpointer?) -> gboolean in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated { Boxed<@MainActor (Double, Double) -> Bool>.from(data)(x, y) ? 1 : 0 }
            } as @convention(c) (gpointer?, gdouble, gdouble, gpointer?) -> gboolean, to: GCallback.self))
    }

    /// `void handler(instance, int n, double x, double y, data)` (clicks).
    @discardableResult
    func onClick(_ signal: String, _ body: @escaping @MainActor (Int32, Double, Double) -> Void) -> gulong {
        connect(pointer, signal, body, unsafeBitCast(
            { (_: gpointer?, n: gint, x: gdouble, y: gdouble, data: gpointer?) in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated { Boxed<@MainActor (Int32, Double, Double) -> Void>.from(data)(n, x, y) }
            } as @convention(c) (gpointer?, gint, gdouble, gdouble, gpointer?) -> Void, to: GCallback.self))
    }

    /// `void handler(instance, int, int, data)` (GtkGLArea's resize).
    @discardableResult
    func onSize(_ signal: String, _ body: @escaping @MainActor (Int32, Int32) -> Void) -> gulong {
        connect(pointer, signal, body, unsafeBitCast(
            { (_: gpointer?, width: gint, height: gint, data: gpointer?) in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated { Boxed<@MainActor (Int32, Int32) -> Void>.from(data)(width, height) }
            } as @convention(c) (gpointer?, gint, gint, gpointer?) -> Void, to: GCallback.self))
    }

    /// `gboolean handler(instance, guint keyval, guint keycode, GdkModifierType, data)`.
    @discardableResult
    func onKey(_ signal: String, _ body: @escaping @MainActor (UInt32, UInt32, GdkModifierType) -> Bool) -> gulong {
        connect(pointer, signal, body, unsafeBitCast(
            { (_: gpointer?, keyval: guint, keycode: guint, state: GdkModifierType, data: gpointer?) -> gboolean in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated {
                    Boxed<@MainActor (UInt32, UInt32, GdkModifierType) -> Bool>.from(data)(keyval, keycode, state) ? 1 : 0
                }
            } as @convention(c) (gpointer?, guint, guint, GdkModifierType, gpointer?) -> gboolean, to: GCallback.self))
    }

    /// `void handler(instance, guint keyval, guint keycode, GdkModifierType, data)` (key-released).
    @discardableResult
    func onKeyUp(_ signal: String, _ body: @escaping @MainActor (UInt32, UInt32, GdkModifierType) -> Void) -> gulong {
        connect(pointer, signal, body, unsafeBitCast(
            { (_: gpointer?, keyval: guint, keycode: guint, state: GdkModifierType, data: gpointer?) in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated {
                    Boxed<@MainActor (UInt32, UInt32, GdkModifierType) -> Void>.from(data)(keyval, keycode, state)
                }
            } as @convention(c) (gpointer?, guint, guint, GdkModifierType, gpointer?) -> Void, to: GCallback.self))
    }

    /// `gboolean handler(instance, GdkModifierType, data)` (modifiers).
    @discardableResult
    func onModifiers(_ signal: String, _ body: @escaping @MainActor (GdkModifierType) -> Bool) -> gulong {
        connect(pointer, signal, body, unsafeBitCast(
            { (_: gpointer?, state: GdkModifierType, data: gpointer?) -> gboolean in
                nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated { Boxed<@MainActor (GdkModifierType) -> Bool>.from(data)(state) ? 1 : 0 }
            } as @convention(c) (gpointer?, GdkModifierType, gpointer?) -> gboolean, to: GCallback.self))
    }

    /// `gboolean handler(instance, const GValue *, double, double, data)` (drop).
    @discardableResult
    func onDrop(_ body: @escaping @MainActor (UnsafePointer<GValue>?, Double, Double) -> Bool) -> gulong {
        connect(pointer, "drop", body, unsafeBitCast(
            { (_: gpointer?, value: UnsafePointer<GValue>?, x: gdouble, y: gdouble, data: gpointer?) -> gboolean in
                nonisolated(unsafe) let value = value; nonisolated(unsafe) let data = data
                return MainActor.assumeIsolated {
                    Boxed<@MainActor (UnsafePointer<GValue>?, Double, Double) -> Bool>.from(data)(value, x, y) ? 1 : 0
                }
            } as @convention(c) (gpointer?, UnsafePointer<GValue>?, gdouble, gdouble, gpointer?) -> gboolean,
            to: GCallback.self))
    }

    /// Notified when a property changes ("notify::name").
    @discardableResult
    func onChange(_ property: String, _ body: @escaping Handler) -> gulong {
        onPointer("notify::\(property)") { _ in body() }
    }

    func disconnect(_ handler: gulong) {
        g_signal_handler_disconnect(pointer, handler)
    }

    func block(_ handler: gulong) { g_signal_handler_block(pointer, handler) }
    func unblock(_ handler: gulong) { g_signal_handler_unblock(pointer, handler) }

    // MARK: Properties

    func set(_ property: String, _ value: Bool) { macbeeb_set_bool(pointer, property, value ? 1 : 0) }
    func set(_ property: String, _ value: Int32) { macbeeb_set_int(pointer, property, value) }
    func set(_ property: String, _ value: Double) { macbeeb_set_double(pointer, property, value) }
    func set(_ property: String, _ value: String?) { macbeeb_set_string(pointer, property, value) }
    func bool(_ property: String) -> Bool { macbeeb_get_bool(pointer, property) != 0 }

    // MARK: Data

    /// Keeps `value` for as long as the object lives (released with it).
    func keep<T>(_ value: T, as key: String = UUID().uuidString) {
        g_object_set_data_full(gObject, key, Boxed(value).retained) { AnyBox.release($0) }
    }

    var gObject: UnsafeMutablePointer<GObject> { pointer.assumingMemoryBound(to: GObject.self) }

    func ref() { g_object_ref(pointer) }
    func unref() { g_object_unref(pointer) }

    /// Calls `body` when the object is finalised.
    func whenFinalised(_ body: @escaping @MainActor () -> Void) {
        g_object_weak_ref(gObject, { data, _ in
            nonisolated(unsafe) let box = data
            MainActor.assumeIsolated { Boxed<@MainActor () -> Void>.from(box)() }
            AnyBox.release(data)
        }, Boxed(body).retained)
    }
}

// MARK: Observing

/// Re-runs `body` whenever @Observable state it reads changes (on the main
/// thread, a change or a burst of them once), until `stop`.
@MainActor
final class Tracking {
    private let body: @MainActor () -> Void
    private var stopped = false
    private var scheduled = false

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        run()
    }

    private func run() {
        guard !stopped else { return }
        scheduled = false
        withObservationTracking(body) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.changed() }
            }
        }
    }

    private func changed() {
        guard !stopped, !scheduled else { return }
        scheduled = true
        run()
    }

    func stop() {
        stopped = true
    }
}

extension GObjectRef {
    /// Runs `body` now and whenever the @Observable state it reads changes,
    /// for as long as the object lives.
    @MainActor
    func track(_ body: @escaping @MainActor () -> Void) {
        let tracking = Tracking(body)
        whenFinalised { tracking.stop() }
        keep(tracking)
    }
}

// MARK: Strings and lists

extension String {
    /// A C string GLib owns (g_strdup), from a GLib function returning one
    /// to be freed.
    init?(gOwned pointer: UnsafeMutablePointer<CChar>?) {
        guard let pointer else { return nil }
        self.init(cString: pointer)
        g_free(pointer)
    }

    init?(gBorrowed pointer: UnsafePointer<CChar>?) {
        guard let pointer else { return nil }
        self.init(cString: pointer)
    }
}

/// A NULL-terminated array of C strings for GTK, for the duration of
/// `body`.
func withCStringArray<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let duplicates = strings.map { UnsafePointer(strdup($0)) }
    defer { duplicates.forEach { free(UnsafeMutableRawPointer(mutating: $0)) } }
    var array: [UnsafePointer<CChar>?] = duplicates + [nil]
    return array.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}

extension URL {
    /// A GFile for the URL (to unref).
    var gFile: OpaquePointer { g_file_new_for_path(path) }

    init?(gFile file: OpaquePointer?) {
        guard let file, let path = String(gOwned: g_file_get_path(file)) else { return nil }
        self.init(fileURLWithPath: path)
    }
}

// MARK: Casting

// GTK's casting macros, unchecked. GTK's types come into Swift as typed
// pointers or opaque ones (final classes are opaque), so these convert
// whichever way the C function wants, inferred from where they're used:
// `gtk_shortcut_controller_set_scope(cast(controller), …)`.

@inline(__always) func cast<T, U>(_ pointer: UnsafeMutablePointer<U>) -> UnsafeMutablePointer<T> {
    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self)
}

@inline(__always) func cast<T>(_ pointer: OpaquePointer) -> UnsafeMutablePointer<T> {
    UnsafeMutablePointer<T>(pointer)
}

@inline(__always) func cast<U>(_ pointer: UnsafeMutablePointer<U>) -> OpaquePointer {
    OpaquePointer(pointer)
}

@inline(__always) func cast(_ pointer: OpaquePointer) -> OpaquePointer {
    pointer
}
