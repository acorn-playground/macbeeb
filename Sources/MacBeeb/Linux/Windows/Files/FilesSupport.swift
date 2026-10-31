import BeebCore
import CGtk
import Foundation

// What the disc contents window and the Print Centre share: their styles,
// file choosers with their own button labels, and GLib signals of shapes
// the GTK layer hasn't got.

@MainActor
enum FilesStyles {
    private static var installed = false

    /// The windows' own CSS (once).
    static func install() {
        guard !installed else { return }
        installed = true
        let css = """
        .macbeeb-desk { background-color: color-mix(in srgb, var(--window-bg-color) 87%, black); }
        listview.macbeeb-pages, listview.macbeeb-pages > row,
        listview.macbeeb-pages > row:hover, listview.macbeeb-pages > row:selected { background: none; }
        listview.macbeeb-pages > row { padding: 9px 24px; }
        listview.macbeeb-pages > row:first-child { padding-top: 24px; }
        .card.macbeeb-paper {
            border-radius: 3px;
            background-color: white;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.22), 0 3px 12px rgba(0, 0, 0, 0.14);
        }
        .macbeeb-mono text { font-family: monospace; }
        columnview.macbeeb-files cell { padding-top: 3px; padding-bottom: 3px; }
        .macbeeb-files-bar { padding: 4px 12px; }
        .macbeeb-files-bar button.flat { padding: 2px 6px; min-height: 24px; }
        .macbeeb-job-row { padding: 6px 4px; }
        .macbeeb-zoom { margin: 18px; border-radius: 9999px; padding: 3px; }
        .macbeeb-zoom button { min-width: 34px; min-height: 34px; border-radius: 9999px; }
        """
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}

// MARK: File choosers

/// (Outside the main actor's types, as C callbacks must be.)
private func filesDialogFinished(_ source: UnsafeMutablePointer<GObject>?, _ result: OpaquePointer?, _ data: gpointer?) {
    guard let source, let result else { return }
    let dialog = UInt(bitPattern: source), outcome = UInt(bitPattern: result), box = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        Boxed<FilesDialogs.Done>.from(UnsafeMutableRawPointer(bitPattern: box))(OpaquePointer(bitPattern: dialog)!,
                                                                               OpaquePointer(bitPattern: outcome)!)
    }
    AnyBox.release(data)
}

/// GTK's file dialog (the desktop's chooser), with a title and the
/// accepting button's label as the Mac's panels have their prompts.
@MainActor
enum FilesDialogs {
    typealias Done = @MainActor (OpaquePointer, OpaquePointer) -> Void

    private static func dialog(title: String, accept: String) -> OpaquePointer {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        gtk_file_dialog_set_accept_label(dialog, accept)
        gtk_file_dialog_set_modal(dialog, 1)
        return dialog
    }

    private static func urls(_ files: OpaquePointer?) -> [URL] {
        guard let files else { return [] }
        var urls: [URL] = []
        for index in 0..<g_list_model_get_n_items(files) {
            if let file = g_list_model_get_item(files, index) {
                if let url = URL(gFile: OpaquePointer(file)) { urls.append(url) }
                g_object_unref(file)
            }
        }
        g_object_unref(gpointer(files))
        return urls
    }

    private static func window(_ parent: Window?) -> UnsafeMutablePointer<GtkWindow>? {
        parent?.window
    }

    /// Files to open (none if cancelled).
    static func openFiles(title: String, accept: String, over parent: Window?,
                          _ completion: @escaping @MainActor ([URL]) -> Void) {
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            defer { if let error { g_error_free(error) } }
            let files = gtk_file_dialog_open_multiple_finish(dialog, result, &error)
            g_object_unref(gpointer(dialog))
            completion(urls(files))
        }
        gtk_file_dialog_open_multiple(dialog(title: title, accept: accept), window(parent), nil, filesDialogFinished,
                                      Boxed<Done>(done).retained)
    }

    /// Folders to open (none if cancelled).
    static func openFolders(title: String, accept: String, over parent: Window?,
                            _ completion: @escaping @MainActor ([URL]) -> Void) {
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            defer { if let error { g_error_free(error) } }
            let files = gtk_file_dialog_select_multiple_folders_finish(dialog, result, &error)
            g_object_unref(gpointer(dialog))
            completion(urls(files))
        }
        gtk_file_dialog_select_multiple_folders(dialog(title: title, accept: accept), window(parent), nil,
                                                filesDialogFinished, Boxed<Done>(done).retained)
    }

    /// A folder (nil if cancelled).
    static func chooseFolder(title: String, accept: String, over parent: Window?,
                             _ completion: @escaping @MainActor (URL?) -> Void) {
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            defer { if let error { g_error_free(error) } }
            let file = gtk_file_dialog_select_folder_finish(dialog, result, &error)
            let url = URL(gFile: file)
            if let file { g_object_unref(gpointer(file)) }
            g_object_unref(gpointer(dialog))
            completion(url)
        }
        gtk_file_dialog_select_folder(dialog(title: title, accept: accept), window(parent), nil, filesDialogFinished,
                                      Boxed<Done>(done).retained)
    }
}

// MARK: Widgets

extension Widget {
    /// A shortcut that works only while this widget (or one inside it) has
    /// the keyboard: Delete in a list, say, and not in the window's other
    /// controls.
    @discardableResult
    func filesShortcut(_ trigger: String, action: String) -> Self {
        let controller = gtk_shortcut_controller_new()!
        gtk_shortcut_controller_set_scope(cast(controller), GTK_SHORTCUT_SCOPE_LOCAL)
        let shortcut = gtk_shortcut_new(gtk_shortcut_trigger_parse_string(trigger), gtk_named_action_new(action))
        gtk_shortcut_controller_add_shortcut(cast(controller), shortcut)
        gtk_widget_add_controller(widget, controller)
        return self
    }
}

/// The index of a list's row (a GtkStringObject of its number).
func filesListIndex(_ item: UnsafeRawPointer?) -> Int? {
    guard let item, let object = macbeeb_string_object(UnsafeMutableRawPointer(mutating: item)) else { return nil }
    return Int(String(cString: gtk_string_object_get_string(object)))
}

// MARK: Self-tests

/// `-MacBeebSelfTestFiles "step;step;…"` (with `-MacBeebSelfTestOpen
/// win.disc-contents` or `app.print-centre`): what the disc contents window
/// and the Print Centre do once they're open, for checking them without
/// looking (each step is "verb" or "verb:argument", a second apart).
@MainActor
enum FilesSelfTest {
    static var steps: [(verb: String, argument: String)] {
        guard LaunchScreen.isSelfTest, let script = UserDefaults.standard.string(forKey: "MacBeebSelfTestFiles") else {
            return []
        }
        return script.split(separator: ";").map { step in
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
    }

    /// The disc a self-test names (`-MacBeebSelfTestDisc`), put in drive 0
    /// before the window opens (the self-test opens the window instead of
    /// inserting it).
    static func insertDisc(into machine: MachineController) {
        guard LaunchScreen.isSelfTest, machine.discNames[0] == nil,
              let path = UserDefaults.standard.string(forKey: "MacBeebSelfTestDisc") else { return }
        machine.insertDisc(URL(fileURLWithPath: path), drive: 0, boot: false)
    }

    private static var running = false

    /// Runs the steps, each through `perform` (in the first window to ask).
    static func run(_ perform: @escaping @MainActor (String, String) async -> Void) {
        let steps = steps
        guard !steps.isEmpty, !running else { return }
        running = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            for step in steps {
                log("step \(step.verb) \(step.argument)")
                if step.verb == "wait" {
                    try? await Task.sleep(for: .seconds(Double(step.argument) ?? 1))
                    continue
                }
                await perform(step.verb, step.argument)
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    /// Saves a popover (or any widget with its own surface) beside the
    /// self-test's pictures, as path-NAME.png.
    static func capture(_ widget: WidgetPointer?, as name: String) {
        guard let widget, let path = UserDefaults.standard.string(forKey: "MacBeebSelfTest") else {
            log("nothing to capture as \(name)")
            return
        }
        Capture.write(Widget(widget), to: path.replacingOccurrences(of: ".png", with: "-\(name).png"))
    }

    /// A blank disc ("blank:adfsL:1:/path/disc.adl"), made and put in a
    /// drive.
    static func blank(_ argument: String, machine: MachineController) {
        let parts = argument.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let kind = BlankDisc(rawValue: parts[0]), let drive = Int(parts[1]) else { return }
        let url = URL(fileURLWithPath: parts[2])
        try? Data(kind.image(title: "TESTDISC")).write(to: url)
        machine.insertDisc(url, drive: drive, boot: false)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[files] \(message)\n".utf8))
    }
}
