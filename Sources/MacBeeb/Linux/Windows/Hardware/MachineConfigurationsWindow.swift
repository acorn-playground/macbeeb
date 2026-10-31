import BeebCore
import BeebNetwork
import CGtk
import Foundation

/// Asks for a name to save a machine configuration under; `completion`
/// gets it (not called if cancelled).
@MainActor
func askConfigurationName(suggesting name: String, for setup: MachineSetup, over parent: Widget? = nil,
                          _ completion: @escaping @MainActor (String) -> Void) {
    let entry = Entry(text: name)
    gtk_entry_set_activates_default(cast(entry.widget), 1)
    entry.accessibleLabel("Name")
    let summary = [setup.model.displayName, setup.fittedSummary].filter { !$0.isEmpty }.joined(separator: " · ")
    let dialog = AlertDialog("Save Machine Configuration",
                             body: summary + "\n\nIt's listed in Machine > Machine Configurations, and in the Network Studio's palette.")
        .response("cancel", "_Cancel")
        .response("save", "_Save", .suggested)
        .defaults(default: "save", close: "cancel")
        .extra(entry)
    dialog.focus(entry)
    entry.onChanged { text in
        adw_alert_dialog_set_response_enabled(cast(dialog.widget), "save",
                                              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
    }
    dialog.choose(over: parent ?? Application.shared.activeWindow.map(Widget.init)) { response in
        let entered = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == "save", !entered.isEmpty else { return }
        completion(entered)
    }
    MainLoop.after(0) { entry.selectAll() }
}

/// Saves `setup` under a name the user gives.
@MainActor
func saveConfiguration(_ setup: MachineSetup, over parent: Widget? = nil) {
    let configurations = MachineConfigurations.shared
    let suggestion = configurations.matching(setup)?.name ?? configurations.freeName(setup.model.displayName)
    askConfigurationName(suggesting: suggestion, for: setup, over: parent) { name in
        do {
            try configurations.save(setup, as: name)
        } catch {
            Platform.showError(error)
        }
    }
}

/// The saved machine configurations: renaming and removing them, and
/// setting them up.
@MainActor
enum MachineConfigurationsWindow {
    static func show() {
        Windows.show("configurations") { MachineConfigurationsController().window }
        HardwareSelfTest.windowShown(key: "configurations")
    }

    /// A new one, a stock Model B to start with, set up in its Hardware
    /// window.
    @discardableResult
    static func newConfiguration() -> UUID? {
        let configurations = MachineConfigurations.shared
        do {
            let saved = try configurations.save(MachineSetup(), as: configurations.freeName("New Machine"))
            HardwareExpansionsWindow.show(ref: .configuration(saved.id))
            return saved.id
        } catch {
            Platform.showError(error)
            return nil
        }
    }

    /// Saves `setup` under a name the user gives (the Network Studio's
    /// Save as Configuration): `saveConfiguration(_:over:)`.
    static func save(_ setup: MachineSetup, over parent: Widget? = nil) {
        saveConfiguration(setup, over: parent)
    }
}

@MainActor
final class MachineConfigurationsController {
    let window = Window(title: "Machine Configurations", width: 820, height: 480)
    private let table = ItemTable()
    private let stack = Stack()
    private let editButton = Button(icon: "document-edit-symbolic")
    private let removeButton = Button(icon: "list-remove-symbolic")
    private var editAction: Action!
    private var removeAction: Action!
    private var renameAction: Action!
    private var machines: [SavedMachine] = []

    private var configurations: MachineConfigurations { MachineConfigurations.shared }

    init() {
        HardwareStyles.install()
        window.minimumSize(width: 560, height: 300)

        let new = Button(icon: "list-add-symbolic") { [weak self] in self?.newConfiguration() }
            .tooltip("Make a new machine configuration and set up its hardware")
            .accessibleLabel("New Configuration")
        editButton.onClicked { [weak self] in self?.editSelected() }
        editButton.tooltip("Set up the selected configuration's model, ROMs, cartridges and boards").accessibleLabel("Edit Hardware")
        removeButton.onClicked { [weak self] in self?.confirmRemove() }
        removeButton.tooltip("Remove the selected configurations").accessibleLabel("Remove")
        let header = HeaderBar()
        header.start(new).start(editButton).start(removeButton)

        let empty = StatusPage(icon: "computer-symbolic", title: "No Machine Configurations",
                               description: Markup.escape("Set a machine up in its Hardware window, then choose Machine > Machine Configurations > Save Configuration, or make one here. Saved machines can set up a window, or be added to a network."),
                               child: Button("New Configuration") { [weak self] in self?.newConfiguration() }
                                .style("suggested-action", "pill")
                                .align(horizontal: GTK_ALIGN_CENTER))
        empty.compact()
        buildTable()
        stack.add(empty, name: "empty")
        stack.add(ScrolledWindow(table).expand(), name: "table")
        window.content = ToolbarView(content: stack).top(header)
        App.addStandardShortcuts(to: window)
        window.action("close") { [weak window] in window?.close() }
        window.action("new") { [weak self] in self?.newConfiguration() }
        window.shortcut("<Control>n", action: "win.new")
        editAction = window.action("edit-hardware") { [weak self] in self?.editSelected() }
        removeAction = window.action("remove") { [weak self] in self?.confirmRemove() }
        renameAction = window.action("rename") { [weak self] in self?.rename() }

        window.track { [weak self] in self?.reload() }
        window.keep(self)
    }

    private var selected: [SavedMachine] {
        table.selectedRows.sorted().compactMap { machines.indices.contains($0) ? machines[$0] : nil }
    }

    private func machine(_ row: Int) -> SavedMachine? {
        machines.indices.contains(row) ? machines[row] : nil
    }

    // MARK: The table

    private func buildTable() {
        table.column("Name", width: 200) { [weak self] in
            NameCell(name: { row in self?.machine(row)?.name ?? "" }) { row, name in
                guard let self, let saved = self.machine(row) else { return }
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.reload()
                } else {
                    try? self.configurations.rename(saved.id, to: name)
                }
            }
        }
        table.column("Model", width: 150) { [weak self] in
            TextCell { row in (self?.machine(row)?.setup.model.displayName ?? "", false, nil) }
        }
        table.column("Fitted", expand: true) { [unowned self] in FittedCell(controller: self) }
        table.onSelectionChanged { [weak self] in self?.selectionChanged() }
        table.onActivate { [weak self] row in
            if let id = self?.machine(row)?.id { self?.edit(id) }
        }
        table.onKey { [weak self] keyval in
            guard let self else { return false }
            switch Int32(keyval) {
            case GDK_KEY_Delete, GDK_KEY_KP_Delete, GDK_KEY_BackSpace:
                self.confirmRemove()
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
                MenuItem("Edit Hardware…", "win.edit-hardware")
                MenuItem("Rename…", "win.rename")
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

    /// The ROMs a configuration has in its sockets that aren't in the
    /// library.
    fileprivate func missingROMs(_ row: Int) -> [String] {
        guard let saved = machine(row) else { return [] }
        return saved.setup.pluggedROMs.filter { ROMLibrary.shared[$0.id] == nil }.map(\.name)
    }

    fileprivate func fitted(_ row: Int) -> String {
        machine(row)?.setup.fittedSummary ?? ""
    }

    private func reload() {
        let ids = Set(selected.map(\.id))
        machines = configurations.machines
        // (The library too: a configuration's ROMs may have gone.)
        _ = ROMLibrary.shared.roms
        stack.visible = machines.isEmpty ? "empty" : "table"
        table.reload(count: machines.count)
        table.select(Set(machines.indices.filter { ids.contains(machines[$0].id) }))
        selectionChanged()
    }

    private func selectionChanged() {
        let count = table.selectedRows.count
        editButton.isEnabled = count == 1
        editAction.isEnabled = count == 1
        renameAction.isEnabled = count == 1
        removeButton.isEnabled = count > 0
        removeAction.isEnabled = count > 0
    }

    // MARK: Commands

    private func edit(_ id: UUID) {
        HardwareExpansionsWindow.show(ref: .configuration(id))
    }

    private func editSelected() {
        let chosen = selected
        guard chosen.count == 1 else { return }
        edit(chosen[0].id)
    }

    private func newConfiguration() {
        guard let id = MachineConfigurationsWindow.newConfiguration() else { return }
        reload()
        table.select(Set(machines.indices.filter { machines[$0].id == id }))
        selectionChanged()
    }

    private func confirmRemove() {
        let removing = selected
        guard !removing.isEmpty else { return }
        HardwareAlerts.confirm(removing.count == 1 ? "Remove \(removing[0].name)?" : "Remove \(removing.count) configurations?",
                               "Machines set up from it, in windows or networks, stay as they are.",
                               action: "_Remove", over: window) { [weak self] in
            guard let self else { return }
            for saved in removing { try? self.configurations.remove(saved.id) }
            self.table.select([])
        }
    }

    private func rename() {
        let rows = table.selectedRows
        guard rows.count == 1, let row = rows.first else { return }
        table.cell(NameCell.self, row: row)?.startEditing()
    }
}

/// What a configuration has fitted, with a warning when ROMs it uses
/// aren't in the library.
@MainActor
private final class FittedCell: TableCell {
    private weak var controller: MachineConfigurationsController?
    private let warning = Icon("dialog-warning-symbolic").style("warning")
    private let label = Label("", style: "dim-label")

    init(controller: MachineConfigurationsController) {
        self.controller = controller
        let warning = warning, label = label
        label.ellipsize()
        let box = Box(.horizontal, spacing: 6) {
            warning
            label
        }
        super.init(box)
        box.expand(horizontal: true)
    }

    override func bind() {
        guard let controller else { return }
        let missing = controller.missingROMs(row)
        warning.isVisible = !missing.isEmpty
        warning.tooltip(missing.isEmpty ? nil : "Not in the ROM library: \(missing.joined(separator: ", "))")
        warning.accessibleLabel(missing.isEmpty ? "" : "Not in the ROM library: \(missing.joined(separator: ", "))")
        let fitted = controller.fitted(row)
        label.text = fitted.isEmpty ? "As standard" : fitted
        label.tooltip(fitted.isEmpty ? nil : fitted)
    }
}
