import BeebCore
import BeebNetwork
import CGtk
import Foundation

/// The machine's ROM sockets, as the hardware has them, and what's in
/// them: the standard ROMs, the user's from the ROM library, or nothing.
/// On the Master, its cartridge slots and the links that make banks 4-7
/// ROM sockets. (The Mac's ROMSocketsSection.)
@MainActor
final class ROMSocketsSection {
    let widget: PreferencesGroup
    private let cards = Box(.vertical, spacing: 12)
    private let rebuilding = Rebuilding<Key>()
    /// The sockets being chosen, and changing them.
    private let sockets: () -> SocketSetup
    private let setSockets: (SocketSetup) -> Void
    /// The machine as it would be with the sockets.
    private var setup = MachineSetup()
    private var econet = false
    /// Each socket's menu button, by bank (for the self-test).
    private(set) var menus: [Int: MenuButton] = [:]

    private var library: ROMLibrary { ROMLibrary.shared }

    /// What the cards show.
    private struct Key: Equatable {
        var setup: MachineSetup
        var econet: Bool
        var groups: [ROMSocketGroup]
        var problems: [Int: String]
        var roms: [UserROM]
    }

    init(sockets: @escaping () -> SocketSetup, set: @escaping (SocketSetup) -> Void) {
        self.sockets = sockets
        setSockets = set
        widget = textGroup("ROM Sockets")
        let footer = Box(.horizontal, spacing: 12) {
            Icon("dialog-information-symbolic").style("dim-label")
            Label("Add ROMs to the library to plug them in: drop .rom files on a socket, or use its menu.",
                  style: "caption", "dim-label").wrap().expand(horizontal: true)
            Button("ROM Library…") { ROMLibraryWindow.show() }
                .tooltip("The sideways ROM images you've added, to plug into machines")
                .align(vertical: GTK_ALIGN_CENTER)
        }
        footer.margin(horizontal: 6)
        widget.add(Box(.vertical, spacing: 12) {
            cards
            footer
        })
    }

    private func detail(_ model: BBCMicro.Model) -> String {
        switch model {
        case .master128: "Two cartridge slots at the front of the keyboard, and links that make banks 4–7 ROM sockets."
        case .bPlus: "Five sockets that each take a 32K chip (two banks), and BASIC and the DFS."
        default: "The ROMs plugged into the motherboard. The highest-numbered language starts at power on."
        }
    }

    /// Shows the sockets of `setup` (the machine as the draft has it): a
    /// network's station (`econet`) has its Econet ROM in one.
    func update(setup: MachineSetup, econet: Bool, source: ROMSource) {
        self.setup = setup
        self.econet = econet
        widget.setText(title: setup.model == .master128 ? "Cartridges and ROM Sockets" : "ROM Sockets", description: detail(setup.model))
        let groups = setup.socketGroups(econet: econet)
        let problems = setup.socketProblems(econet: econet, source: source)
        let key = Key(setup: setup, econet: econet, groups: groups, problems: problems, roms: library.roms)
        rebuilding.update(key, in: cards) { register in
            cards.removeAll()
            menus = [:]
            for group in groups {
                cards.append(card(group, problems: problems, register: register))
            }
        }
    }

    // MARK: Groups

    private func card(_ group: ROMSocketGroup, problems: [Int: String], register: (AnyHashable, Widget) -> Void) -> Widget {
        let list = ListBox().style("boxed-list")
        let header = ActionRow(group.name, subtitle: group.detail).style("hw-group-header")
        if let control = groupControl(group) {
            header.suffix(control)
            register("group \(group.id)", control)
        }
        list.append(header)
        for socket in group.sockets {
            list.append(socketRow(socket, in: group, problem: problems[socket.bank], register: register))
        }
        return list
    }

    private func groupControl(_ group: ROMSocketGroup) -> Widget? {
        switch group.kind {
        case .cartridge(let slot):
            let choices: [Cartridge?] = [nil] + Cartridge.allCases
            let picker = DropDown(["No Cartridge"] + Cartridge.allCases.map(\.displayName),
                                  selected: choices.firstIndex(of: setup.sockets.cartridges[slot]) ?? 0)
            picker.object.onChange("selected") { [weak self, picker] in
                guard let self, choices.indices.contains(picker.selected) else { return }
                let chosen = choices[picker.selected]
                if self.sockets().cartridges[slot] != chosen { self.setCartridge(chosen, slot: slot) }
            }
            return picker.tooltip("What's plugged into this slot").accessibleLabel("\(group.name)")
                .align(vertical: GTK_ALIGN_CENTER)
        case .link(let bank):
            let toggles = ToggleGroup(["Sideways RAM", "ROM Socket"], selected: setup.sockets.romLinks.contains(bank) ? 1 : 0) { _ in }
                .fullWidth()
            toggles.object.onChange("active") { [weak self, toggles] in
                guard let self else { return }
                let rom = toggles.selected == 1
                if self.sockets().romLinks.contains(bank) != rom { self.setLink(rom, bank: bank) }
            }
            return toggles.tooltip(bank == 4 ? "Link LK19: West for sideways RAM in banks 4 and 5, East for ROMs in IC37"
                                   : "Link LK18: West for sideways RAM in banks 6 and 7, East for ROMs in IC41")
                .accessibleLabel(bank == 4 ? "Link LK19" : "Link LK18")
                .align(vertical: GTK_ALIGN_CENTER)
        case .motherboard, .board:
            return nil
        }
    }

    // (Each makes its changes to a copy and sets it once.)

    private func setCartridge(_ cartridge: Cartridge?, slot: Int) {
        var new = sockets()
        new.cartridges[slot] = cartridge
        // Its ROMs come out with it.
        if cartridge != .roms {
            new.roms[slot * 2] = nil
            new.roms[slot * 2 + 1] = nil
        }
        setSockets(new)
    }

    private func setLink(_ rom: Bool, bank: Int) {
        var new = sockets()
        if rom {
            new.romLinks.insert(bank)
        } else {
            new.romLinks.remove(bank)
            new.roms[bank] = nil
            new.roms[bank + 1] = nil
        }
        setSockets(new)
    }

    // MARK: Sockets

    /// The two-bank ROM whose upper half is in `bank`, if there is one.
    private func pairCovering(_ bank: Int, in group: ROMSocketGroup) -> PluggedROM? {
        guard group.takesPairs, bank % 2 == 1, let rom = setup.sockets.roms[bank - 1]?.rom, rom.layout == .pair else { return nil }
        return rom
    }

    private func socketRow(_ socket: ROMSocket, in group: ROMSocketGroup, problem: String?,
                           register: (AnyHashable, Widget) -> Void) -> Widget {
        let covering = pairCovering(socket.bank, in: group)
        let content = setup.sockets.roms[socket.bank]
        let row = ActionRow("")
        let number = Label("\(socket.answersAs)", style: "hw-number").centred()
        number.style(socket.takenBy != nil || covering != nil ? "taken" : "rom")
        number.tooltip("Bank \(socket.answersAs)")
        row.prefix(number)
        if let takenBy = socket.takenBy {
            row.set(title: takenBy, subtitle: "")
            row.style("hw-quiet")
            row.suffix(Icon("changes-prevent-symbolic").style("dim-label").tooltip("Taken by \(takenBy)"))
        } else if let covering {
            row.set(title: "\(covering.name) (upper half)",
                    subtitle: "Its 32K chip takes banks \(socket.answersAs - 1) and \(socket.answersAs).")
            row.style("hw-quiet")
        } else {
            switch content {
            case .rom(let rom):
                row.set(title: rom.name, subtitle: library[rom.id]?.summary ?? rom.layout.displayName)
            case .empty:
                row.set(title: "Empty", subtitle: socket.standard.map { "\($0) taken out" } ?? "")
                row.style("hw-quiet")
            case nil:
                if let standard = socket.standard {
                    row.set(title: standard, subtitle: "As standard")
                } else {
                    row.set(title: "Empty", subtitle: "")
                    row.style("hw-quiet")
                }
            }
        }
        if let problem {
            row.subtitle = problem
            row.style("hw-problem")
            row.suffix(Icon("dialog-warning-symbolic").style("warning").tooltip(problem).accessibleLabel(problem))
        }
        if socket.takenBy == nil && covering == nil {
            let menu = socketMenu(socket, in: group)
            menus[socket.bank] = menu
            row.suffix(menu)
            register("socket \(socket.bank)", menu)
            row.style("hw-drop")
            row.onDropFiles { [weak self] urls, _, _ in
                guard let self, let url = urls.first else { return false }
                self.plugFile(url, into: socket, group: group, over: row)
                return true
            }
        }
        return row
    }

    private func fits(_ rom: UserROM, _ socket: ROMSocket, in group: ROMSocketGroup) -> Bool {
        guard rom.layout == .pair else { return true }
        return group.takesPairs && socket.bank % 2 == 0 && group.sockets.contains { $0.bank == socket.bank + 1 && $0.takenBy == nil }
    }

    private func socketMenu(_ socket: ROMSocket, in group: ROMSocketGroup) -> MenuButton {
        let button = MenuButton(label: setup.sockets.roms[socket.bank]?.rom == nil ? "Plug In" : "Change")
        button.tooltip("Choose what's in bank \(socket.answersAs)").align(vertical: GTK_ALIGN_CENTER)
        // (Made as it opens: the library as it is then.)
        button.popover(Box(.vertical, spacing: 0)) { [weak self, button] box, popover in
            guard let self else { return }
            box.removeAll()
            let current = self.sockets().roms[socket.bank]
            let roms = self.library.roms.filter { self.fits($0, socket, in: group) }
            if !roms.isEmpty {
                box.append(Label("ROM Library", style: "hw-menu-heading"))
                for rom in roms {
                    box.append(popoverItem(rom.name, detail: rom.summary, in: popover) { [weak self] in
                        self?.plug(rom, into: socket)
                    })
                }
            }
            box.append(popoverItem("Add ROM File…", in: popover) { [weak self] in
                self?.chooseFile(for: socket, group: group, over: button)
            })
            box.append(Separator())
            if let standard = socket.standard {
                box.append(popoverItem("Put Back \(standard)", enabled: current != nil, in: popover) { [weak self] in
                    self?.setContent(nil, bank: socket.bank)
                })
                box.append(popoverItem("Take Out \(standard)", enabled: current != .empty, in: popover) { [weak self] in
                    self?.setContent(.empty, bank: socket.bank)
                })
            } else {
                box.append(popoverItem("Empty Socket", enabled: current != nil, in: popover) { [weak self] in
                    self?.setContent(nil, bank: socket.bank)
                })
            }
        }
        return button
    }

    private func setContent(_ content: SocketContent?, bank: Int) {
        var new = sockets()
        new.roms[bank] = content
        setSockets(new)
    }

    private func plug(_ rom: UserROM, into socket: ROMSocket) {
        var new = sockets()
        new.roms[socket.bank] = .rom(rom.plugged)
        // A two-bank chip takes the upper bank too.
        if rom.layout == .pair { new.roms[socket.bank + 1] = nil }
        setSockets(new)
    }

    private func chooseFile(for socket: ROMSocket, group: ROMSocketGroup, over parent: Widget) {
        // (The Mac's panel says: a sideways ROM image, 16K or less, or a
        // 32K, 64K or 128K ROM, copied into the ROM library.)
        ROMFileDialog.open(title: "Add a ROM to Bank \(socket.answersAs)", accept: "_Add") { [weak self] urls in
            guard let self, let url = urls.first else { return }
            self.plugFile(url, into: socket, group: group, over: parent)
        }
    }

    private func plugFile(_ url: URL, into socket: ROMSocket, group: ROMSocketGroup, over parent: Widget) {
        do {
            let rom = try library.add(fileAt: url)
            guard fits(rom, socket, in: group) else {
                HardwareAlerts.show("ROM", "\(rom.name) is two 16K ROMs in a 32K chip, which needs a socket that takes two banks. It's in the ROM library, where you can change how it's laid out.", over: parent)
                return
            }
            plug(rom, into: socket)
        } catch {
            HardwareAlerts.show("ROM", "\(error)", over: parent)
        }
    }
}
