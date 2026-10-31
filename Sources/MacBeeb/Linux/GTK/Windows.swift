import CGtk
import Foundation

// The application and its windows.

@MainActor
final class Application {
    static private(set) var shared: Application!

    let app: UnsafeMutablePointer<AdwApplication>

    var object: GObjectRef { GObjectRef(app) }
    private var gApplication: UnsafeMutablePointer<GApplication> {
        UnsafeMutableRawPointer(app).assumingMemoryBound(to: GApplication.self)
    }
    var gtkApplication: UnsafeMutablePointer<GtkApplication> {
        UnsafeMutableRawPointer(app).assumingMemoryBound(to: GtkApplication.self)
    }

    /// `id` is the app's reverse-DNS ID (its D-Bus name, desktop file and
    /// icon); one instance runs at a time, and files opened again go to it.
    init(id: String) {
        app = adw_application_new(id, GApplicationFlags(rawValue: 1 << 2))  // G_APPLICATION_HANDLES_OPEN
        Self.shared = self
        g_set_application_name("MacBeeb")
    }

    /// Runs the app until it quits; the exit status.
    func run(_ arguments: [String]) -> Int32 {
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var mutable = argv
        return mutable.withUnsafeMutableBufferPointer { buffer in
            g_application_run(gApplication, Int32(arguments.count), buffer.baseAddress)
        }
    }

    /// Once, as it starts (the primary instance).
    func onStartup(_ body: @escaping @MainActor () -> Void) {
        object.on("startup", body)
    }

    /// When it's launched with no files (or launched again).
    func onActivate(_ body: @escaping @MainActor () -> Void) {
        object.on("activate", body)
    }

    func onShutdown(_ body: @escaping @MainActor () -> Void) {
        object.on("shutdown", body)
    }

    /// Files to open (from the command line, the file manager, or a second
    /// launch).
    func onOpen(_ body: @escaping @MainActor ([URL]) -> Void) {
        typealias Open = @MainActor ([URL]) -> Void
        macbeeb_signal_connect(gpointer(app), "open", unsafeBitCast(
            { (_: gpointer?, files: UnsafeMutablePointer<OpaquePointer?>?, count: gint, _: UnsafePointer<CChar>?,
               data: gpointer?) in
                var urls: [URL] = []
                for index in 0..<Int(count) {
                    let file = files?[index]
                    if let file, let url = URL(gFile: file) {
                        urls.append(url)
                    } else if let file, let uri = String(gOwned: g_file_get_uri(file)), let url = URL(string: uri) {
                        urls.append(url)
                    }
                }
                MainActor.assumeIsolated { Boxed<Open>.from(data)(urls) }
            } as @convention(c) (gpointer?, UnsafeMutablePointer<OpaquePointer?>?, gint, UnsafePointer<CChar>?, gpointer?) -> Void,
            to: GCallback.self), Boxed<Open>(body).retained, { data, _ in AnyBox.release(data) }, 0)
    }

    /// Keeps it running with no windows open, until released (as the Mac
    /// app runs with only a menu bar).
    func hold() { g_application_hold(gApplication) }
    func release() { g_application_release(gApplication) }

    func quit() { g_application_quit(gApplication) }

    /// The window the user's working in.
    var activeWindow: WidgetPointer? {
        gtk_application_get_active_window(gtkApplication).map { WidgetPointer(OpaquePointer($0)) }
    }

    /// Every window open.
    var windows: [UnsafeMutablePointer<GtkWindow>] {
        var result: [UnsafeMutablePointer<GtkWindow>] = []
        var node = gtk_application_get_windows(gtkApplication)
        while let current = node {
            if let data = current.pointee.data { result.append(data.assumingMemoryBound(to: GtkWindow.self)) }
            node = current.pointee.next
        }
        return result
    }

    /// The keyboard shortcuts for an action ("win.open-disc"):
    /// "<Alt>o", "<Control><Shift>s", "F6"…
    func setAccels(_ action: String, _ accels: [String]) {
        withCStringArray(accels) { gtk_application_set_accels_for_action(gtkApplication, action, $0) }
    }

    /// An app-wide action ("app.name").
    @discardableResult
    func action(_ name: String, _ body: @escaping @MainActor () -> Void) -> Action {
        let action = Action(name, body)
        g_action_map_add_action(OpaquePointer(app), action.gAction)
        return action
    }

    /// Light or dark, following the system (libadwaita's style manager).
    func followSystemAppearance() {
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_DEFAULT)
    }
}

/// A window: libadwaita's application window, with a "win" action group.
@MainActor
class Window: Widget {
    init(title: String, width: Int32 = -1, height: Int32 = -1) {
        super.init(adw_application_window_new(Application.shared.gtkApplication))
        gtk_window_set_title(window, title)
        gtk_window_set_default_size(window, width, height)
    }

    override init(_ widget: WidgetPointer) {
        super.init(widget)
    }

    var window: UnsafeMutablePointer<GtkWindow> { ptr() }

    var content: Widget? {
        get { adw_application_window_get_content(cast(widget)).map(Widget.init) }
        set { adw_application_window_set_content(cast(widget), newValue?.widget) }
    }

    var title: String {
        get { String(gBorrowed: gtk_window_get_title(window)) ?? "" }
        set {
            guard newValue != title else { return }
            gtk_window_set_title(window, newValue)
        }
    }

    func present() {
        gtk_window_present(window)
    }

    func close() {
        gtk_window_close(window)
    }

    func destroy() {
        gtk_window_destroy(window)
    }

    var isActive: Bool { gtk_window_is_active(window) != 0 }

    /// Called when the window becomes (or stops being) the active one.
    func onActiveChanged(_ body: @escaping @MainActor (Bool) -> Void) {
        let window = self.window
        object.onChange("is-active") { body(gtk_window_is_active(window) != 0) }
    }

    /// Asked to close: true keeps it open.
    func onCloseRequest(_ body: @escaping @MainActor () -> Bool) {
        object.onStop("close-request", body)
    }

    @discardableResult
    func resizable(_ on: Bool) -> Self {
        gtk_window_set_resizable(window, on ? 1 : 0)
        return self
    }

    @discardableResult
    func minimumSize(width: Int32, height: Int32) -> Self {
        gtk_widget_set_size_request(widget, width, height)
        return self
    }

    func setDefaultSize(width: Int32, height: Int32) {
        gtk_window_set_default_size(window, width, height)
    }

    var defaultSize: (width: Int32, height: Int32) {
        var width: Int32 = 0, height: Int32 = 0
        gtk_window_get_default_size(window, &width, &height)
        return (width, height)
    }

    var isFullscreen: Bool {
        get { gtk_window_is_fullscreen(window) != 0 }
        set { if newValue { gtk_window_fullscreen(window) } else { gtk_window_unfullscreen(window) } }
    }

    var isMaximized: Bool { gtk_window_is_maximized(window) != 0 }

    /// Over `parent`, and closed with it.
    @discardableResult
    func transient(for parent: Window?, modal: Bool = false) -> Self {
        gtk_window_set_transient_for(window, parent?.window)
        gtk_window_set_modal(window, modal ? 1 : 0)
        gtk_window_set_destroy_with_parent(window, 1)
        return self
    }

    /// Hidden rather than destroyed when closed (a window kept for reuse).
    @discardableResult
    func hidesOnClose(_ on: Bool = true) -> Self {
        gtk_window_set_hide_on_close(window, on ? 1 : 0)
        return self
    }

    /// A window action ("win.name").
    @discardableResult
    func action(_ name: String, _ body: @escaping @MainActor () -> Void) -> Action {
        add(Action(name, body))
    }

    @discardableResult
    func add(_ action: Action) -> Action {
        g_action_map_add_action(OpaquePointer(widget), action.gAction)
        return action
    }

    /// A shortcut for this window alone: "<Alt>o", "F6"…
    func shortcut(_ trigger: String, action: String) {
        shortcuts([(action, [trigger])])
    }

    /// The window's own shortcuts, by action ("win.open-disc", "app.quit").
    /// They're heard as keys come back up from the focused widget (GTK's
    /// bubble phase), so a widget that takes a key first (the BBC's
    /// screen) keeps it; the menus show them through their items' accels.
    func shortcuts(_ list: [(action: String, accels: [String])]) {
        let controller = gtk_shortcut_controller_new()!
        gtk_shortcut_controller_set_scope(cast(controller), GTK_SHORTCUT_SCOPE_LOCAL)
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_BUBBLE)
        for (action, accels) in list {
            for trigger in accels {
                guard let parsed = gtk_shortcut_trigger_parse_string(trigger) else { continue }
                gtk_shortcut_controller_add_shortcut(cast(controller), gtk_shortcut_new(parsed, gtk_named_action_new(action)))
            }
        }
        gtk_widget_add_controller(widget, controller)
    }

    /// The window wrapped (for a window found by GTK).
    static func wrapping(_ pointer: UnsafeMutablePointer<GtkWindow>) -> Window {
        Window(WidgetPointer(OpaquePointer(pointer)))
    }
}

/// Windows kept by a key, so asking again brings the open one forward
/// (as SwiftUI's `openWindow(id:)` does).
@MainActor
enum Windows {
    private static var open: [String: Window] = [:]

    /// The window for `key`: the open one, or a new one from `make`.
    @discardableResult
    static func show(_ key: String, _ make: () -> Window) -> Window {
        if let window = open[key] {
            window.present()
            return window
        }
        let window = make()
        open[key] = window
        window.onDestroy { open[key] = nil }
        window.present()
        return window
    }

    static func existing(_ key: String) -> Window? {
        open[key]
    }

    static func close(_ key: String) {
        open[key]?.close()
    }
}
