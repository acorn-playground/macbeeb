import CGtk
import Foundation

// Choosing files (GTK's file dialog: the desktop's own chooser, through
// the portal), the clipboard, launching URLs and files, and recent files.

/// (Outside the main actor's types, as C callbacks must be.)
private func fileDialogFinished(_ source: UnsafeMutablePointer<GObject>?, _ result: OpaquePointer?, _ data: gpointer?) {
    guard let source, let result else { return }
    let dialog = UInt(bitPattern: source), outcome = UInt(bitPattern: result), box = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        Boxed<FileDialogs.Done>.from(UnsafeMutableRawPointer(bitPattern: box))(OpaquePointer(bitPattern: dialog)!,
                                                                              OpaquePointer(bitPattern: outcome)!)
    }
    AnyBox.release(data)
}

@MainActor
enum FileDialogs {
    /// GTK's filters for a kind of file: its own, then (if it allows
    /// others) all files.
    private static func filters(_ kind: FileKind) -> (list: OpaquePointer, first: OpaquePointer?) {
        let store = g_list_store_new(gtk_file_filter_get_type())!
        var first: OpaquePointer?
        if !kind.extensions.isEmpty {
            let filter = gtk_file_filter_new()!
            gtk_file_filter_set_name(filter, kind.name)
            for suffix in kind.extensions {
                gtk_file_filter_add_suffix(filter, suffix)
            }
            if kind == .images || kind == .discsAndImages {
                gtk_file_filter_add_pixbuf_formats(filter)
            }
            g_list_store_append(store, gpointer(filter))
            first = filter
            g_object_unref(gpointer(filter))
        }
        if kind.extensions.isEmpty || kind.allowsOthers {
            let all = gtk_file_filter_new()!
            gtk_file_filter_set_name(all, "All files")
            gtk_file_filter_add_pattern(all, "*")
            g_list_store_append(store, gpointer(all))
            g_object_unref(gpointer(all))
        }
        return (store, first)
    }

    private static func dialog(_ kind: FileKind, title: String?) -> OpaquePointer {
        let dialog = gtk_file_dialog_new()!
        if let title { gtk_file_dialog_set_title(dialog, title) }
        gtk_file_dialog_set_modal(dialog, 1)
        let (list, first) = filters(kind)
        gtk_file_dialog_set_filters(dialog, list)
        if let first { gtk_file_dialog_set_default_filter(dialog, first) }
        g_object_unref(gpointer(list))
        return dialog
    }

    private static var parent: UnsafeMutablePointer<GtkWindow>? {
        Application.shared.activeWindow.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self) }
    }

    typealias Done = @MainActor (OpaquePointer, OpaquePointer) -> Void

    /// GLib's async callback, calling the boxed `Done` with the dialog and
    /// the result.
    private static let finished: GAsyncReadyCallback = fileDialogFinished

    /// Asks for files to open; `completion` gets them (none if cancelled).
    static func open(_ kind: FileKind, multiple: Bool, title: String?, _ completion: @escaping @MainActor ([URL]) -> Void) {
        let dialog = dialog(kind, title: title ?? (multiple ? "Choose Files" : "Choose a File"))
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            defer { if let error { g_error_free(error) } }
            if multiple {
                guard let files = gtk_file_dialog_open_multiple_finish(dialog, result, &error) else { return completion([]) }
                var urls: [URL] = []
                for index in 0..<g_list_model_get_n_items(files) {
                    if let file = g_list_model_get_item(files, index) {
                        if let url = URL(gFile: OpaquePointer(file)) { urls.append(url) }
                        g_object_unref(file)
                    }
                }
                g_object_unref(gpointer(files))
                completion(urls)
            } else {
                guard let file = gtk_file_dialog_open_finish(dialog, result, &error) else { return completion([]) }
                let url = URL(gFile: file)
                g_object_unref(gpointer(file))
                completion(url.map { [$0] } ?? [])
            }
            g_object_unref(gpointer(dialog))
        }
        if multiple {
            gtk_file_dialog_open_multiple(dialog, parent, nil, finished, Boxed<Done>(done).retained)
        } else {
            gtk_file_dialog_open(dialog, parent, nil, finished, Boxed<Done>(done).retained)
        }
    }

    /// Asks where to save; `completion` gets the place (nil if cancelled).
    static func save(_ kind: FileKind, suggestedName: String, title: String?, _ completion: @escaping @MainActor (URL?) -> Void) {
        let dialog = dialog(kind, title: title ?? "Save")
        gtk_file_dialog_set_initial_name(dialog, suggestedName)
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            defer { if let error { g_error_free(error) } }
            let file = gtk_file_dialog_save_finish(dialog, result, &error)
            let url = URL(gFile: file)
            if let file { g_object_unref(gpointer(file)) }
            g_object_unref(gpointer(dialog))
            completion(url)
        }
        gtk_file_dialog_save(dialog, parent, nil, finished, Boxed<Done>(done).retained)
    }

    /// Asks for a folder (starting in `initial`, if given).
    static func chooseFolder(title: String, initial: URL? = nil, _ completion: @escaping @MainActor (URL?) -> Void) {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        gtk_file_dialog_set_modal(dialog, 1)
        if let initial {
            let folder = initial.gFile
            gtk_file_dialog_set_initial_folder(dialog, folder)
            g_object_unref(gpointer(folder))
        }
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            defer { if let error { g_error_free(error) } }
            let file = gtk_file_dialog_select_folder_finish(dialog, result, &error)
            let url = URL(gFile: file)
            if let file { g_object_unref(gpointer(file)) }
            g_object_unref(gpointer(dialog))
            completion(url)
        }
        gtk_file_dialog_select_folder(dialog, parent, nil, finished, Boxed<Done>(done).retained)
    }
}

@MainActor
enum Clipboard {
    private static var clipboard: OpaquePointer {
        gdk_display_get_clipboard(gdk_display_get_default())
    }

    /// The clipboard's text, if it has any (asynchronously).
    static func readText(_ completion: @escaping @MainActor (String) -> Void) {
        typealias Done = @MainActor (String?) -> Void
        let done: Done = { text in if let text { completion(text) } }
        gdk_clipboard_read_text_async(clipboard, nil, { source, result, data in
            var error: UnsafeMutablePointer<GError>?
            let text = String(gOwned: gdk_clipboard_read_text_finish(OpaquePointer(source), result, &error))
            if let error { g_error_free(error) }
            MainActor.assumeIsolated { Boxed<Done>.from(data)(text) }
            AnyBox.release(data)
        }, Boxed<Done>(done).retained)
    }

    static func setText(_ text: String) {
        gdk_clipboard_set_text(clipboard, text)
    }

    /// Puts a PNG on the clipboard, as a picture.
    static func setPNG(_ png: Data) {
        let bytes = png.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        var error: UnsafeMutablePointer<GError>?
        guard let texture = gdk_texture_new_from_bytes(bytes, &error) else {
            if let error { g_error_free(error) }
            return
        }
        gdk_clipboard_set_texture(clipboard, texture)
        g_object_unref(gpointer(texture))
    }
}

@MainActor
enum Launcher {
    /// Opens a URL in the default browser (or its app).
    static func open(_ url: URL) {
        let parent = Application.shared.activeWindow.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self) }
        if url.isFileURL {
            let file = url.gFile
            let launcher = gtk_file_launcher_new(file)
            g_object_unref(gpointer(file))
            gtk_file_launcher_launch(launcher, parent, nil, nil, nil)
            g_object_unref(gpointer(launcher))
        } else {
            let launcher = gtk_uri_launcher_new(url.absoluteString)
            gtk_uri_launcher_launch(launcher, parent, nil, nil, nil)
            g_object_unref(gpointer(launcher))
        }
    }

    /// Shows a file in the file manager.
    static func reveal(_ url: URL) {
        let parent = Application.shared.activeWindow.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self) }
        let file = url.gFile
        let launcher = gtk_file_launcher_new(file)
        g_object_unref(gpointer(file))
        gtk_file_launcher_open_containing_folder(launcher, parent, nil, nil, nil)
        g_object_unref(gpointer(launcher))
    }

    /// Adds a file to the desktop's recent files.
    static func noteRecent(_ url: URL) {
        guard let uri = String(gOwned: g_filename_to_uri(url.path, nil, nil)) else { return }
        gtk_recent_manager_add_item(gtk_recent_manager_get_default(), uri)
    }
}
