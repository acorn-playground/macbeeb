import AppKit
import BeebCore
import BeebNetwork
import SwiftUI

/// Asks for a name to save a machine configuration under. Nil if cancelled.
@MainActor
func askConfigurationName(suggesting name: String, for setup: MachineSetup) -> String? {
    let alert = NSAlert()
    alert.messageText = "Save Machine Configuration"
    alert.informativeText = [setup.model.displayName, setup.fittedSummary].filter { !$0.isEmpty }.joined(separator: " · ")
        + "\n\nIt's listed in Machine > Machine Configurations, and in the Network Studio's palette."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = name
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return entered.isEmpty ? nil : entered
}

/// Saves `setup` under a name the user gives.
@MainActor
func saveConfiguration(_ setup: MachineSetup) {
    let configurations = MachineConfigurations.shared
    let suggestion = configurations.matching(setup)?.name ?? configurations.freeName(setup.model.displayName)
    guard let name = askConfigurationName(suggesting: suggestion, for: setup) else { return }
    do {
        try configurations.save(setup, as: name)
    } catch {
        NSAlert(error: error).runModal()
    }
}

/// Machine > Machine Configurations: the saved ones, to set this machine
/// up as; saving this one; managing them.
struct MachineConfigurationsMenu: View {
    let machine: MachineController?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Machine Configurations") {
            let configurations = MachineConfigurations.shared.machines
            ForEach(configurations) { saved in
                Toggle(isOn: Binding(get: { machine?.setup == saved.setup }, set: { _ in machine?.use(saved.setup) })) {
                    Text(saved.name)
                }
                .help([saved.setup.model.displayName, saved.setup.fittedSummary].filter { !$0.isEmpty }.joined(separator: " · "))
            }
            if !configurations.isEmpty { Divider() }
            Button("Save Configuration…") {
                if let machine { saveConfiguration(machine.setup) }
            }
            .disabled(machine == nil)
            Button("New Configuration…") {
                if let id = try? MachineConfigurations.shared.save(MachineSetup(), as: MachineConfigurations.shared.freeName("New Machine")).id {
                    openWindow(id: HardwareExpansionsWindow.refWindowID, value: HardwareRef.configuration(id))
                }
            }
            Button("Manage Configurations…") { openWindow(id: MachineConfigurationsWindow.windowID) }
        }
    }
}

/// The saved machine configurations: renaming and removing them.
struct MachineConfigurationsWindow: View {
    static let windowID = "machine-configurations"
    @State private var selection: Set<UUID> = []
    @State private var removing: [SavedMachine] = []
    @Environment(\.openWindow) private var openWindow

    private var configurations: MachineConfigurations { MachineConfigurations.shared }

    private func edit(_ id: UUID) {
        openWindow(id: HardwareExpansionsWindow.refWindowID, value: HardwareRef.configuration(id))
    }

    /// A new one, a stock Model B to start with, set up in its Hardware
    /// window.
    private func newConfiguration() {
        guard let saved = try? configurations.save(MachineSetup(), as: configurations.freeName("New Machine")) else { return }
        selection = [saved.id]
        edit(saved.id)
    }

    var body: some View {
        Group {
            if configurations.machines.isEmpty {
                ContentUnavailableView {
                    Label("No Machine Configurations", systemImage: "desktopcomputer")
                } description: {
                    Text("Set a machine up in its Hardware window, then choose Machine > Machine Configurations > Save Configuration, or make one here. Saved machines can set up a window, or be added to a network.")
                } actions: {
                    Button("New Configuration", action: newConfiguration)
                }
            } else {
                table
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 300, idealHeight: 420)
        .navigationTitle("Machine Configurations")
        .toolbar {
            ToolbarItemGroup {
                Button("New Configuration", systemImage: "plus", action: newConfiguration)
                    .help("Make a new machine configuration and set up its hardware")
                Button("Edit Hardware", systemImage: "slider.horizontal.3") {
                    if let id = selection.first { edit(id) }
                }
                .disabled(selection.count != 1)
                .help("Set up the selected configuration's model, ROMs, cartridges and boards")
                Button("Remove", systemImage: "minus") {
                    removing = configurations.machines.filter { selection.contains($0.id) }
                }
                .disabled(selection.isEmpty)
                .help("Remove the selected configurations")
            }
        }
        .confirmationDialog(removing.count == 1 ? "Remove \(removing[0].name)?" : "Remove \(removing.count) configurations?",
                            isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } })) {
            Button("Remove", role: .destructive) {
                for saved in removing { try? configurations.remove(saved.id) }
                selection = []
                removing = []
            }
        } message: {
            Text("Machines set up from it, in windows or networks, stay as they are.")
        }
    }

    private var table: some View {
        Table(configurations.machines, selection: $selection) {
            TableColumn("Name") { saved in
                TextField("Name", text: Binding(get: { saved.name }, set: { name in
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty { try? configurations.rename(saved.id, to: name) }
                }))
                .textFieldStyle(.plain)
            }
            .width(min: 140, ideal: 190)
            TableColumn("Model") { saved in
                Text(saved.setup.model.displayName)
            }
            .width(min: 110, ideal: 130)
            TableColumn("Fitted") { saved in
                HStack(spacing: 4) {
                    if !missingROMs(saved).isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Not in the ROM library: \(missingROMs(saved).joined(separator: ", "))")
                    }
                    Text(saved.setup.fittedSummary.isEmpty ? "As standard" : saved.setup.fittedSummary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(saved.setup.fittedSummary)
                }
            }
            .width(min: 200, ideal: 360)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Edit Hardware…") { ids.first.map(edit) }
                .disabled(ids.count != 1)
            Button("Remove…", role: .destructive) {
                removing = configurations.machines.filter { ids.contains($0.id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { edit(id) }
        }
    }

    private func missingROMs(_ saved: SavedMachine) -> [String] {
        saved.setup.pluggedROMs.filter { ROMLibrary.shared[$0.id] == nil }.map(\.name)
    }
}
