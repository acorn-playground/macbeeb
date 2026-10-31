import BeebCore
import BeebNetwork
import CGtk
import Foundation

/// The studio's sidebar: the network as a whole, or the machine (or clock)
/// selected, or what to do with several. (The Mac's NetworkInspector.)
@MainActor
final class NetworkInspectorPanel {
    let session: NetworkSession
    let root: Widget
    private let bin = Bin()
    private var key = ""
    private let openStation: (UUID) -> Void
    private let openDebugger: (UUID) -> Void
    private let openHardware: (UUID) -> Void

    init(session: NetworkSession, openStation: @escaping (UUID) -> Void, openDebugger: @escaping (UUID) -> Void,
         openHardware: @escaping (UUID) -> Void) {
        self.session = session
        self.openStation = openStation
        self.openDebugger = openDebugger
        self.openHardware = openHardware
        root = bin
        bin.accessibleLabel("Inspector")
        bin.track { [self] in
            // Rebuilt only when what it's about changes; the rows follow
            // the rest themselves.
            let selection = session.selection
            var key = "network"
            if selection.count == 1, let node = session.node(selection.first!) {
                key = "node \(node.id) \(node.kind) \(node.level)"
            } else if selection.count > 1 {
                key = "several \(selection.count)"
            }
            guard key != self.key else { return }
            self.key = key
            self.rebuild()
        }
    }

    private func rebuild() {
        let page = PreferencesPage()
        let selection = session.selection
        if selection.count == 1, let node = session.node(selection.first!) {
            if node.isMachine {
                MachineInspector(session: session, id: node.id, openStation: openStation, openDebugger: openDebugger,
                                 openHardware: openHardware).build(into: page)
            } else {
                clockInspector(node.id, into: page)
            }
        } else if selection.count > 1 {
            selectionSummary(into: page)
        } else {
            networkSummary(into: page)
        }
        bin.child = page
    }

    // MARK: The network

    private func networkSummary(into page: PreferencesPage) {
        let session = session
        let name = EntryRow("Name", text: session.project.name) { name in
            session.update { $0.name = name }
        }
        adw_entry_row_set_show_apply_button(cast(name.widget), 1)
        name.object.on("apply") { session.renameFileToMatch() }
        name.tooltip("The network's name; its file is renamed to match when you press Return")
        networkFollow(name) { session.project.name }
        let machines = ActionRow("Machines").property()
        let clock = ActionRow("Clock").property()
        let speed = ActionRow("Speed").property()
        let throttle = NetworkThrottle(1, owner: speed)
        machines.track { [machines, clock, speed] in
            machines.subtitle = "\(session.project.stations.count), \(session.controllers.count) on"
            clock.subtitle = session.project.hasClock ? "Fitted" : "None"
            let status = session.status
            speed.isVisible = status.speed > 0 && !session.controllers.isEmpty
            // (Once a second, saying what it is then: it changes all the
            // time.)
            throttle.run {
                let status = session.status
                speed.subtitle = String(format: "%.0f%% of real time", status.speed * 100)
                    + (status.threads > 1 ? ", on \(status.threads) cores" : "")
            }
        }
        page.add(PreferencesGroup(title: "Network") {
            name
            machines
            clock
            speed
        })

        let problems = PreferencesGroup(title: "Problems")
        var rows: [Widget] = []
        problems.track { [problems] in
            rows.forEach(problems.remove)
            let list = session.project.problems
            rows = list.isEmpty
                ? [ActionRow("None").prefix(Icon("object-select-symbolic").style("dim-label"))]
                : list.map { ActionRow($0.message).prefix(Icon("dialog-warning-symbolic").style("warning")) }
            for row in rows {
                adw_action_row_set_title_lines(cast(row.widget), 0)
                problems.add(row)
            }
        }
        page.add(problems)

        let network = session.runtime.network
        page.add(PreferencesGroup(title: "Debugging") {
            SwitchRow("Pause the network at a breakpoint",
                      subtitle: "When one machine stops in its debugger, the others stop too, so none of them times out waiting for it.",
                      isOn: network.pausesOnBreakpoint) { network.setPauseOnBreakpoint($0) }
        })

        let snap = SwitchRow("Snap to grid", isOn: session.project.canvas.snapToGrid) { on in
            session.update { $0.canvas.snapToGrid = on }
        }
        page.add(PreferencesGroup(title: "Canvas") { snap })

        let location = ActionRow("Location").property().subtitleSelectable()
        location.track { [location] in location.subtitle = session.url.path }
        let reveal = Button("Show in Files") { Platform.reveal(session.url) }
            .tooltip("Show the network's package in the file manager")
        page.add(PreferencesGroup(title: "File") {
            location
            NetworkButtonStrip { reveal }
        })
    }

    private func selectionSummary(into page: PreferencesPage) {
        let session = session
        let machines = { session.selection.compactMap { session.node($0) }.filter(\.isMachine) }
        page.add(PreferencesGroup(title: "\(session.selection.count) Selected") {
            ButtonRow("Power On", icon: "system-shutdown-symbolic") { machines().forEach { session.powerOn($0.id) } }
            ButtonRow("Power Off", icon: "media-playback-stop-symbolic") { machines().forEach { session.powerOff($0.id) } }
            ButtonRow("Break", icon: "object-rotate-left-symbolic") { machines().forEach { session.pressBreak($0.id) } }
        })
    }

    // MARK: The clock

    static let rates = [50_000, 100_000, 125_000, 200_000, 250_000]

    private func clockInspector(_ id: UUID, into page: PreferencesPage) {
        let session = session
        let rates = Self.rates
        let current = session.node(id)?.clockRate ?? NetworkNode.defaultClockRate
        let rate = ComboRow("Rate", items: rates.map(ClockCard.rateText), selected: rates.firstIndex(of: current) ?? 3) { index in
            session.update { $0[id]?.clockRate = rates[index] }
        }
        rate.track { [rate] in
            let value = session.node(id)?.clockRate ?? NetworkNode.defaultClockRate
            if let index = rates.firstIndex(of: value) { rate.selected = index }
        }
        page.add(PreferencesGroup(title: "Network Clock",
                                  description: "An Econet carries nothing without a clock: the clock box sets the speed every station sends and receives at.") {
            rate
        })
    }
}

/// A machine's part of the inspector.
@MainActor
final class MachineInspector {
    let session: NetworkSession
    let id: UUID
    private let openStation: (UUID) -> Void
    private let openDebugger: (UUID) -> Void
    private let openHardware: (UUID) -> Void
    private var actions: NetworkActionGroup?
    /// A new number for a machine that's on, waiting for the go-ahead to
    /// restart it.
    private var pendingNumber: Int?
    private let numberProblem = Label("", style: "caption", "error")

    init(session: NetworkSession, id: UUID, openStation: @escaping (UUID) -> Void, openDebugger: @escaping (UUID) -> Void,
         openHardware: @escaping (UUID) -> Void) {
        self.session = session
        self.id = id
        self.openStation = openStation
        self.openDebugger = openDebugger
        self.openHardware = openHardware
    }

    private var node: NetworkNode? { session.node(id) }

    func build(into page: PreferencesPage) {
        guard let node else { return }
        let session = session, id = id
        actions = NetworkActionGroup("inspector", on: page)
        page.keep(self)
        installActions()

        // Who it is.
        let name = EntryRow("Name", text: node.name)
        adw_entry_row_set_show_apply_button(cast(name.widget), 1)
        name.object.on("apply") { [name] in session.rename(id, to: name.text) }
        networkFollow(name) { session.node(id)?.name ?? "" }
        let number = EntryRow("Station", text: node.stationNumber.map(String.init) ?? "")
        adw_entry_row_set_show_apply_button(cast(number.widget), 1)
        adw_entry_row_set_input_purpose(cast(number.widget), GTK_INPUT_PURPOSE_DIGITS)
        number.tooltip("1 to 254; each machine on a network needs its own. A machine that's on restarts to take it.")
        number.object.on("apply") { [self, number] in self.applyNumber(number) }
        networkFollow(number) { session.node(id)?.stationNumber.map(String.init) ?? "" }
        numberProblem.wrap().visible(false).margin(top: 8)
        let kinds: [NetworkNode.Kind] = [.station, .fileServer, .printServer]
        let role = ComboRow("Role", items: kinds.map(\.displayName), selected: kinds.firstIndex(of: node.kind) ?? 0) { index in
            session.update { $0[id]?.kind = kinds[index] }
        }
        page.add(PreferencesGroup(title: node.kind.displayName) {
            name
            number
            role
            numberProblem
        })

        if node.kind == .fileServer { fileServer(node, into: page) }
        if node.kind == .printServer { printerServer(into: page) }
        machine(node, into: page)
        power(into: page)
        discs(into: page)

        let open = Button("Open Window") { [self] in
            if !session.isOn(id) { session.powerOn(id) }
            self.openStation(id)
        }
        let debugger = Button("Debugger") { [self] in self.openDebugger(id) }
        debugger.track { [debugger] in debugger.isEnabled = session.isOn(id) }
        page.add(PreferencesGroup { NetworkButtonStrip { open; debugger }.margin(top: 0) })
    }

    private func installActions() {
        guard let actions else { return }
        let session = session, id = id
        actions.add("insert-disc") { drive in session.chooseDisc(for: id, drive: Int(drive) ?? 0) }
        actions.add("eject") { drive in session.eject(id, drive: Int(drive) ?? 0) }
        // The saved configuration it's set up as, if it is one: a radio
        // item in the Configuration menu.
        let configuration = Action(choice: "use-configuration", value: "") { [self] value in
            guard let configuration = UUID(uuidString: value).flatMap({ MachineConfigurations.shared[$0] }) else { return }
            self.use(configuration.setup)
        }
        g_action_map_add_action(actions.group, configuration.gAction)
        numberProblem.track {
            let setup = session.node(id)?.setup
            configuration.value = MachineConfigurations.shared.machines.first { $0.setup == setup }?.id.uuidString ?? ""
        }
        actions.add(plain: "save-configuration") { [self] in
            if let setup = self.node?.setup { saveNetworkConfiguration(setup, over: Application.shared.activeWindow.map(Widget.init)) }
        }
    }

    // MARK: The station number

    private func applyNumber(_ field: EntryRow) {
        guard let node else { return }
        guard let value = Int(field.text.trimmingCharacters(in: .whitespaces)) else {
            showNumberProblem("A station number is a number from 1 to 254")
            return
        }
        guard value != node.stationNumber, pendingNumber == nil else { return }
        if let problem = session.project.stationNumberProblem(value, for: id) {
            showNumberProblem(problem)
            field.text = node.stationNumber.map(String.init) ?? ""
        } else if session.controllers[id] != nil {
            // On: it has to restart, so ask.
            showNumberProblem(nil)
            pendingNumber = value
            let session = session, id = id
            AlertDialog("Change \(node.name) to station \(value)?",
                        body: "Its network interface takes its number when it starts, so it starts again: what's in its memory is lost. Its discs stay in their drives.")
                .response("cancel", "_Cancel")
                .response("change", "Change and _Restart", .suggested)
                .defaults(default: "change", close: "cancel")
                .choose(over: field) { [self] response in
                    self.pendingNumber = nil
                    if response == "change" {
                        self.showNumberProblem(session.renumber(id, to: value))
                    } else {
                        field.text = session.node(id)?.stationNumber.map(String.init) ?? ""
                    }
                }
        } else {
            showNumberProblem(session.setStationNumber(id, to: value))
        }
    }

    private func showNumberProblem(_ problem: String?) {
        numberProblem.text = problem ?? ""
        numberProblem.isVisible = problem != nil
    }

    // MARK: Servers

    private func fileServer(_ node: NetworkNode, into page: PreferencesPage) {
        let session = session, id = id
        let levels = FileServerLevel.allCases.filter { $0.isChoosable || $0 == node.level }
        let server = ComboRow("Server", items: levels.map(\.displayName), selected: levels.firstIndex(of: node.level) ?? 0) { index in
            session.setFileServerLevel(id, levels[index])
        }
        server.tooltip("Level 1 runs on a Model B from a DFS disc. Level 2 needs a 6502 Second Processor, and has users, passwords, directories and boot options. Changing it restarts the server with a fresh disc of its own.")
        let console = consoleRow()
        let group = PreferencesGroup(title: "File Server") {
            server
            console
        }
        let start = Button("Start File Server") { session.startFileServer(id) }
        let buttons = WrapBox(spacing: 8, lineSpacing: 8).margin(top: 12)
        buttons.append(start)
        if node.level != .level3 {
            let add = Button("Add Files…") { session.chooseFilesForServer(id) }
                .tooltip(node.level == .level2
                         ? "Put files in the server's $.LIBRARY, with the server switched off (or drag them onto its card)"
                         : "Put files on the server, in directory A (or drag them onto its card)")
            let show = Button("Show Files") {
                if let controller = session.controllers[id] { DiscContentsWindow.show(for: controller) }
            }
            .tooltip("The server's disc: its files, to add, rename, delete or drag out")
            show.track { [show] in show.isEnabled = session.isOn(id) }
            buttons.append(add)
            buttons.append(show)
        }
        switch node.level {
        case .level3:
            start.tooltip("Runs Acorn's Level 3 file server in the Second Processor, from the hard disc")
        case .level2:
            start.tooltip("Runs Acorn's Level 2 file server in the Second Processor, from the utilities disc in drive 1, serving the disc in drive 0")
        case .level1:
            start.tooltip("Runs Acorn's Level 1 file server from its disc, giving every other machine the shared directory A")
        }
        group.add(buttons)
        let text = switch node.level {
        case .level3:
            "Acorn's Level 3 file server runs in this Master's 6502 Second Processor, from its SCSI hard disc. This one has Mark Moxon's Elite over Econet for the user ELITE: on another machine, type *NET, *I AM 0.254 ELITE, then *ELITE to play, or *ELITE S for the scoreboard."
        case .level2:
            "Acorn's Level 2 file server runs in this BBC's 6502 Second Processor, serving the disc in drive 0. Its users are SYST (who can make others with *NEWUSER), BOOT and GUEST, none with a password. On the other machines, type *NET, then *I AM GUEST (or another user): each has their own directory, and $.LIBRARY is everyone's library. Shift-Break logs on as BOOT and runs its !BOOT (hold N too on a Model B). Files dropped on its card go in $.LIBRARY, with the server off."
        case .level1:
            "Acorn's Level 1 file server runs on this BBC, from its disc. Every other machine on the network shares directory A: on them, type *NET, then SAVE, LOAD, CHAIN and *CAT use the server. Drop files on its card to put them there (BASIC as .bas text, or files with .inf addresses). Open its window to see the server's console."
        }
        group.add(NetworkCaption(text).margin(top: 12))
        page.add(group)
    }

    private func printerServer(into page: PreferencesPage) {
        let session = session, id = id
        let console = consoleRow()
        let jobs = ActionRow("Jobs").property()
        jobs.track { [jobs] in
            let station = session.node(id)?.stationNumber ?? 0
            jobs.subtitle = "\(PrintCentre.shared.jobs.filter { $0.printer.hasSuffix("station \(station)") }.count)"
        }
        let group = PreferencesGroup(title: "Printer Server") {
            console
            jobs
        }
        let buttons = WrapBox(spacing: 8, lineSpacing: 8).margin(top: 12)
        buttons.append(Button("Start Printer Server") { session.startPrinterServer(id) })
        buttons.append(Button("Print Centre") { PrintCentreWindow.show() }
            .tooltip("What the printer server has printed, on paper"))
        group.add(buttons)
        group.add(NetworkCaption("MacBeeb's printer server runs on this BBC and prints to its printer port; what it prints appears in the Print Centre. On the other machines, *FX5,4 chooses the network printer, then VDU 2 starts printing and VDU 3 stops.").margin(top: 12))
        page.add(group)
    }

    /// The server's console: its last line, while it's on.
    private func consoleRow() -> ActionRow {
        let session = session, id = id
        let row = ActionRow("Console").property()
        gtk_widget_add_css_class(row.widget, "monospace")
        row.track { [row] in
            let line = session.controllers[id]?.consoleLine
            row.isVisible = line != nil
            row.subtitle = line ?? ""
        }
        return row
    }

    // MARK: The machine

    private func machine(_ node: NetworkNode, into page: PreferencesPage) {
        let session = session, id = id
        let models = BBCMicro.Model.allCases
        let model = ComboRow("Model", items: models.map(\.displayName),
                             selected: models.firstIndex(of: node.setup?.model ?? .modelB) ?? 0) { [self] index in
            self.setModel(models[index])
        }
        model.track { [model] in
            if let current = session.node(id)?.setup?.model, let index = models.firstIndex(of: current) { model.selected = index }
        }
        let group = PreferencesGroup(title: "Machine") { model }
        let summary = NetworkCaption("")
        summary.margin(top: 8)
        summary.track { [summary] in
            let text = session.node(id)?.setup?.fittedSummary ?? ""
            summary.text = text
            summary.isVisible = !text.isEmpty
        }
        group.add(summary)
        let hardware = Button("Hardware…") { [self] in self.openHardware(id) }
        hardware.track { [hardware] in
            hardware.tooltip(session.isOn(id) ? "ROMs, cartridges, boards, sideways RAM and VideoNuLA"
                             : "ROMs, cartridges, boards, sideways RAM and VideoNuLA, for when it's switched on")
        }
        let configurations = Menu {}
        let configuration = MenuButton(label: "Configuration", menu: configurations)
            .tooltip("Set this machine up as one of your saved machine configurations, or save it as one")
        configuration.track {
            let saved = MachineConfigurations.shared.machines
            var entries: [MenuEntry] = []
            if !saved.isEmpty {
                entries.append(MenuSection {
                    for machine in saved {
                        MenuItem(machine.name, "inspector.use-configuration", target: machine.id.uuidString)
                    }
                })
            }
            entries.append(MenuItem("Save as Configuration…", "inspector.save-configuration"))
            configurations.set(entries)
        }
        let buttons = WrapBox(spacing: 8, lineSpacing: 8).margin(top: 12)
        buttons.append(hardware)
        buttons.append(configuration)
        group.add(buttons)
        page.add(group)
    }

    private func use(_ setup: MachineSetup) {
        if let controller = session.controllers[id] {
            // A power cycle, which tells the network.
            controller.use(setup)
        } else {
            session.update { [id] in $0[id]?.setup = setup }
        }
    }

    private func setModel(_ model: BBCMicro.Model) {
        guard session.node(id)?.setup?.model != model else { return }
        if let controller = session.controllers[id] {
            // The running machine changes (a power cycle), and tells the
            // network.
            controller.setModel(model)
        } else {
            session.update { [id] in $0[id]?.setup?.model = model }
        }
    }

    // MARK: Power and discs

    private func power(into page: PreferencesPage) {
        let session = session, id = id
        let on = SwitchRow("On", isOn: session.isOn(id)) { on in on ? session.powerOn(id) : session.powerOff(id) }
        let suspended = SwitchRow("Suspended", isOn: session.isSuspended(id)) { session.setSuspended(id, $0) }
        suspended.tooltip("It stops where it is while the rest of the network runs on, so other machines waiting for it time out")
        let pressBreak = Button("Break") { session.pressBreak(id) }
        let coldBoot = Button("Cold Boot") { session.coldBoot(id) }.tooltip("Switch it off and on again")
        let buttons = NetworkButtonStrip { pressBreak; coldBoot }
        on.track { [on, suspended, buttons] in
            let isOn = session.isOn(id)
            on.isOn = isOn
            suspended.isVisible = isOn
            suspended.isOn = session.isSuspended(id)
            buttons.isVisible = isOn
        }
        page.add(PreferencesGroup(title: "Power") {
            on
            suspended
            buttons
        })
    }

    private func discs(into page: PreferencesPage) {
        let session = session, id = id
        let group = PreferencesGroup(title: "Discs",
                                     description: "The network keeps its own copies of its discs, so the machines never change your files.")
        for drive in 0..<2 {
            let row = ActionRow("Drive \(drive)").property()
            let menu = MenuButton(icon: "media-floppy-symbolic", menu: Menu {
                MenuItem("Insert Disc…", "inspector.insert-disc", target: "\(drive)")
                MenuItem("Eject", "inspector.eject", target: "\(drive)")
            })
            menu.style("flat").align(vertical: GTK_ALIGN_CENTER).tooltip("Insert or eject drive \(drive)'s disc")
                .accessibleLabel("Drive \(drive)")
            row.suffix(menu)
            row.track { [row] in
                let disc = session.node(id)?.discs[drive]?.displayName
                row.subtitle = disc ?? "Empty"
                adw_action_row_set_subtitle_lines(cast(row.widget), 1)
            }
            group.add(row)
        }
        page.add(group)
    }
}

/// A text field that shows a value as it changes elsewhere, and leaves
/// what's being typed alone otherwise.
@MainActor
func networkFollow(_ row: EntryRow, _ value: @escaping @MainActor () -> String) {
    var last = value()
    row.track { [row] in
        let now = value()
        guard now != last else { return }
        last = now
        row.text = now
    }
}

/// Saves `setup` under a name the user gives (Save as Configuration…).
@MainActor
func saveNetworkConfiguration(_ setup: MachineSetup, over parent: Widget?) {
    let configurations = MachineConfigurations.shared
    let suggestion = configurations.matching(setup)?.name ?? configurations.freeName(setup.model.displayName)
    let field = EntryRow("Name", text: suggestion)
    let form = ListBox().style("boxed-list")
    form.append(field)
    let detail = [setup.model.displayName, setup.fittedSummary].filter { !$0.isEmpty }.joined(separator: " · ")
    let dialog = AlertDialog("Save Machine Configuration",
                             body: detail + "\n\nIt's listed in Machine Configurations, and in the Network Studio's palette.")
        .response("cancel", "_Cancel")
        .response("save", "_Save", .suggested)
        .defaults(default: "save", close: "cancel")
        .extra(form)
    adw_alert_dialog_set_response_enabled(cast(dialog.widget), "save", suggestion.isEmpty ? 0 : 1)
    field.object.on("changed") { [field] in
        adw_alert_dialog_set_response_enabled(cast(dialog.widget), "save",
                                              field.text.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1)
    }
    adw_entry_row_set_activates_default(cast(field.widget), 1)
    dialog.focus(field)
    dialog.choose(over: parent) { response in
        guard response == "save" else { return }
        let name = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try configurations.save(setup, as: name)
        } catch {
            Platform.showError(error)
        }
    }
}
