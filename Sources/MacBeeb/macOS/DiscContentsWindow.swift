import AppKit
import BeebCore
import SwiftUI
import UniformTypeIdentifiers

/// File > Show Disc Contents: the files on the discs in a machine's drives,
/// which can be dragged out to Finder (with .inf files) and in from it,
/// renamed, relocked, readdressed and deleted, with undo.
struct DiscContentsWindow: View {
    static let windowID = "disc-contents"
    let machine: MachineController
    @State private var model: DiscContentsModel
    @State private var titleText = ""
    @State private var editing: DiscVolume.Item?
    @State private var namingDirectory = false
    @FocusState private var titleFocused: Bool
    @Environment(\.undoManager) private var undoManager

    init(machine: MachineController) {
        self.machine = machine
        _model = State(initialValue: DiscContentsModel(machine: machine))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.problem == nil, let volume = model.volume {
                header(volume)
                Divider()
            }
            if let problem = model.problem {
                ContentUnavailableView {
                    Label(problem, systemImage: "opticaldiscdrive")
                } actions: {
                    if machine.discNames[model.drive] == nil {
                        HStack {
                            Button("New Disc…") { machine.newDisc(drive: model.drive) }
                                .buttonStyle(.borderedProminent)
                            Button("Insert Disc…") { machine.openDisc(drive: model.drive, boot: false) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiscFileTable(model: model, onInfo: { editing = $0 })
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle(windowTitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Drive", selection: $model.surface) {
                    ForEach(model.surfaces, id: \.self) { surface in
                        Text("Drive \(surface)").tag(surface)
                    }
                }
                .pickerStyle(.segmented)
                .help("The BBC’s drives 2 and 3 are the other sides of double-sided DFS discs")
            }
            ToolbarItemGroup {
                Button("Add Files…", systemImage: "plus") { addFiles() }
                    .help("Copy Mac files onto the disc")
                    .disabled(model.volume == nil || model.problem != nil)
                if model.volume?.isADFS == true {
                    Button("New Directory", systemImage: "folder.badge.plus") { namingDirectory = true }
                        .help("Make a directory")
                }
                Button("Export…", systemImage: "square.and.arrow.up") { exportSelection() }
                    .help("Copy the selected files to a folder on the Mac, with .inf files")
                    .disabled(model.selection.isEmpty)
                Button("Get Info", systemImage: "info.circle") { editing = model.selectedItems.first }
                    .help("Rename, readdress or lock the selected file")
                    .disabled(model.selection.count != 1)
                Button("Delete", systemImage: "trash") { model.delete(model.selectedItems, undoManager: undoManager) }
                    .help("Delete the selected files")
                    .disabled(model.selection.isEmpty)
            }
        }
        .onAppear { model.reload() }
        .onChange(of: machine.discChanges) { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.reload() }
        .onChange(of: model.title, initial: true) {
            if !titleFocused {
                titleText = model.title
            }
        }
        .onChange(of: titleFocused) {
            if !titleFocused {
                model.setTitle(titleText, undoManager: undoManager)
            }
        }
        .alert("The disc can’t be changed", isPresented: Binding(get: { model.alert != nil },
                                                                 set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .sheet(item: $editing) { item in
            FileInfoSheet(item: item, adfs: model.volume?.isADFS ?? false,
                          maxNameLength: model.volume?.maxNameLength ?? 7) { name, load, exec, locked in
                model.update(item, name: name, loadAddress: load, executionAddress: exec, locked: locked,
                             undoManager: undoManager)
            }
        }
        .sheet(isPresented: $namingDirectory) {
            NameSheet(title: "New Directory", prompt: "Make", maxLength: ADFSDisc.maxNameLength) { name in
                model.createDirectory(named: name, undoManager: undoManager)
            }
        }
    }

    private var windowTitle: String {
        let disc = machine.discNames[model.drive].map { " — \($0)" } ?? ""
        return "Drive \(model.surface)\(disc)"
    }

    private func header(_ volume: DiscVolume) -> some View {
        HStack(spacing: 12) {
            TextField("Title", text: $titleText, prompt: Text("No title"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .focused($titleFocused)
                .onSubmit { model.setTitle(titleText, undoManager: undoManager) }
                .onChange(of: titleText) {
                    if titleText.count > volume.maxTitleLength {
                        titleText = String(titleText.prefix(volume.maxTitleLength))
                    }
                }
                .help("The disc’s title, which *CAT shows")
            Picker("Boot:", selection: Binding(get: { model.bootOption },
                                               set: { model.setBootOption($0, undoManager: undoManager) })) {
                Text("None").tag(0)
                Text("*LOAD").tag(1)
                Text("*RUN").tag(2)
                Text("*EXEC").tag(3)
            }
            .fixedSize()
            .help("What Shift-Break does with !BOOT (*OPT 4)")
            Spacer()
            Text(model.freeSpace)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.volume?.isADFS == true, model.problem == nil {
                Button("$") { model.goUp(to: 0) }
                    .buttonStyle(.link)
                ForEach(Array(model.path.enumerated()), id: \.offset) { depth, step in
                    Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                    Button(step.name) { model.goUp(to: depth + 1) }
                        .buttonStyle(.link)
                }
            }
            Spacer()
            if model.waiting {
                ProgressView().controlSize(.small)
                Text("Waiting for drive \(model.drive) to stop…")
            } else if model.adfsChanged.contains(model.drive) {
                Text("The BBC’s ADFS will say “Disc changed” until you *MOUNT.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = model.volume?.isADFS ?? false
        panel.prompt = "Add"
        panel.message = "Files with .inf files beside them keep their BBC names and addresses; .bas text becomes a BASIC program."
        guard panel.runModal() == .OK else { return }
        model.add(panel.urls, undoManager: undoManager)
    }

    private func exportSelection() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Each file is copied with a .inf file holding its BBC name, addresses and lock."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try model.export(model.selectedItems, to: folder)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: The file list

/// The disc's files in an NSTableView, for Finder-style dragging: out as
/// file promises (each file written with its .inf), in as file URLs.
struct DiscFileTable: NSViewRepresentable {
    let model: DiscContentsModel
    var onInfo: (DiscVolume.Item) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onInfo: onInfo)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 22
        for (id, title, width) in [("name", "Name", 180.0), ("load", "Load", 80.0), ("exec", "Exec", 80.0),
                                   ("length", "Length", 70.0), ("access", "Access", 60.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.sortDescriptors = model.sortOrder
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menu = context.coordinator.contextMenu
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onInfo = onInfo
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: DiscContentsModel
        var onInfo: (DiscVolume.Item) -> Void
        weak var table: NSTableView?
        private var shown: [DiscVolume.Item] = []
        private var isADFS = false
        let contextMenu = NSMenu()

        init(model: DiscContentsModel, onInfo: @escaping (DiscVolume.Item) -> Void) {
            self.model = model
            self.onInfo = onInfo
            super.init()
            contextMenu.delegate = self
        }

        func update() {
            guard let table else { return }
            isADFS = model.volume?.isADFS ?? false
            if shown != model.items {
                shown = model.items
                table.reloadData()
            }
            let rows = IndexSet(shown.indices.filter { model.selection.contains(shown[$0].id) })
            if table.selectedRowIndexes != rows {
                table.selectRowIndexes(rows, byExtendingSelection: false)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, row < shown.count else { return nil }
            let item = shown[row]
            let id = column.identifier
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = item.name
                cell.imageView?.image = NSWorkspace.shared.icon(for: item.isDirectory ? .folder : .data)
            case "load": cell.textField?.stringValue = item.isDirectory ? "" : hex(item.loadAddress)
            case "exec": cell.textField?.stringValue = item.isDirectory ? "" : hex(item.executionAddress)
            case "length": cell.textField?.stringValue = item.isDirectory ? "" : String(format: "%06X", item.length)
            default: cell.textField?.stringValue = item.access
            }
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            if id.rawValue != "name" && id.rawValue != "access" {
                text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            }
            cell.addSubview(text)
            cell.textField = text
            var constraints = [text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                               text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
            if id.rawValue == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                constraints += [image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                image.widthAnchor.constraint(equalToConstant: 16),
                                image.heightAnchor.constraint(equalToConstant: 16),
                                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5)]
            } else {
                constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
            }
            NSLayoutConstraint.activate(constraints)
            return cell
        }

        /// As *INFO shows them: DFS's six digits (FF for the I/O
        /// processor), ADFS's eight.
        private func hex(_ address: UInt32) -> String {
            if isADFS {
                return String(format: "%08X", address)
            }
            return address >= 0xFFFF_0000 ? String(format: "FF%04X", address & 0xFFFF) : String(format: "%06X", address)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0].id : nil })
            if model.selection != ids {
                model.selection = ids
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            model.sortOrder = tableView.sortDescriptors
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < shown.count else { return }
            openOrInfo(shown[row])
        }

        func openOrInfo(_ item: DiscVolume.Item) {
            if item.isDirectory {
                model.open(item)
            } else {
                onInfo(item)
            }
        }

        func deleteSelection() {
            model.delete(model.selectedItems, undoManager: table?.undoManager)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes([clicked], byExtendingSelection: false)
            }
            let items = model.selectedItems
            guard !items.isEmpty else { return }
            if items.count == 1 {
                let item = items[0]
                menu.addItem(withTitle: item.isDirectory ? "Open" : "Get Info", action: #selector(openSelected),
                             keyEquivalent: "").target = self
                if item.isDirectory {
                    menu.addItem(withTitle: "Get Info", action: #selector(infoForSelected), keyEquivalent: "").target = self
                }
            }
            menu.addItem(withTitle: "Export…", action: #selector(exportSelected), keyEquivalent: "").target = self
            if items.count == 1, model.isBASIC(items[0]) {
                menu.addItem(withTitle: "Export as Text…", action: #selector(exportSelectedAsText),
                             keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "").target = self
        }

        @objc private func openSelected() {
            if let item = model.selectedItems.first {
                openOrInfo(item)
            }
        }

        @objc private func infoForSelected() {
            if let item = model.selectedItems.first {
                onInfo(item)
            }
        }

        @objc private func exportSelected() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            do {
                try model.export(model.selectedItems, to: folder)
            } catch {
                NSAlert(error: error).runModal()
            }
        }

        @objc private func exportSelectedAsText() {
            if let item = model.selectedItems.first {
                model.exportAsText(item)
            }
        }

        @objc private func deleteSelected() {
            deleteSelection()
        }

        // MARK: Dragging out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < shown.count, let volume = model.volume else { return nil }
            let item = shown[row]
            let type = item.isDirectory ? UTType.folder : UTType.data
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: FilePromises.shared)
            provider.userInfo = FilePromises.Promise(item: item, volume: volume, location: model.location)
            return provider
        }

        // MARK: Dropping in

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard (info.draggingSource as? NSTableView) !== tableView, model.volume != nil else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            model.add(urls, undoManager: tableView.undoManager)
            return true
        }
    }
}

/// Return opens a directory or a file's info, Delete deletes, Command-I
/// shows info.
final class FileTableView: NSTableView {
    weak var coordinator: DiscFileTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        let selected = coordinator?.model.selectedItems ?? []
        switch event.keyCode {
        case 51, 117:
            coordinator?.deleteSelection()
        case 36, 76:
            if selected.count == 1 {
                coordinator?.openOrInfo(selected[0])
            }
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "i", selected.count == 1 {
                coordinator?.onInfo(selected[0])
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// Writes dragged-out files where Finder asks, each with its .inf.
final class FilePromises: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = FilePromises()

    struct Promise {
        var item: DiscVolume.Item
        var volume: DiscVolume
        var location: DiscVolume.Location
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let promise = provider.userInfo as? Promise else { return "File" }
        return InfFile.macName(promise.item.name)
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let promise = provider.userInfo as? Promise else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        do {
            try DiscContentsModel.write(promise.item, from: promise.volume, at: promise.location, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

// MARK: Sheets

/// A file's (or directory's) name, addresses and lock.
struct FileInfoSheet: View {
    let item: DiscVolume.Item
    let adfs: Bool
    let maxNameLength: Int
    var onSave: (String, UInt32, UInt32, Bool) -> Void
    @State private var name = ""
    @State private var load = ""
    @State private var exec = ""
    @State private var locked = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name:", text: $name)
            if !item.isDirectory {
                TextField("Load address:", text: $load)
                    .font(.body.monospaced())
                TextField("Execution address:", text: $exec)
                    .font(.body.monospaced())
                LabeledContent("Length:") {
                    Text("\(item.length) bytes (&\(String(item.length, radix: 16, uppercase: true)))")
                }
            }
            Toggle("Locked", isOn: $locked)
            if !nameIsValid {
                Text(adfs ? "Up to 10 characters, without spaces or . : * # $ & @ ^ % \\ | \""
                          : "Up to 7 characters (after a directory and a dot, as in W.DATA), without spaces or . : # * \"")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !item.isDirectory && (Self.address(load) == nil || Self.address(exec) == nil) {
                Text("Addresses are in hex, up to 8 digits (6 starting FF mean the I/O processor).")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .navigationTitle("Info for “\(item.name)”")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(name, Self.address(load) ?? item.loadAddress, Self.address(exec) ?? item.executionAddress,
                           locked)
                    dismiss()
                }
                .disabled(!nameIsValid || (!item.isDirectory && (Self.address(load) == nil || Self.address(exec) == nil)))
            }
        }
        .onAppear {
            name = item.name
            load = format(item.loadAddress)
            exec = format(item.executionAddress)
            locked = item.locked
        }
    }

    private var nameIsValid: Bool {
        if adfs {
            return ADFSDisc.isValidName(name)
        }
        let (directory, leaf) = DiscVolume.dfsNameParts(name)
        return DFSDisc.isValidName(leaf) && DFSDisc.isValidDirectory(directory)
    }

    private func format(_ address: UInt32) -> String {
        !adfs && address >= 0xFFFF_0000 ? String(format: "FF%04X", address & 0xFFFF) : String(format: adfs ? "%08X" : "%06X", address)
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

/// Asks for a name.
struct NameSheet: View {
    let title: String
    let prompt: String
    let maxLength: Int
    var onDone: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name:", text: $name)
                .onChange(of: name) {
                    if name.count > maxLength {
                        name = String(name.prefix(maxLength))
                    }
                }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(prompt) {
                    onDone(name)
                    dismiss()
                }
                .disabled(!ADFSDisc.isValidName(name))
            }
        }
    }
}
