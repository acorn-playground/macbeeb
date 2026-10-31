import BeebCore
import BeebHost
import CGtk
import Foundation

/// File > Show Disc Contents (Alt+Shift+I): the files on the discs in a
/// machine's drives, which can be dragged out to the file manager (with
/// .inf files) and in from it, renamed, relocked, readdressed and deleted,
/// with undo. (The Mac's DiscContentsWindow.)
@MainActor
final class DiscContentsWindow {
    static func show(for machine: MachineController) {
        FilesSelfTest.insertDisc(into: machine)
        Windows.show("disc-contents-\(machine.id)") {
            DiscContentsWindow(machine: machine).window
        }
    }

    let machine: MachineController
    let model: DiscContentsModel
    let undoManager = UndoManager()
    let window: Window

    private let toasts: ToastOverlay
    private let toolbarView: ToolbarView
    private let drives = Bin()
    private var driveGroup: WidgetPointer?
    private var driveSurfaces: [Int] = []
    private var driveTooltips: [String] = []
    private let addButton = Button(icon: "list-add-symbolic")
    private let newDirectoryButton = Button(icon: "folder-new-symbolic")

    // The disc's title, boot option and free space.
    private let infoBar = Box(.horizontal, spacing: 8)
    private let titleEntry = Entry(placeholder: "No title")
    private var titleFocused = false
    private let bootChoice = DropDown(["None", "*LOAD", "*RUN", "*EXEC"])
    private let freeSpace = Label("", style: "dim-label", "numeric")

    // The files, or why there are none.
    private let stack = Stack()
    private let table = Table(selection: .multiple)
    private let problemPage = StatusPage(icon: "media-floppy-symbolic", title: "")
    private let problemButtons = Box(.horizontal, spacing: 12)
    private let emptyPage = StatusPage(icon: "folder-documents-symbolic", title: "No Files")
    private var shown: [DiscVolume.Item] = []
    private var isADFS = false
    private var syncing = false
    private var tableFocused = false
    private var columnKeys: [OpaquePointer: String] = [:]
    private var columns: [String: OpaquePointer] = [:]
    private let contextMenu = Menu {}
    private lazy var contextPopover = Popover(menu: contextMenu)

    // The ADFS directory, and what the drive's doing.
    private let footer = Box(.horizontal, spacing: 6)
    private let pathBar = Box(.horizontal, spacing: 2)
    private let waitingSpinner = Spinner()
    private let footerStatus = Label("", style: "dim-label", "caption")
    private var shownPath: [String] = []

    private let primaryMenu = Menu {}
    private var undoLabels: [String] = []
    private let menuButton = MenuButton(icon: "open-menu-symbolic")
    private var actions: [String: Action] = [:]
    private var alertShowing = false
    /// Where dragged-out files are written for the file manager to copy.
    private let dragFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacBeeb Drags", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    private init(machine: MachineController) {
        FilesStyles.install()
        self.machine = machine
        model = DiscContentsModel(machine: machine)
        window = Window(title: "Disc Contents", width: 760, height: 520)
        window.minimumSize(width: 480, height: 300)

        toolbarView = ToolbarView()
        toasts = ToastOverlay(toolbarView)
        window.content = toasts

        buildActions()
        buildHeaderBar()
        buildInfoBar()
        buildTable()
        buildContent()
        buildFooter()
        observe()

        App.addStandardShortcuts(to: window)
        window.shortcut("<Control>z", action: "win.undo")
        window.shortcut("<Control><Shift>z", action: "win.redo")
        window.shortcut("<Control>i", action: "win.get-info")
        window.shortcut("<Alt>Return", action: "win.get-info")
        window.shortcut("<Alt>Up", action: "win.go-up")
        window.shortcut("<Control><Shift>n", action: "win.new-directory")
        window.onActiveChanged { [weak self] active in
            if active { self?.model.reload() }
        }
        let folder = dragFolder
        window.onDestroy { try? FileManager.default.removeItem(at: folder) }
        window.keep(self)
        FilesSelfTest.run { [weak self] verb, argument in await self?.selfTest(verb, argument) }
    }

    // MARK: Actions

    private func command(_ name: String, _ body: @escaping @MainActor () -> Void) {
        actions[name] = window.action(name, body)
    }

    private func buildActions() {
        let model = model
        command("add-files") { [weak self] in self?.addFiles(folders: false) }
        command("add-folders") { [weak self] in self?.addFiles(folders: true) }
        command("new-directory") { [weak self] in self?.nameDirectory() }
        command("export") { [weak self] in self?.exportSelection() }
        command("export-text") { [weak self] in
            guard let self, let item = self.model.selectedItems.first else { return }
            self.model.exportAsText(item)
        }
        command("get-info") { [weak self] in
            guard let self, self.model.selection.count == 1, let item = self.model.selectedItems.first else { return }
            self.showInfo(item)
        }
        command("open-item") { [weak self] in
            guard let self, let item = self.model.selectedItems.first else { return }
            self.openOrInfo(item)
        }
        command("delete") { [weak self] in
            guard let self else { return }
            model.delete(model.selectedItems, undoManager: self.undoManager)
        }
        command("undo") { [weak self] in
            self?.undoManager.undo()
            self?.updateUndo()
        }
        command("redo") { [weak self] in
            self?.undoManager.redo()
            self?.updateUndo()
        }
        command("go-up") {
            if !model.path.isEmpty { model.goUp(to: model.path.count - 1) }
        }
        command("new-disc") { [weak self] in
            guard let self else { return }
            self.machine.newDisc(drive: self.model.drive)
        }
        command("insert-disc") { [weak self] in
            guard let self else { return }
            self.machine.openDisc(drive: self.model.drive, boot: false)
        }
        command("close") { [weak self] in self?.window.close() }
    }

    /// Which actions can run, as the disc and the selection change.
    private func updateActions() {
        let usable = model.volume != nil && model.problem == nil
        let selected = model.selectedItems
        actions["add-files"]?.isEnabled = usable
        actions["add-folders"]?.isEnabled = usable && isADFS
        actions["new-directory"]?.isEnabled = usable && isADFS
        actions["export"]?.isEnabled = usable && !selected.isEmpty
        actions["export-text"]?.isEnabled = usable && selected.count == 1 && model.isBASIC(selected[0])
        actions["get-info"]?.isEnabled = usable && selected.count == 1
        actions["open-item"]?.isEnabled = usable && selected.count == 1
        actions["delete"]?.isEnabled = usable && !selected.isEmpty
        actions["go-up"]?.isEnabled = usable && !model.path.isEmpty
        updateUndo()
    }

    /// Undo and Redo, named for what they'd do, as the Mac's Edit menu has
    /// them.
    private func updateUndo() {
        actions["undo"]?.isEnabled = undoManager.canUndo
        actions["redo"]?.isEnabled = undoManager.canRedo
        let undo = undoManager.canUndo && !undoManager.undoActionName.isEmpty ? "Undo \(undoManager.undoActionName)" : "Undo"
        let redo = undoManager.canRedo && !undoManager.redoActionName.isEmpty ? "Redo \(undoManager.redoActionName)" : "Redo"
        // (Not rebuilt unless it changes: it may be open.)
        guard [undo, redo] != undoLabels else { return }
        undoLabels = [undo, redo]
        primaryMenu.set([
            MenuSection {
                MenuItem("Add Files…", "win.add-files")
                MenuItem("Add Folders…", "win.add-folders")
                MenuItem("New Directory…", "win.new-directory", accel: "<Control><Shift>n")
            },
            MenuSection {
                MenuItem("Export…", "win.export")
                MenuItem("Export as Text…", "win.export-text")
            },
            MenuSection {
                MenuItem(undo, "win.undo", accel: "<Control>z")
                MenuItem(redo, "win.redo", accel: "<Control><Shift>z")
            },
        ])
    }

    // MARK: The header bar

    private func buildHeaderBar() {
        let header = HeaderBar(title: drives)
        addButton.action("win.add-files")
            .tooltip("Copy files onto the disc")
            .accessibleLabel("Add Files")
        newDirectoryButton.action("win.new-directory").tooltip("Make a directory").accessibleLabel("New Directory")
        let export = Button(icon: "document-save-as-symbolic").action("win.export")
            .tooltip("Copy the selected files to a folder, with .inf files").accessibleLabel("Export")
        let info = Button(icon: "document-properties-symbolic").action("win.get-info")
            .tooltip("Rename, readdress or lock the selected file").accessibleLabel("Get Info")
        let delete = Button(icon: "user-trash-symbolic").action("win.delete")
            .tooltip("Delete the selected files").accessibleLabel("Delete")
        menuButton.menu = primaryMenu
        menuButton.tooltip("Main Menu").primary()
        header.start(addButton).start(newDirectoryButton)
        header.end(menuButton).end(delete).end(info).end(export)
        toolbarView.top(header)
    }

    /// The drives: 0 and 1, and 2 and 3 (the other sides) when there's a
    /// double-sided DFS disc.
    private func updateDrives() {
        let surfaces = model.surfaces
        let tooltips = surfaces.map { surface -> String in
            let drive = surface % 2
            guard let name = machine.discNames[drive] else { return "Drive \(surface): no disc" }
            return surface >= 2 ? "Drive \(surface): the other side of \(name)" : "Drive \(surface): \(name)"
        }
        if surfaces != driveSurfaces || tooltips != driveTooltips || driveGroup == nil {
            driveSurfaces = surfaces
            driveTooltips = tooltips
            let group = adw_toggle_group_new()!
            for (surface, tooltip) in zip(surfaces, tooltips) {
                let toggle = adw_toggle_new()!
                adw_toggle_set_label(toggle, "Drive \(surface)")
                adw_toggle_set_tooltip(toggle, tooltip)
                adw_toggle_set_name(toggle, "\(surface)")
                adw_toggle_group_add(cast(group), toggle)
            }
            adw_toggle_group_set_homogeneous(cast(group), 1)
            let widget = Widget(group)
            widget.tooltip("The BBC’s drives 2 and 3 are the other sides of double-sided DFS discs")
                .accessibleLabel("Drive")
            adw_toggle_group_set_active(cast(group), guint(surfaces.firstIndex(of: model.surface) ?? 0))
            widget.object.onChange("active") { [weak self] in
                guard let self else { return }
                let index = Int(adw_toggle_group_get_active(cast(group)))
                if self.driveSurfaces.indices.contains(index), self.model.surface != self.driveSurfaces[index] {
                    self.showSurface(self.driveSurfaces[index])
                }
            }
            drives.child = widget
            driveGroup = group
        } else if let group = driveGroup, let index = surfaces.firstIndex(of: model.surface),
                  adw_toggle_group_get_active(cast(group)) != guint(index) {
            adw_toggle_group_set_active(cast(group), guint(index))
        }
    }

    /// Shows another drive: its files as last read (no waiting for the
    /// read the drive's change starts).
    private func showSurface(_ surface: Int) {
        model.surface = surface
        model.goUp(to: 0)
    }

    // MARK: The title and boot option

    private func buildInfoBar() {
        let titleLabel = Label("_Title")
        gtk_label_set_use_underline(cast(titleLabel.widget), 1)
        gtk_label_set_mnemonic_widget(cast(titleLabel.widget), titleEntry.widget)
        titleEntry.widthChars(16).tooltip("The disc’s title, which *CAT shows")
        titleEntry.onActivate { [weak self] in self?.commitTitle() }
        let focus = FocusController()
        focus.onEnter { [weak self] in self?.titleFocused = true }
        focus.onLeave { [weak self] in
            self?.titleFocused = false
            self?.commitTitle()
        }
        titleEntry.add(focus)
        // Escape puts it back.
        let keys = KeyController().onPressed { [weak self] key, _, _ in
            guard let self, key == UInt32(GDK_KEY_Escape) else { return false }
            self.titleEntry.text = self.model.title
            return false
        }
        titleEntry.add(keys)

        let bootLabel = Label("_Boot")
        gtk_label_set_use_underline(cast(bootLabel.widget), 1)
        gtk_label_set_mnemonic_widget(cast(bootLabel.widget), bootChoice.widget)
        bootChoice.tooltip("What Shift-Break does with !BOOT (*OPT 4)")
        bootChoice.object.onChange("selected") { [weak self] in
            guard let self, !self.syncing, self.bootChoice.selected >= 0 else { return }
            self.model.setBootOption(self.bootChoice.selected, undoManager: self.undoManager)
        }
        freeSpace.ellipsize(PANGO_ELLIPSIZE_START).tooltip("Free space on this side of the disc")

        infoBar.append(titleLabel)
        infoBar.append(titleEntry)
        infoBar.append(Separator(GTK_ORIENTATION_VERTICAL).style("spacer").margin(horizontal: 4))
        infoBar.append(bootLabel)
        infoBar.append(bootChoice)
        infoBar.append(Spacer())
        infoBar.append(freeSpace)
        infoBar.style("toolbar", "macbeeb-files-bar")
        toolbarView.top(infoBar)
        adw_toolbar_view_set_top_bar_style(cast(toolbarView.widget), ADW_TOOLBAR_RAISED_BORDER)
    }

    private func commitTitle() {
        guard model.volume != nil, model.problem == nil else { return }
        if titleEntry.text != model.title {
            model.setTitle(titleEntry.text, undoManager: undoManager)
        }
    }

    // MARK: The files

    private func buildTable() {
        table.style("macbeeb-files")
        table.accessibleLabel("Files")
        gtk_column_view_set_enable_rubberband(cast(table.widget), 1)
        column("Name", key: "name", width: 200, expand: true, icon: true, text: { $0.name }) {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        column("Load", key: "load", width: 96, monospace: true, text: { [weak self] item in
            item.isDirectory ? "" : self?.hex(item.loadAddress) ?? ""
        }) { $0.loadAddress < $1.loadAddress }
        column("Exec", key: "exec", width: 96, monospace: true, text: { [weak self] item in
            item.isDirectory ? "" : self?.hex(item.executionAddress) ?? ""
        }) { $0.executionAddress < $1.executionAddress }
        column("Length", key: "length", width: 84, monospace: true, text: { item in
            item.isDirectory ? "" : String(format: "%06X", item.length)
        }) { $0.length < $1.length }
        column("Access", key: "access", width: 76, text: { $0.access }) {
            $0.access.compare($1.access) == .orderedAscending
        }

        // The header's sorting is the model's.
        if let name = columns["name"] {
            gtk_column_view_sort_by_column(cast(table.widget), name, GTK_SORT_ASCENDING)
        }
        let sorter = gtk_column_view_get_sorter(cast(table.widget))!
        GObjectRef(sorter).onInt("changed") { [weak self] _ in
            guard let self else { return }
            let viewSorter: OpaquePointer = cast(sorter)
            guard let column = gtk_column_view_sorter_get_primary_sort_column(viewSorter),
                  let key = self.columnKeys[column] else { return }
            let ascending = gtk_column_view_sorter_get_primary_sort_order(viewSorter) == GTK_SORT_ASCENDING
            let order = [DiscSort(key: key, ascending: ascending)]
            if self.model.sortOrder != order { self.model.sortOrder = order }
        }

        table.onSelectionChanged { [weak self] rows in
            guard let self, !self.syncing else { return }
            let ids = Set(rows.compactMap { self.shown.indices.contains($0) ? self.shown[$0].id : nil })
            if self.model.selection != ids { self.model.selection = ids }
        }
        table.onActivate { [weak self] row in
            guard let self, self.shown.indices.contains(row) else { return }
            self.openOrInfo(self.shown[row])
        }
        table.onContextClick { [weak self] x, y in self?.showContextMenu(x: x, y: y) }
        table.filesShortcut("Delete", action: "win.delete").filesShortcut("KP_Delete", action: "win.delete")
    }

    /// A column whose cells are a label (with the item's icon, for names),
    /// each knowing its row, and dragging out the files they show.
    private func column(_ title: String, key: String, width: Int32, expand: Bool = false, monospace: Bool = false,
                        icon: Bool = false, text: @escaping @MainActor (DiscVolume.Item) -> String,
                        before: @escaping @MainActor (DiscVolume.Item, DiscVolume.Item) -> Bool) {
        let factory = gtk_signal_list_item_factory_new()!
        let column = gtk_column_view_column_new(title, factory)!
        typealias Cell = @MainActor (OpaquePointer) -> Void
        let setup: Cell = { [weak self] item in
            let box = Box(.horizontal, spacing: 8)
            if icon {
                box.append(Icon("text-x-generic-symbolic"))
            }
            let label = Label()
            label.ellipsize().expand(horizontal: true)
            if monospace { label.style("monospace") }
            box.append(label)
            let cell = box.widget
            box.add(DragSource { [weak self] _, _ in
                guard let self, let row = Widget.row(of: cell) else { return nil }
                return self.dragOut(row: row)
            })
            gtk_list_item_set_child(item, box.widget)
        }
        let bind: Cell = { [weak self] item in
            guard let self, let child = gtk_list_item_get_child(item),
                  let row = filesListIndex(gtk_list_item_get_item(item)), self.shown.indices.contains(row) else { return }
            let entry = self.shown[row]
            Widget(child).setRow(row)
            var node = gtk_widget_get_first_child(child)
            while let current = node {
                if let image = macbeeb_files_image(current) {
                    gtk_image_set_from_icon_name(image, entry.isDirectory ? "folder-symbolic" : "text-x-generic-symbolic")
                } else {
                    gtk_label_set_text(cast(current), text(entry))
                }
                node = gtk_widget_get_next_sibling(current)
            }
        }
        for (signal, body) in [("setup", setup), ("bind", bind)] {
            macbeeb_signal_connect(gpointer(factory), signal, unsafeBitCast(
                { (_: gpointer?, item: gpointer?, data: gpointer?) in
                    nonisolated(unsafe) let item = item, data = data
                    MainActor.assumeIsolated {
                        guard let item else { return }
                        Boxed<Cell>.from(data)(OpaquePointer(item))
                    }
                } as @convention(c) (gpointer?, gpointer?, gpointer?) -> Void, to: GCallback.self),
                Boxed<Cell>(body).retained, { data, _ in AnyBox.release(data) }, 0)
        }

        typealias Compare = @MainActor (Int, Int) -> Int32
        let compare: Compare = { [weak self] a, b in
            guard let self, self.shown.indices.contains(a), self.shown.indices.contains(b) else { return 0 }
            let x = self.shown[a], y = self.shown[b]
            return before(x, y) ? -1 : before(y, x) ? 1 : 0
        }
        let sorter = gtk_custom_sorter_new({ a, b, data in
            nonisolated(unsafe) let a = a, b = b, data = data
            return MainActor.assumeIsolated {
                Boxed<Compare>.from(data)(filesListIndex(a) ?? 0, filesListIndex(b) ?? 0)
            }
        }, Boxed<Compare>(compare).retained, { AnyBox.release($0) })
        gtk_column_view_column_set_sorter(column, cast(sorter!))
        g_object_unref(gpointer(sorter))

        gtk_column_view_column_set_expand(column, expand ? 1 : 0)
        gtk_column_view_column_set_resizable(column, 1)
        gtk_column_view_column_set_fixed_width(column, width)
        gtk_column_view_append_column(cast(table.widget), column)
        g_object_unref(gpointer(column))
        columnKeys[column] = key
        columns[key] = column
    }

    /// As *INFO shows them: DFS's six digits (FF for the I/O processor),
    /// ADFS's eight.
    private func hex(_ address: UInt32) -> String {
        if isADFS {
            return String(format: "%08X", address)
        }
        return address >= 0xFFFF_0000 ? String(format: "FF%04X", address & 0xFFFF) : String(format: "%06X", address)
    }

    /// The table follows the model: its items, and their selection.
    private func syncTable() {
        syncing = true
        defer { syncing = false }
        let adfs = model.volume?.isADFS ?? false
        if shown != model.items || adfs != isADFS {
            isADFS = adfs
            shown = model.items
            table.reload(count: shown.count)
        }
        let rows = Set(shown.indices.filter { model.selection.contains(shown[$0].id) })
        if table.selectedRows != rows {
            table.select(rows)
        }
    }

    /// The row at a point in the table, if there's one there.
    private func row(atX x: Double, y: Double) -> Int? {
        guard var node = gtk_widget_pick(table.widget, x, y, GTK_PICK_DEFAULT) else { return nil }
        while node != table.widget {
            if let row = Widget.row(of: node) { return row }
            // (A cell's padding, or between cells: its label's below.)
            if let child = gtk_widget_get_first_child(node) {
                if let row = Widget.row(of: child) { return row }
                if let grandchild = gtk_widget_get_first_child(child), let row = Widget.row(of: grandchild) { return row }
            }
            guard let parent = gtk_widget_get_parent(node) else { break }
            node = parent
        }
        return nil
    }

    private func openOrInfo(_ item: DiscVolume.Item) {
        if item.isDirectory {
            model.open(item)
        } else {
            showInfo(item)
        }
    }

    // MARK: The context menu

    private func showContextMenu(x: Double, y: Double) {
        if let row = row(atX: x, y: y), shown.indices.contains(row), !model.selection.contains(shown[row].id) {
            model.selection = [shown[row].id]
            syncTable()
            updateActions()
        }
        let items = model.selectedItems
        guard !items.isEmpty else { return }
        var entries: [MenuEntry] = []
        var first: [MenuEntry] = []
        if items.count == 1 {
            let item = items[0]
            first.append(MenuItem(item.isDirectory ? "Open" : "Get Info", "win.open-item"))
            if item.isDirectory {
                first.append(MenuItem("Get Info", "win.get-info"))
            }
        }
        first.append(MenuItem("Export…", "win.export"))
        if items.count == 1, model.isBASIC(items[0]) {
            first.append(MenuItem("Export as Text…", "win.export-text"))
        }
        entries.append(.section(label: nil, entries: first))
        entries.append(.section(label: nil, entries: [MenuItem("Delete", "win.delete", accel: "Delete")]))
        contextMenu.set(entries)
        contextPopover.show(on: table, at: x, y: y)
    }

    // MARK: Dragging out, dropping in

    /// Writes the files a drag from `row` takes (the selection, if the row's
    /// in it) where the file manager can copy them, each with its .inf.
    private func dragOut(row: Int) -> [URL]? {
        guard let volume = model.volume, shown.indices.contains(row) else { return nil }
        let rows = table.selectedRows.contains(row) ? table.selectedRows.sorted() : [row]
        let items = rows.compactMap { shown.indices.contains($0) ? shown[$0] : nil }
        // (The last drag's copies have been taken by now.)
        try? FileManager.default.removeItem(at: dragFolder)
        let folder = dragFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let written = try DiscContentsModel.export(items, from: volume, at: model.location, to: folder)
            var urls: [URL] = []
            for (item, url) in zip(items, written) {
                urls.append(url)
                if !item.isDirectory { urls.append(url.appendingPathExtension("inf")) }
            }
            return urls
        } catch {
            model.alert = error.localizedDescription
            return nil
        }
    }

    private func installDrop(on widget: Widget) {
        let dragRoot = dragFolder.deletingLastPathComponent().standardizedFileURL.path
        let target = DropTarget.files { [weak self] urls, _, _ in
            guard let self, self.model.volume != nil, self.model.problem == nil else { return false }
            // (Not our own files, dragged out and back.)
            let incoming = urls.filter { !$0.standardizedFileURL.path.hasPrefix(dragRoot) }
            guard !incoming.isEmpty else { return false }
            self.model.add(incoming, undoManager: self.undoManager)
            return true
        }
        widget.add(target)
    }

    // MARK: Content

    private func buildContent() {
        problemButtons.append(Button("_New Disc…").action("win.new-disc").style("suggested-action", "pill"))
        problemButtons.append(Button("_Insert Disc…").action("win.insert-disc").style("pill"))
        problemButtons.align(horizontal: GTK_ALIGN_CENTER)
        gtk_box_set_homogeneous(cast(problemButtons.widget), 1)
        adw_status_page_set_child(cast(problemPage.widget), problemButtons.widget)

        emptyPage.detail = "Drag files here from the file manager, or choose Add Files. Files with .inf files beside "
            + "them keep their BBC names and addresses; .bas text becomes a BASIC program."
        let addFiles = Button("_Add Files…").action("win.add-files").style("pill").align(horizontal: GTK_ALIGN_CENTER)
        adw_status_page_set_child(cast(emptyPage.widget), addFiles.widget)

        stack.add(ScrolledWindow(table, horizontal: GTK_POLICY_AUTOMATIC).expand(), name: "files")
        stack.add(emptyPage, name: "empty")
        stack.add(problemPage, name: "problem")
        stack.add(Box(.vertical), name: "reading")
        installDrop(on: stack)
        toolbarView.content = stack
    }

    // MARK: The footer

    private func buildFooter() {
        waitingSpinner.size(width: 16, height: 16)
        footerStatus.ellipsize()
        footer.append(pathBar)
        footer.append(Spacer())
        footer.append(waitingSpinner)
        footer.append(footerStatus)
        footer.style("toolbar", "macbeeb-files-bar")
        toolbarView.bottom(footer)
        adw_toolbar_view_set_bottom_bar_style(cast(toolbarView.widget), ADW_TOOLBAR_RAISED_BORDER)
    }

    private func updateFooter() {
        let showingPath = isADFS && model.problem == nil && model.volume != nil
        let names = showingPath ? model.path.map(\.name) : []
        if names != shownPath || pathBar.isVisible != showingPath {
            shownPath = names
            pathBar.removeAll()
            if showingPath {
                let crumbs = ["$"] + names
                for (depth, name) in crumbs.enumerated() {
                    if depth > 0 {
                        pathBar.append(Icon("go-next-symbolic", size: 12).style("dim-label"))
                    }
                    if depth == crumbs.count - 1 {
                        pathBar.append(Label(name, style: "heading").margin(horizontal: 6))
                    } else {
                        let model = model
                        pathBar.append(Button(name) { model.goUp(to: depth) }.style("flat")
                            .tooltip(depth == 0 ? "The root directory" : "Back to \(name)"))
                    }
                }
            }
            pathBar.isVisible = showingPath
        }
        waitingSpinner.isVisible = model.waiting
        if model.waiting {
            footerStatus.text = "Waiting for drive \(model.drive) to stop…"
        } else if model.adfsChanged.contains(model.drive) {
            footerStatus.text = "The BBC’s ADFS will say “Disc changed” until you *MOUNT."
        } else {
            footerStatus.text = ""
        }
        let reveal = showingPath || !footerStatus.text.isEmpty
        adw_toolbar_view_set_reveal_bottom_bars(cast(toolbarView.widget), reveal ? 1 : 0)
    }

    // MARK: Following the model

    private func observe() {
        let machine = machine
        let model = model
        window.track {
            // A disc in or out, or another drive shown. (Reloaded outside
            // the tracking: reloading reads and sets the model's own state.)
            _ = machine.discChanges
            _ = model.surface
            Task { @MainActor in model.reload() }
        }
        window.track { [weak self] in
            guard let self else { return }
            let disc = machine.discNames[model.drive].map { " — \($0)" } ?? ""
            self.window.title = "Drive \(model.surface)\(disc)"
            self.updateDrives()
        }
        window.track { [weak self] in
            guard let self else { return }
            let volume = model.volume
            let problem = model.problem
            let usable = volume != nil && problem == nil
            self.syncing = true
            if let problem {
                let noDisc = machine.discNames[model.drive] == nil || (volume.map { model.side >= $0.sideCount } ?? false)
                self.problemPage.title = noDisc ? "No Disc" : "Can’t Show the Disc"
                self.problemPage.detail = problem
                self.problemButtons.isVisible = machine.discNames[model.drive] == nil
                self.stack.visible = "problem"
            } else if volume == nil {
                self.stack.visible = "reading"
            } else {
                self.emptyPage.title = model.path.isEmpty ? "No Files" : "Empty Directory"
                self.stack.visible = model.items.isEmpty ? "empty" : "files"
                if !model.items.isEmpty, !self.tableFocused {
                    // The keyboard starts in the files.
                    self.tableFocused = true
                    self.table.grabFocus()
                }
            }
            self.infoBar.isVisible = usable
            self.newDirectoryButton.isVisible = volume?.isADFS == true && problem == nil
            if let volume, usable {
                gtk_entry_set_max_length(cast(self.titleEntry.widget), Int32(volume.maxTitleLength))
                if !self.titleFocused { self.titleEntry.text = model.title }
                self.bootChoice.selected = model.bootOption
                self.freeSpace.text = model.freeSpace
            }
            self.syncing = false
            self.syncTable()
            self.updateFooter()
            self.updateActions()
        }
        window.track { [weak self] in
            // (Waiting, and the ADFS note, change on their own.)
            _ = model.waiting
            _ = model.adfsChanged
            self?.updateFooter()
        }
        window.track { [weak self] in
            guard let self, let alert = model.alert, !self.alertShowing else { return }
            self.alertShowing = true
            AlertDialog("The disc can’t be changed", body: alert)
                .response("ok", "_OK", .suggested)
                .defaults(default: "ok", close: "ok")
                .choose(over: self.window) { [weak self] _ in
                    self?.alertShowing = false
                    model.alert = nil
                }
        }
    }

    // MARK: Adding and exporting

    private func addFiles(folders: Bool) {
        let completion: @MainActor ([URL]) -> Void = { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.model.add(urls, undoManager: self.undoManager)
        }
        if folders {
            FilesDialogs.openFolders(title: "Add Folders", accept: "_Add", over: window, completion)
        } else {
            FilesDialogs.openFiles(title: "Add Files", accept: "_Add", over: window, completion)
        }
    }

    private func exportSelection() {
        let items = model.selectedItems
        guard !items.isEmpty else { return }
        FilesDialogs.chooseFolder(title: "Export", accept: "_Export", over: window) { [weak self] folder in
            guard let self, let folder else { return }
            self.export(items, to: folder)
        }
    }

    private func export(_ items: [DiscVolume.Item], to folder: URL) {
        do {
            try model.export(items, to: folder)
            let message = items.count == 1 ? "Exported “\(items[0].name)”, with a .inf file"
                : "Exported \(items.count) files, each with a .inf file"
            toasts.show(message, button: "_Open Folder") { Launcher.open(folder) }
        } catch {
            Platform.showError(error)
        }
    }

    // MARK: Info and naming

    private func showInfo(_ item: DiscVolume.Item) {
        guard let volume = model.volume else { return }
        FileInfoDialog(item: item, adfs: volume.isADFS) { [weak self] name, load, exec, locked in
            guard let self else { return }
            self.model.update(item, name: name, loadAddress: load, executionAddress: exec, locked: locked,
                              undoManager: self.undoManager)
        }
        .present(over: window)
    }

    private func nameDirectory() {
        guard model.volume?.isADFS == true else { return }
        let entry = Entry(placeholder: "Name").maxLength(Int32(ADFSDisc.maxNameLength))
        gtk_entry_set_activates_default(cast(entry.widget), 1)
        entry.accessibleLabel("Name")
        let dialog = AlertDialog("New Directory")
            .response("cancel", "_Cancel")
            .response("make", "_Make", .suggested)
            .defaults(default: "make", close: "cancel")
            .extra(entry)
        adw_alert_dialog_set_response_enabled(cast(dialog.widget), "make", 0)
        entry.onChanged { text in
            adw_alert_dialog_set_response_enabled(cast(dialog.widget), "make", ADFSDisc.isValidName(text) ? 1 : 0)
        }
        dialog.focus(entry)
        dialog.choose(over: window) { [weak self] response in
            guard let self, response == "make", ADFSDisc.isValidName(entry.text) else { return }
            self.model.createDirectory(named: entry.text, undoManager: self.undoManager)
        }
    }

    // MARK: Self-tests

    private func selfTest(_ verb: String, _ argument: String) async {
        switch verb {
        case "drive":
            showSurface(Int(argument) ?? 0)
        case "insert":
            // "insert:1:/path/disc.ssd"
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let drive = Int(parts[0]) {
                machine.insertDisc(URL(fileURLWithPath: parts[1]), drive: drive, boot: false)
            }
        case "select":
            let rows = argument.split(separator: ",").compactMap { Int($0) }
            model.selection = Set(rows.compactMap { shown.indices.contains($0) ? shown[$0].id : nil })
        case "select-name":
            model.selection = Set(shown.filter { argument.split(separator: ",").map(String.init).contains($0.name) }.map(\.id))
        case "info":
            gtk_widget_activate_action_variant(window.widget, "win.get-info", nil)
        case "open":
            gtk_widget_activate_action_variant(window.widget, "win.open-item", nil)
        case "up":
            gtk_widget_activate_action_variant(window.widget, "win.go-up", nil)
        case "menu":
            let rows = table.selectedRows.sorted()
            showContextMenu(x: 120, y: Double(40 + (rows.first ?? 0) * 26))
            try? await Task.sleep(for: .milliseconds(600))
            FilesSelfTest.capture(contextPopover.widget, as: "menu")
        case "blank":
            FilesSelfTest.blank(argument, machine: machine)
        case "update":
            // "update:NEWNAME,load,exec,locked" for the selected file.
            let parts = argument.split(separator: ",").map(String.init)
            if parts.count == 4, let item = model.selectedItems.first {
                model.update(item, name: parts[0], loadAddress: FileInfoDialog.address(parts[1]) ?? item.loadAddress,
                             executionAddress: FileInfoDialog.address(parts[2]) ?? item.executionAddress,
                             locked: parts[3] == "1", undoManager: undoManager)
            }
        case "watch-prints":
            // (What App's startup does.)
            PrintCentreWindow.watchArrivals()
        case "type":
            machine.host.send(.type(argument + "\n"))
        case "primary-menu":
            menuButton.popup()
            try? await Task.sleep(for: .milliseconds(600))
            FilesSelfTest.capture(gtk_menu_button_get_popover(cast(menuButton.widget)).map { cast($0) }, as: "primary-menu")
        case "newdir":
            nameDirectory()
        case "mkdir":
            model.createDirectory(named: argument, undoManager: undoManager)
        case "add":
            model.add(argument.split(separator: "|").map { URL(fileURLWithPath: String($0)) }, undoManager: undoManager)
        case "delete":
            model.delete(model.selectedItems, undoManager: undoManager)
        case "undo":
            gtk_widget_activate_action_variant(window.widget, "win.undo", nil)
        case "redo":
            gtk_widget_activate_action_variant(window.widget, "win.redo", nil)
        case "title":
            model.setTitle(argument, undoManager: undoManager)
        case "boot":
            model.setBootOption(Int(argument) ?? 0, undoManager: undoManager)
        case "sort":
            let parts = argument.split(separator: ",").map(String.init)
            if let column = columns[parts[0]] {
                gtk_column_view_sort_by_column(cast(table.widget), column,
                                               parts.count > 1 && parts[1] == "desc" ? GTK_SORT_DESCENDING : GTK_SORT_ASCENDING)
            }
        case "export":
            export(model.selectedItems, to: URL(fileURLWithPath: argument))
        case "drag":
            let urls = dragOut(row: table.selectedRows.min() ?? 0) ?? []
            FilesSelfTest.log("drag: " + urls.map(\.path).joined(separator: ", "))
        case "drop":
            let urls = argument.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            model.add(urls, undoManager: undoManager)
        case "dump":
            FilesSelfTest.log("items: " + shown.map { "\($0.name) \(hex($0.loadAddress)) \($0.access)" }.joined(separator: ", "))
            FilesSelfTest.log("title: \(model.title) boot: \(model.bootOption) free: \(model.freeSpace) undo: \(undoManager.undoActionName)")
        default:
            FilesSelfTest.log("unknown step \(verb)")
        }
    }
}

// MARK: Rows

extension Widget {
    /// GObject data on the widget: a small number (a row's index).
    fileprivate func setRow(_ row: Int?, key: String = "macbeeb-files-row") {
        g_object_set_data(object.gObject, key, row.map { gpointer(bitPattern: $0 + 1) } ?? nil)
    }

    fileprivate static func row(of widget: WidgetPointer, key: String = "macbeeb-files-row") -> Int? {
        guard let data = g_object_get_data(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self), key)
        else { return nil }
        return Int(bitPattern: data) - 1
    }
}

// MARK: Get Info

/// A file's (or directory's) name, addresses and lock. (The Mac's
/// FileInfoSheet.)
@MainActor
final class FileInfoDialog {
    let item: DiscVolume.Item
    let adfs: Bool
    let onSave: @MainActor (String, UInt32, UInt32, Bool) -> Void

    init(item: DiscVolume.Item, adfs: Bool, onSave: @escaping @MainActor (String, UInt32, UInt32, Bool) -> Void) {
        self.item = item
        self.adfs = adfs
        self.onSave = onSave
    }

    func present(over parent: Window) {
        let item = item, adfs = adfs
        let name = EntryRow("Name", text: item.name)
        let load = EntryRow("Load address", text: format(item.loadAddress)).style("macbeeb-mono")
        let exec = EntryRow("Execution address", text: format(item.executionAddress)).style("macbeeb-mono")
        let length = ActionRow("Length", subtitle: "\(item.length) bytes (&\(String(item.length, radix: 16, uppercase: true)))")
            .property().subtitleSelectable()
        let locked = SwitchRow("Locked", isOn: item.locked)
        let group = PreferencesGroup {
            name
            if !item.isDirectory {
                load
                exec
                length
            }
            locked
        }
        let problem = Label("", style: "caption", "error").wrap()
        let cancel = Button("_Cancel")
        let save = Button("_Save").style("suggested-action")
        let header = HeaderBar().showsWindowButtons(start: false, end: false).start(cancel).end(save)
        let body = Box(.vertical, spacing: 12) {
            group
            problem
        }
        .margin(top: 12, bottom: 18, start: 24, end: 24)
        let dialog = Dialog(title: "Info for “\(item.name)”", content: ToolbarView(content: body).top(header), width: 420)
        dialog.defaultWidget(save)

        func nameIsValid() -> Bool {
            if adfs {
                return ADFSDisc.isValidName(name.text)
            }
            let (directory, leaf) = DiscVolume.dfsNameParts(name.text)
            return DFSDisc.isValidName(leaf) && DFSDisc.isValidDirectory(directory)
        }
        func addressesAreValid() -> Bool {
            item.isDirectory || (Self.address(load.text) != nil && Self.address(exec.text) != nil)
        }
        func validate() {
            if !nameIsValid() {
                problem.text = adfs ? "Up to 10 characters, without spaces or . : * # $ & @ ^ % \\ | \""
                    : "Up to 7 characters (after a directory and a dot, as in W.DATA), without spaces or . : # * \""
            } else if !addressesAreValid() {
                problem.text = "Addresses are in hex, up to 8 digits (6 starting FF mean the I/O processor)."
            } else {
                problem.text = ""
            }
            problem.isVisible = !problem.text.isEmpty
            save.isEnabled = problem.text.isEmpty
        }
        let onSave = onSave
        func commit() {
            guard nameIsValid(), addressesAreValid() else { return }
            onSave(name.text, Self.address(load.text) ?? item.loadAddress, Self.address(exec.text) ?? item.executionAddress,
                   locked.isOn)
            dialog.close()
        }
        for row in [name, load, exec] {
            row.object.on("changed") { validate() }
            row.object.on("entry-activated") { commit() }
        }
        cancel.onClicked { dialog.close() }
        save.onClicked { commit() }
        validate()
        dialog.focus(name)
        dialog.present(over: parent)
    }

    private func format(_ address: UInt32) -> String {
        !adfs && address >= 0xFFFF_0000 ? String(format: "FF%04X", address & 0xFFFF)
            : String(format: adfs ? "%08X" : "%06X", address)
    }

    /// Hex, with or without & or 0x; six digits from FF mean FFFFxxxx.
    static func address(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespaces).uppercased()
        if digits.hasPrefix("&") {
            digits.removeFirst()
        } else if digits.hasPrefix("0X") {
            digits.removeFirst(2)
        }
        guard !digits.isEmpty, digits.count <= 8, let value = UInt32(digits, radix: 16) else { return nil }
        return digits.count <= 6 && value >> 16 == 0xFF ? 0xFFFF_0000 | value & 0xFFFF : value
    }
}
