import BeebCore
import BeebNetwork
import CGtk
import Foundation

/// Machine > ROM Library: the user's sideways ROMs, kept as copies so
/// machines and networks can use them whatever happens to the files.
/// Each has a name and a layout (how a ROM bigger than 16K is switched).
@MainActor
enum ROMLibraryWindow {
    static func show() {
        Windows.show("rom-library") { ROMLibraryController().window }
        HardwareSelfTest.windowShown(key: "rom-library")
    }
}

@MainActor
final class ROMLibraryController {
    let window = Window(title: "ROM Library", width: 780, height: 480)
    private let table = ItemTable()
    private let stack = Stack()
    private let removeButton = Button(icon: "list-remove-symbolic")
    private var removeAction: Action!
    private var roms: [UserROM] = []

    private var library: ROMLibrary { ROMLibrary.shared }

    init() {
        HardwareStyles.install()
        window.minimumSize(width: 560, height: 320)

        let add = Button(icon: "list-add-symbolic") { [weak self] in self?.add() }
            .tooltip("Add ROM image files to the library")
            .accessibleLabel("Add ROMs…")
        removeButton.onClicked { [weak self] in self?.confirmRemove(self?.selected ?? []) }
        removeButton.tooltip("Remove the selected ROMs from the library").accessibleLabel("Remove")
        let header = HeaderBar()
        header.start(add).start(removeButton)

        let empty = StatusPage(icon: "media-flash-symbolic", title: "No ROMs",
                               description: Markup.escape("Add sideways ROM images (.rom, .bin) to plug them into your machines' sockets. Drop files here, or click Add."),
                               child: Button("Add ROMs…") { [weak self] in self?.add() }
                                .style("suggested-action", "pill")
                                .align(horizontal: GTK_ALIGN_CENTER))
        empty.compact()
        buildTable()
        stack.add(empty, name: "empty")
        stack.add(ScrolledWindow(table, horizontal: GTK_POLICY_AUTOMATIC).expand(), name: "table")
        let content = Bin(stack).style("hw-drop")
        content.onDropFiles { [weak self] urls, _, _ in
            self?.add(urls)
            return true
        }
        window.content = ToolbarView(content: content).top(header)
        App.addStandardShortcuts(to: window)
        window.action("close") { [weak window] in window?.close() }
        removeAction = window.action("remove") { [weak self] in self?.confirmRemove(self?.selected ?? []) }
        window.action("show-in-files") { [weak self] in self?.showInFiles() }
        window.action("rename") { [weak self] in self?.rename() }
        window.shortcut("<Control>o", action: "win.add")
        window.action("add") { [weak self] in self?.add() }

        window.track { [weak self] in self?.reload() }
        window.keep(self)
    }

    private var selected: [UserROM] {
        table.selectedRows.sorted().compactMap { roms.indices.contains($0) ? roms[$0] : nil }
    }

    // MARK: The table

    private func buildTable() {
        table.column("Name", expand: true) { [weak self] in
            NameCell(name: { row in self?.rom(row)?.name ?? "" }) { row, name in
                guard var renamed = self?.rom(row), !name.isEmpty else {
                    self?.reload()
                    return
                }
                renamed.name = name
                try? self?.library.update(renamed)
            }
        }
        table.column("ROM", width: 180) { [weak self] in
            TextCell { row in
                guard let rom = self?.rom(row) else { return ("", false, nil) }
                return (rom.title.map { [$0, rom.version].compactMap { $0 }.joined(separator: " ") } ?? "No ROM header",
                        rom.title == nil, rom.copyright)
            }
        }
        table.column("Type", width: 90) { [weak self] in
            TextCell { row in
                guard let rom = self?.rom(row) else { return ("", false, nil) }
                return (rom.title == nil ? "—" : rom.isLanguage ? "Language" : "Service", true, nil)
            }
        }
        table.column("Layout", width: 200) { [unowned self] in LayoutCell(library: self) }
        table.column("Size", width: 90) { [weak self] in
            TextCell(numeric: true) { row in
                guard let rom = self?.rom(row) else { return ("", false, nil) }
                return (rom.size >= 1024 ? "\(rom.size / 1024)K" : "\(rom.size) bytes", true, nil)
            }
        }
        table.onSelectionChanged { [weak self] in self?.selectionChanged() }
        table.onActivate { [weak self] _ in self?.rename() }
        table.onKey { [weak self] keyval in
            guard let self else { return false }
            switch Int32(keyval) {
            case GDK_KEY_Delete, GDK_KEY_KP_Delete, GDK_KEY_BackSpace:
                self.confirmRemove(self.selected)
                return true
            case GDK_KEY_F2:
                self.rename()
                return true
            default:
                return false
            }
        }
        let menu = Popover(menu: Menu {
            MenuSection {
                MenuItem("Rename…", "win.rename")
                MenuItem("Show in Files", "win.show-in-files")
            }
            MenuSection {
                MenuItem("Remove…", "win.remove")
            }
        })
        table.onContextMenu = { [weak self] _, x, y in
            guard let self else { return }
            menu.show(on: self.table, at: x, y: y)
        }
    }

    fileprivate func rom(_ row: Int) -> UserROM? {
        roms.indices.contains(row) ? roms[row] : nil
    }

    fileprivate func setLayout(_ layout: ROMLayout, row: Int) {
        guard var changed = rom(row), changed.layout != layout else { return }
        changed.layout = layout
        try? library.update(changed)
    }

    /// The library changed: the rows again, the same ROMs selected.
    private func reload() {
        let ids = Set(selected.map(\.id))
        roms = library.roms
        stack.visible = roms.isEmpty ? "empty" : "table"
        table.reload(count: roms.count)
        table.select(Set(roms.indices.filter { ids.contains(roms[$0].id) }))
        selectionChanged()
    }

    private func selectionChanged() {
        let any = !table.selectedRows.isEmpty
        removeButton.isEnabled = any
        removeAction.isEnabled = any
    }

    // MARK: Commands

    private func add() {
        // (The Mac's panel says: sideways ROM images, 16K or less, or 32K,
        // 64K or 128K, copied into the library.)
        ROMFileDialog.open(title: "Add ROMs", accept: "_Add", multiple: true) { [weak self] urls in
            self?.add(urls)
        }
    }

    private func add(_ urls: [URL]) {
        var problems: [String] = []
        var added: Set<String> = []
        for url in urls {
            do {
                added.insert(try library.add(fileAt: url).id)
            } catch {
                problems.append("\(error)")
            }
        }
        if !added.isEmpty {
            reload()
            table.select(Set(roms.indices.filter { added.contains(roms[$0].id) }))
            selectionChanged()
        }
        if !problems.isEmpty {
            HardwareAlerts.show("ROM Library", problems.joined(separator: "\n"), over: window)
        }
    }

    private func confirmRemove(_ removing: [UserROM]) {
        guard !removing.isEmpty else { return }
        HardwareAlerts.confirm(removing.count == 1 ? "Remove \(removing[0].name)?" : "Remove \(removing.count) ROMs?",
                               "Machines with it in a socket will say it's missing. Networks keep their own copies, so they still have it.",
                               action: "_Remove", over: window) { [weak self] in
            guard let self else { return }
            for rom in removing { try? self.library.remove(rom.id) }
            self.table.select([])
        }
    }

    private func showInFiles() {
        for rom in selected {
            Platform.reveal(library.folder.appendingPathComponent(ROMSource.fileName(for: rom.id)))
        }
    }

    private func rename() {
        let rows = table.selectedRows
        guard rows.count == 1, let row = rows.first else { return }
        table.cell(NameCell.self, row: row)?.startEditing()
    }
}

/// How a ROM goes into a machine: two 16K ROMs in one chip, or one ROM
/// switched by its own hardware. A choice where there is one.
@MainActor
private final class LayoutCell: TableCell {
    private weak var library: ROMLibraryController?
    private let picker = DropDown([])
    private let fixed = Label("", style: "dim-label")
    private var layouts: [ROMLayout] = []
    private var binding = false

    init(library: ROMLibraryController) {
        self.library = library
        let picker = picker, fixed = fixed
        let box = Box(.horizontal) {
            picker
            fixed
        }
        // (Every row as tall as one with a picker.)
        box.size(height: 34)
        picker.style("flat").align(vertical: GTK_ALIGN_CENTER)
        fixed.align(vertical: GTK_ALIGN_CENTER)
        super.init(box)
        picker.tooltip("How the ROM goes into a machine: two 16K ROMs in one chip, or one ROM switched by its own hardware")
        picker.accessibleLabel("Layout")
        fixed.ellipsize()
        picker.object.onChange("selected") { [weak self] in
            guard let self, !self.binding, self.layouts.indices.contains(self.picker.selected) else { return }
            self.library?.setLayout(self.layouts[self.picker.selected], row: self.row)
        }
    }

    override func bind() {
        guard let rom = library?.rom(row) else { return }
        binding = true
        defer { binding = false }
        layouts = ROMLibrary.shared.data(for: rom.id).map(ROMLayout.candidates(for:)) ?? [rom.layout]
        if !layouts.contains(rom.layout) { layouts.append(rom.layout) }
        let several = layouts.count > 1
        picker.isVisible = several
        fixed.isVisible = !several
        fixed.text = rom.layout.displayName
        if several {
            picker.setItems(layouts.map(\.displayName), selected: layouts.firstIndex(of: rom.layout) ?? 0)
        }
    }
}
