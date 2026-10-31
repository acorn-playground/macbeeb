import BeebNetwork
import CGtk
import Foundation

/// Opening networks, from the menus, the start window and the agents.
@MainActor
enum NetworkStudioCommands {
    /// Posted (with the package's URL) to have a network's window opened,
    /// by whichever window can.
    static let openRequest = Notification.Name("MacBeebOpenNetworkWindow")
    /// Posted (with the package's URL) to show a network's Share Over
    /// Internet dialog.
    static let shareRequest = Notification.Name("MacBeebShareNetwork")

    /// A new network from a template, as a draft: closing it asks whether
    /// to keep it.
    static func createDraft(_ template: NetworkTemplate) throws -> URL {
        let url = RecentNetworks.newURL(named: template.title)
        var project = try NetworkPackage.create(template, at: url)
        project.draft = true
        try NetworkPackage.save(project, to: url)
        return url
    }

    static func open(_ url: URL) {
        installObservers()
        NetworkStudioWindow.show(url.standardizedFileURL)
    }

    /// Open Network…: a network's package (a folder) from the file
    /// chooser, starting in the networks folder.
    static func chooseAndOpen(_ opened: (@MainActor () -> Void)? = nil) {
        installObservers()
        let folder = RecentNetworks.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NetworkFileDialogs.chooseNetwork(in: folder) { url in
            guard let url else { return }
            guard url.pathExtension.lowercased() == NetworkPackage.fileExtension else {
                Platform.showAlert(title: "That isn’t a network",
                                   message: "A network is a folder whose name ends in .\(NetworkPackage.fileExtension), as MacBeeb saves them.")
                return
            }
            open(url)
            opened?()
        }
    }

    /// Network Studio: the network that's open, else the last one, else a
    /// new one.
    static func showStudio() {
        installObservers()
        if let url = NetworkSession.open.keys.first ?? RecentNetworks.shared.existing.first {
            open(url)
        } else {
            NetworkStartWindow.show()
        }
    }

    /// Save Network As…: a copy somewhere else, which the window carries on
    /// with.
    static func saveAs(_ session: NetworkSession) {
        NetworkFileDialogs.save(suggestedName: session.url.lastPathComponent, in: session.url.deletingLastPathComponent()) { url in
            guard var url else { return }
            if url.pathExtension.lowercased() != NetworkPackage.fileExtension {
                url.appendPathExtension(NetworkPackage.fileExtension)
            }
            do {
                try session.saveAs(url)
            } catch {
                Platform.showError(error)
            }
        }
    }

    private static var observing = false

    /// The agents ask for a network's window (once they've opened it) with
    /// `openRequest`: the studio opens it. (Called as the app starts, and
    /// by everything here, in case.)
    static func installObservers() {
        guard !observing else { return }
        observing = true
        _ = NotificationCenter.default.addObserver(forName: openRequest, object: nil, queue: .main) { note in
            let url = note.object as? URL
            MainActor.assumeIsolated {
                if let url { NetworkStudioWindow.show(url.standardizedFileURL) }
            }
        }
    }
}

/// GTK's file chooser for networks: packages are folders on Linux.
@MainActor
enum NetworkFileDialogs {
    typealias Done = @MainActor (OpaquePointer, OpaquePointer) -> Void

    private static var parent: UnsafeMutablePointer<GtkWindow>? {
        Application.shared.activeWindow.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self) }
    }

    private static func dialog(title: String, accept: String, folder: URL) -> OpaquePointer {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        gtk_file_dialog_set_accept_label(dialog, accept)
        gtk_file_dialog_set_modal(dialog, 1)
        let initial = folder.gFile
        gtk_file_dialog_set_initial_folder(dialog, initial)
        g_object_unref(gpointer(initial))
        return dialog
    }

    /// A network's folder (or the folder it's in, if the user goes in).
    static func chooseNetwork(in folder: URL, _ completion: @escaping @MainActor (URL?) -> Void) {
        let dialog = dialog(title: "Open Network", accept: "_Open", folder: folder)
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            defer { if let error { g_error_free(error) } }
            let file = gtk_file_dialog_select_folder_finish(dialog, result, &error)
            var url = URL(gFile: file)
            if let file { g_object_unref(gpointer(file)) }
            g_object_unref(gpointer(dialog))
            // Chosen from inside the package (its Media folder, say).
            while let current = url, current.pathExtension.lowercased() != NetworkPackage.fileExtension,
                  current.path.contains(".\(NetworkPackage.fileExtension)/") {
                url = current.deletingLastPathComponent()
            }
            completion(url)
        }
        gtk_file_dialog_select_folder(dialog, parent, nil, networkDialogFinished, Boxed<Done>(done).retained)
    }

    /// Where to save a copy.
    static func save(suggestedName: String, in folder: URL, _ completion: @escaping @MainActor (URL?) -> Void) {
        let dialog = dialog(title: "Save Network As", accept: "_Save", folder: folder)
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
        gtk_file_dialog_save(dialog, parent, nil, networkDialogFinished, Boxed<Done>(done).retained)
    }

    /// A folder to keep a network in.
    static func chooseFolder(in folder: URL, _ completion: @escaping @MainActor (URL?) -> Void) {
        let dialog = dialog(title: "Choose a Folder", accept: "_Choose", folder: folder)
        let done: Done = { dialog, result in
            var error: UnsafeMutablePointer<GError>?
            defer { if let error { g_error_free(error) } }
            let file = gtk_file_dialog_select_folder_finish(dialog, result, &error)
            let url = URL(gFile: file)
            if let file { g_object_unref(gpointer(file)) }
            g_object_unref(gpointer(dialog))
            completion(url)
        }
        gtk_file_dialog_select_folder(dialog, parent, nil, networkDialogFinished, Boxed<Done>(done).retained)
    }
}

extension NetworkStudioPreview {
    /// Waits for the workers, types *CLUSTER and *MANDEL on the Guide, and
    /// shows the Mandelbrot view as the picture's drawn.
    static func runMandelbrot(_ studio: NetworkStudio) {
        let session = studio.session
        let stations = session.project.stations.filter { $0.kind == .station }
        func screen(_ node: NetworkNode) async -> String {
            (try? await session.controllers[node.id]?.host.performAsync { $0.machine.screenText().joined(separator: "\n") }) ?? ""
        }
        func log(_ what: String, _ node: NetworkNode) async {
            let text = await screen(node).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " | ")
            NSLog("MacBeeb preview: \(what); frames \(session.runtime.network.frames(after: nil).count), tracing \(session.runtime.network.isTracing); \(node.name) says: \(text)")
        }
        Task { @MainActor in
            guard let guide = stations.first(where: { $0.bootsDisc == true }), let controller = session.controllers[guide.id] else { return }
            let workers = stations.filter { $0.bootsDisc != true }
            for _ in 0..<400 {
                var ready = true
                for node in workers where !(await screen(node)).contains("BASIC") { ready = false }
                if ready { break }
                try? await Task.sleep(for: .seconds(1))
            }
            await log("workers at BASIC", guide)
            // (And the Guide at its prompt, once it's shown its page and
            // logged on: the file server has to be up.)
            for second in 0..<1800 {
                let lines = await screen(guide).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if lines.contains(where: { $0.contains("Workers:") }), lines.last?.hasPrefix(">") == true { break }
                if second % 60 == 59 { await log("waiting for the Guide", guide) }
                try? await Task.sleep(for: .seconds(1))
            }
            await log("typing *CLUSTER", guide)
            controller.host.send(.type("*CLUSTER\n"))
            for second in 0..<400 {
                if await screen(guide).contains("failed.") { break }
                if second % 30 == 29 { await log("waiting for CLUSTER", guide) }
                try? await Task.sleep(for: .seconds(1))
            }
            await log("typing *MANDEL", guide)
            controller.host.send(.type("*MANDEL\n"))
            studio.show(.mandelbrot)
            // A picture once a good part's drawn, and when it's done.
            var captured = false
            for _ in 0..<240 {
                try? await Task.sleep(for: .seconds(10))
                let observer = studio.mandelbrot.observer
                NSLog("MacBeeb preview: \(observer.tilesCompleted) tiles, \(observer.workers.count) workers, \(observer.messages) messages")
                if !captured, observer.tilesCompleted >= 120, let path = UserDefaults.standard.string(forKey: "MacBeebSelfTest") {
                    captured = true
                    Capture.write(studio.window, to: path.replacingOccurrences(of: ".png", with: "-partway.png"))
                }
                if observer.completeSeen, let path = UserDefaults.standard.string(forKey: "MacBeebSelfTest") {
                    try? await Task.sleep(for: .seconds(2))
                    Capture.write(studio.window, to: path.replacingOccurrences(of: ".png", with: "-complete.png"))
                    studio.session.selection = [guide.id]
                    studio.show(.canvas)
                    try? await Task.sleep(for: .seconds(2))
                    Capture.write(studio.window, to: path.replacingOccurrences(of: ".png", with: "-canvas.png"))
                    Application.shared.quit()
                    return
                }
            }
        }
    }
}

/// GLib's async callback for the dialogs above (outside the main actor's
/// types, as C callbacks must be).
private func networkDialogFinished(_ source: UnsafeMutablePointer<GObject>?, _ result: OpaquePointer?, _ data: gpointer?) {
    guard let source, let result else { return }
    let dialog = UInt(bitPattern: source), outcome = UInt(bitPattern: result), box = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        Boxed<NetworkFileDialogs.Done>.from(UnsafeMutableRawPointer(bitPattern: box))(OpaquePointer(bitPattern: dialog)!,
                                                                                     OpaquePointer(bitPattern: outcome)!)
    }
    AnyBox.release(data)
}

/// Seeing the studio without a person: `-MacBeebSelfTestNetwork <template>`
/// (a NetworkTemplate's raw value) with `-MacBeebSelfTestOpen
/// app.new-network` makes a draft of that template and opens it. The
/// draft's deleted when the app quits. And with it (each 1, or a value):
///
/// - `-MacBeebSelfTestNetworkView` canvas, tiles, focus, traffic or
///   mandelbrot: the view shown.
/// - `-MacBeebSelfTestNetworkSelect` a node's name: it's selected.
/// - `-MacBeebSelfTestNetworkSelectAll`: several selected.
/// - `-MacBeebSelfTestNetworkZoom` 1.0: the canvas's zoom.
/// - `-MacBeebSelfTestNetworkWidth` 800: the window's width.
/// - `-MacBeebSelfTestNetworkClose`: closing it, so it asks to keep it.
/// - `-MacBeebSelfTestNetworkStation` (and `…StationOff`): the selected
///   machine's own window (and it switched off, so it goes).
/// - `-MacBeebSelfTestNetworkMenu` path: the selection's context menu,
///   saved as a PNG.
/// - `-MacBeebSelfTestNetworkAdd` modelB (a palette item): it's added, as
///   a click in the palette does.
/// - `-MacBeebSelfTestNetworkProblem`: two machines with one number.
/// - `-MacBeebSelfTestNetworkPause`: the network paused (a still picture).
/// - `-MacBeebSelfTestNetworkMandelbrot`: for the Distributed Mandelbrot
///   templates, *CLUSTER and *MANDEL typed on the Guide once it's logged
///   on, the Mandelbrot view shown, and pictures saved partway
///   (path-partway.png) and once it's complete (path-complete.png,
///   path-canvas.png). (It needs the emulation near full speed: a release
///   build.)
@MainActor
enum NetworkStudioPreview {
    static var template: NetworkTemplate? {
        UserDefaults.standard.string(forKey: "MacBeebSelfTestNetwork").flatMap(NetworkTemplate.init(rawValue:))
    }

    /// Opens the preview's network instead of the start window; whether it
    /// did.
    static func runIfRequested() -> Bool {
        guard LaunchScreen.isSelfTest, let template else { return false }
        let url: URL
        do {
            url = try NetworkStudioCommands.createDraft(template)
        } catch {
            NSLog("MacBeeb: couldn't make the preview network: \(error)")
            return false
        }
        Application.shared.object.on("shutdown") {
            NetworkSession.existing(url)?.close()
            try? FileManager.default.removeItem(at: url)
        }
        let defaults = UserDefaults.standard
        NetworkStudioWindow.show(url)
        guard let studio = NetworkStudioWindow.existing(url) else { return true }
        if let view = defaults.string(forKey: "MacBeebSelfTestNetworkView").flatMap(NetworkStudio.Mode.init(rawValue:)) {
            studio.show(view)
        }
        if let name = defaults.string(forKey: "MacBeebSelfTestNetworkSelect"),
           let node = studio.session.project.nodes.first(where: { $0.name == name }) {
            studio.session.selection = [node.id]
        }
        if defaults.string(forKey: "MacBeebSelfTestNetworkStation") != nil, let id = studio.session.selection.first {
            MainLoop.after(2) { StationWindow.show(network: url, node: id) }
        }
        if defaults.string(forKey: "MacBeebSelfTestNetworkStationOff") != nil, let id = studio.session.selection.first {
            MainLoop.after(4) { studio.session.powerOff(id) }
        }
        if let path = defaults.string(forKey: "MacBeebSelfTestNetworkMenu") {
            MainLoop.after(3) { studio.canvas?.showMenuForSelection(capturingTo: path) }
        }
        if defaults.string(forKey: "MacBeebSelfTestNetworkSelectAll") != nil {
            MainLoop.after(1) { studio.session.selection = Set(studio.session.project.nodes.filter(\.isMachine).prefix(3).map(\.id)) }
        }
        if let width = Int32(defaults.string(forKey: "MacBeebSelfTestNetworkWidth") ?? "") {
            studio.window.setDefaultSize(width: width, height: 700)
        }
        if let item = defaults.string(forKey: "MacBeebSelfTestNetworkAdd") {
            MainLoop.after(2) { studio.canvas?.addFromPalette(item) }
        }
        if defaults.string(forKey: "MacBeebSelfTestNetworkProblem") != nil {
            let machines = studio.session.project.stations
            if machines.count > 1 {
                studio.session.update { $0[machines[1].id]?.stationNumber = machines[0].stationNumber }
            }
        }
        if defaults.string(forKey: "MacBeebSelfTestNetworkMandelbrot") != nil {
            runMandelbrot(studio)
        }
        if defaults.string(forKey: "MacBeebSelfTestNetworkPause") != nil {
            MainLoop.after(2.5) { studio.session.setPaused(true) }
        }
        if defaults.string(forKey: "MacBeebSelfTestNetworkClose") != nil {
            MainLoop.after(1.5) { studio.window.close() }
        }
        if let zoom = Double(defaults.string(forKey: "MacBeebSelfTestNetworkZoom") ?? "") {
            MainLoop.after(0.8) { studio.canvas?.setZoom(zoom, animated: false) }
        }
        return true
    }
}
