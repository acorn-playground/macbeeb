import BeebNetwork
import CGtk
import Foundation

/// Closing a new network, as closing a new document does: keep it, with a
/// name and a place, or delete it. (The Mac's KeepNetworkSheet.)
@MainActor
enum KeepNetworkDialog {
    /// `finished(true)`: kept or deleted, so the window can close;
    /// `finished(false)`: cancelled, it stays.
    static func present(session: NetworkSession, over window: Window, finished: @escaping @MainActor (Bool) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var folders: [(title: String, url: URL)] = [
            ("MacBeeb Networks", RecentNetworks.folder),
            ("Documents", home.appendingPathComponent("Documents")),
            ("Desktop", home.appendingPathComponent("Desktop")),
        ]
        var folder = RecentNetworks.folder
        let name = EntryRow("Save As", text: session.project.name)
        adw_entry_row_set_activates_default(cast(name.widget), 1)
        let whereRow = ComboRow("Where", items: folders.map(\.title) + ["Other…"], selected: 0)
        whereRow.tooltip(folder.path)
        var choosing = false
        whereRow.object.onChange("selected") { [whereRow] in
            let index = whereRow.selected
            guard index >= 0, !choosing else { return }
            if index < folders.count {
                folder = folders[index].url
                whereRow.tooltip(folder.path)
                return
            }
            // Other…: somewhere else, or back to where it was.
            choosing = true
            let previous = folders.firstIndex { $0.url == folder } ?? 0
            NetworkFileDialogs.chooseFolder(in: folder) { url in
                defer { choosing = false }
                guard let url else {
                    whereRow.selected = previous
                    return
                }
                folder = url
                if !folders.contains(where: { $0.url == url }) {
                    folders.append((url.lastPathComponent, url))
                }
                let index = folders.firstIndex { $0.url == url } ?? 0
                whereRow.setItems(folders.map(\.title) + ["Other…"], selected: index)
                whereRow.selected = index
                whereRow.tooltip(url.path)
            }
        }
        let form = ListBox()
        form.append(name)
        form.append(whereRow)
        form.style("boxed-list")
        let dialog = AlertDialog("Do you want to keep this new network “\(session.project.name)”?",
                                 body: "You can save it, with its machines, discs and layout, to open again, or delete it now.")
            .response("cancel", "_Cancel")
            .response("delete", "_Delete", .destructive)
            .response("save", "_Save", .suggested)
            .defaults(default: "save", close: "cancel")
            .extra(form)
        name.object.on("changed") { [name] in
            adw_alert_dialog_set_response_enabled(cast(dialog.widget), "save",
                                                  name.text.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1)
        }
        dialog.focus(name)
        dialog.choose(over: window) { response in
            switch response {
            case "save":
                do {
                    try session.keep(as: name.text, in: folder)
                    finished(true)
                } catch {
                    finished(false)
                    AlertDialog("Couldn’t save it there", body: error.localizedDescription)
                        .response("ok", "_OK", .suggested)
                        .defaults(default: "ok", close: "ok")
                        .present(over: window)
                }
            case "delete":
                // Closes the network, and moves it to the Trash.
                Task {
                    await session.discard()
                    finished(true)
                }
            default:
                finished(false)
            }
        }
    }
}
