import BeebCore
import BeebNetwork
import BeebROMs
import CGtk
import Foundation
import Observation

/// Machine > Hardware: the ROMs in the machine's sockets (and the Master's
/// cartridges), the Model B's memory board and its physical memory, the
/// sixteen sideways banks, loading sideways RAM, and VideoNuLA. For a
/// standalone machine, a network's station (on or off), or a saved machine
/// configuration.
///
/// The hardware is chosen as a draft: fitting it restarts the BBC (as
/// switching off and on would), so nothing changes until Restart. Loading
/// and clearing sideways RAM works on the running BBC straight away.
@MainActor
enum HardwareExpansionsWindow {
    static func show(for machine: MachineController) {
        let key = "hardware-\(machine.id)"
        let window = show(target: machine, key: key)
        // A standalone machine's goes with its window (a station runs on
        // without one).
        if !machine.isStation, let machineWindow = MachineWindow.existing(for: machine), window != nil {
            machineWindow.window.onDestroy { Windows.close(key) }
        }
    }

    /// A station's (on or off) or a saved configuration's.
    static func show(ref: HardwareRef) {
        guard let target = ref.target else { return }
        let key = switch ref {
        case .machine(let id): "hardware-\(id)"
        case .station(let network, let node): "hardware-station-\(network.path)-\(node)"
        case .configuration(let id): "hardware-configuration-\(id)"
        }
        let window = show(target: target, key: key)
        if case .configuration(let id) = ref, let window {
            // Removed: its window goes.
            window.track { [weak window] in
                if MachineConfigurations.shared[id] == nil { window?.close() }
            }
        }
    }

    /// The window, if it's new.
    @discardableResult
    private static func show(target: any HardwareTarget, key: String) -> Window? {
        var made: Window?
        Windows.show(key) {
            let controller = HardwareWindowController(target: target)
            controller.register(key)
            made = controller.window
            return controller.window
        }
        HardwareSelfTest.windowShown(key: key)
        return made
    }

    /// The controller of the window for `key`, for the self-test.
    static func controller(_ key: String) -> HardwareWindowController? {
        HardwareWindowController.open[key]
    }
}

/// What the window's choosing, and what the running machine has.
@MainActor
@Observable
final class HardwareModel {
    let target: any HardwareTarget
    var draft: MachineController.HardwareDraft
    var snapshot: MachineController.HardwareSnapshot?

    init(target: any HardwareTarget) {
        self.target = target
        draft = target.hardwareDraft
    }

    /// The running machine, for what's in its memory now.
    var running: MachineController? { target.running }
    var pending: Bool { draft != target.hardwareDraft }
    var expansions: BBCMicro.Expansions { draft.expansions }

    /// The machine as the draft would make it.
    var draftSetup: MachineSetup { draft.applied(to: target.setup) }
}

@MainActor
final class HardwareWindowController {
    static var open: [String: HardwareWindowController] = [:]

    let model: HardwareModel
    let window: Window
    private var target: any HardwareTarget { model.target }
    private var closed = false
    private var lastTargetDraft: MachineController.HardwareDraft

    private let windowTitle = WindowTitle("Hardware")
    private let toolbar: ToolbarView
    private let toasts: ToastOverlay
    private let scroller: ScrolledWindow

    // The model.
    private let modelName = Label("", style: "hw-header-title")
    private let summary = Label("", style: "title-4", "dim-label")
    private let modelPicker = DropDown(BBCMicro.Model.allCases.map(\.displayName))

    // In the 6502's socket.
    private let boardGroup = textGroup("In the 6502’s Socket", "A shadow RAM board fits between the 6502 and its socket. One at a time.")
    private var boardRows: [(board: BBCMicro.MemoryBoard, radio: CheckButton, fitted: Widget)] = []
    private let ariesLink = plainText(SwitchRow("Start-up link fitted"))
    private let ariesNote = noteRow("", icon: "dialog-information-symbolic")

    // In a ROM socket.
    private let moduleGroup = textGroup("In a ROM Socket", "A sideways RAM module plugs into a free motherboard ROM socket, with or without a board.")
    private var moduleRows: [(module: BBCMicro.SidewaysModule, row: ActionRow, radio: CheckButton, fitted: Widget)] = []
    private let socketRow = ActionRow("Socket")
    private let socketChoice = ToggleGroup(["Leftmost · bank 12", "Next · bank 13"], selected: 1) { _ in }.fullWidth()
    private let secondRow = ActionRow("Second bank")
    private let secondChoice = ToggleGroup(["Bank 9", "Bank 5"]) { _ in }.fullWidth()
    private let assumedNote = noteRow("With the B32’s renumbering, where the second bank lands isn’t documented: MacBeeb assumes it moves with the first.",
                                      icon: "dialog-question-symbolic")
    private let protectNote = noteRow("The B32 write-protects it until *RWRITE EXTERNAL.", icon: "changes-prevent-symbolic")
    private let b12Note = noteRow("With the B12 there’s no free ROM socket for a module, but the B12 has 16K of sideways RAM of its own (bank 0).",
                                  icon: "dialog-information-symbolic")

    // The controller ROM.
    private let firmwareGroup = textGroup("Controller ROM", "The board does nothing without its ROM: it switches the memory and adds the commands.")
    private let firmwareRow = ActionRow("")
    private let firmwareHash = ActionRow("SHA-256")
    private var bundledRow: ButtonRow!

    // The sockets.
    private var sockets: ROMSocketsSection!

    // Memory, and shadow RAM.
    private let memoryGroup = textGroup("Memory", "The RAM chips, to scale.")
    private let memoryBar = MemoryBar()
    private let shadowGroup = textGroup("Shadow RAM", "Two views of the screen’s memory: programs use the board’s RAM while the screen stays in main RAM.")
    private let ariesPool = AriesPool()
    private let shadowMap = ShadowMap()

    // The banks.
    private let banksGroup = textGroup("Sideways Banks", "Sixteen bank numbers, chosen by ROMSEL (&FE30); the highest-numbered language starts at power on.")
    private let bankStrip = BankStrip()
    private let ramBanks = ListBox().style("boxed-list")
    private let ramRebuilding = Rebuilding<RAMKey>()

    // Not a Model B.
    private let modelBGroup = PreferencesGroup()

    // Video.
    private let videoGroup = textGroup("Video", "VideoNuLA replaces the Video ULA: each of the sixteen colours can be any of 4,096. It fits any model, with any memory board.")
    private let nulaIcon = Icon("preferences-color-symbolic", size: 24)
    private let nulaSwitch = plainText(SwitchRow("VideoNuLA fitted"))
    private let palette = NuLAPalette()
    private var paletteRow: CustomRow!

    // Restarting.
    private let restartTitle = Label("", style: "heading")
    private let restartDetail = Label("", style: "dim-label")
    private let revertButton = Button("_Revert")
    private let applyButton = Button("_Restart BBC").style("suggested-action")
    private var revertAction: Action!
    private let saveButton = Button(icon: "document-save-symbolic")
    /// Everything in the window, scrolling (for the self-test's pictures).
    private(set) var column: Widget!

    init(target: any HardwareTarget) {
        HardwareStyles.install()
        model = HardwareModel(target: target)
        lastTargetDraft = model.draft
        window = Window(title: "Hardware", width: 760, height: 860)
        window.minimumSize(width: 600, height: 420)
        scroller = ScrolledWindow(nil, horizontal: GTK_POLICY_NEVER)
        toasts = ToastOverlay(scroller)
        toolbar = ToolbarView(content: toasts)

        sockets = ROMSocketsSection(sockets: { [weak self] in self?.model.draft.sockets ?? .standard },
                                    set: { [weak self] new in self?.model.draft.sockets = new })
        buildHeaderBar()
        buildBoard()
        buildModule()
        buildFirmware()
        buildMemory()
        buildBanks()
        buildModelB()
        buildVideo()
        buildRestartBar()

        let column = Box(.vertical, spacing: 24) {
            buildModelHeader()
            boardGroup
            moduleGroup
            firmwareGroup
            sockets.widget
            memoryGroup
            shadowGroup
            banksGroup
            modelBGroup
            videoGroup
        }
        column.margin(top: 24, bottom: 32, start: 12, end: 12)
        self.column = column
        scroller.child = Clamp(column, maximum: 720)
        window.content = toolbar
        App.addStandardShortcuts(to: window)
        window.action("close") { [weak window] in window?.close() }

        observe()
        poll()
        window.keep(self)
        window.onDestroy { [weak self] in
            self?.closed = true
            Self.open = Self.open.filter { $0.value !== self }
        }
    }

    /// Registers it under its key (for the self-test).
    func register(_ key: String) { Self.open[key] = self }

    /// A socket's menu button (for the self-test).
    func socketMenu(_ bank: Int) -> MenuButton? { sockets.menus[bank] }

    // MARK: Header bar

    private func buildHeaderBar() {
        let header = HeaderBar(title: windowTitle)
        let guide = Button(icon: "help-browser-symbolic") { [weak self] in
            GuideWindow.show(page: self?.model.expansions.guidePage ?? "README")
        }
        .tooltip("Open the Hardware Expansion Guide")
        .accessibleLabel("Guide")
        saveButton.onClicked { [weak self] in
            guard let self else { return }
            saveConfiguration(self.target.setup)
        }
        saveButton.accessibleLabel("Save Configuration…")
        header.end(guide).end(saveButton)
        toolbar.top(header)
    }

    // MARK: The model

    /// The model, which can be changed here (as everything else, it takes
    /// effect when the BBC restarts), and what it has.
    private func buildModelHeader() -> Widget {
        summary.wrap()
        modelName.wrap()
        modelPicker.tooltip("Which BBC Micro this is. It changes when the BBC restarts; discs stay in their drives.")
            .accessibleLabel("Model")
            .align(vertical: GTK_ALIGN_CENTER)
        modelPicker.object.onChange("selected") { [weak self] in
            guard let self, BBCMicro.Model.allCases.indices.contains(self.modelPicker.selected) else { return }
            let chosen = BBCMicro.Model.allCases[self.modelPicker.selected]
            if self.model.draft.model != chosen { self.model.draft.model = chosen }
        }
        let names = Box(.vertical, spacing: 4) {
            modelName
            summary
        }
        names.expand(horizontal: true)
        return Box(.horizontal, spacing: 12) {
            names
            modelPicker
        }
        .margin(horizontal: 6)
    }

    private func memorySummary(_ e: BBCMicro.Expansions) -> String {
        var parts = ["32K main RAM"]
        switch e.board {
        case .none: break
        case .watford32K: parts.append("32K of shadow RAM")
        case .ariesB32: parts.append("32K for shadow and sideways RAM")
        case .ariesB32B12: parts.append(contentsOf: ["32K for shadow and sideways RAM", "16K sideways RAM"])
        }
        if e.sidewaysRAM != .none { parts.append("\(e.sidewaysRAM.extraRAM / 1024)K sideways RAM module") }
        return parts.count == 1 ? "32K of RAM, four ROM sockets" : parts.joined(separator: " + ")
    }

    // MARK: Board

    private func buildBoard() {
        boardGroup.headerSuffix(learnMoreButton { [weak self] in self?.model.expansions.board.guidePage ?? "README" })
        var first: CheckButton?
        for board in BBCMicro.MemoryBoard.allCases {
            let radio = CheckButton("")
            if let first { radio.group(with: first) } else { first = radio }
            radio.accessibleLabel(board.displayName)
            let fitted = fittedLabel()
            let row = ActionRow(board.displayName, subtitle: board.blurb)
            row.prefix(radio)
            row.suffix(fitted)
            if board.extraRAM > 0 { row.suffix(badge("+\(board.extraRAM / 1024)K")) }
            row.activates(radio)
            row.tooltip(board.blurb)
            radio.object.on("toggled") { [weak self, radio] in
                guard let self, radio.isOn, self.model.draft.expansions.board != board else { return }
                var draft = self.model.draft
                draft.expansions.board = board
                // The B12 takes the module's socket.
                if !board.takesSidewaysModule { draft.expansions.sidewaysRAM = .none }
                self.model.draft = draft
            }
            boardGroup.add(row)
            boardRows.append((board, radio, fitted))
        }
        ariesLink.tooltip("The link by the 6502 on the B32: fitted, shadow RAM is on at power on and Ctrl-Break")
        ariesLink.object.onChange("active") { [weak self] in
            guard let self, self.model.draft.expansions.ariesStartUpLink != self.ariesLink.isOn else { return }
            self.model.draft.expansions.ariesStartUpLink = self.ariesLink.isOn
        }
        boardGroup.add(ariesLink)
        boardGroup.add(ariesNote)
    }

    private func fittedLabel() -> Widget {
        Box(.horizontal, spacing: 4) {
            Icon("object-select-symbolic")
            Label("Fitted")
        }
        .style("hw-fitted")
        .align(vertical: GTK_ALIGN_CENTER)
        .tooltip("Fitted now")
    }

    private func badge(_ text: String) -> Widget {
        Label(text, style: "hw-badge").align(vertical: GTK_ALIGN_CENTER)
    }

    // MARK: Sideways RAM module

    private func buildModule() {
        moduleGroup.headerSuffix(learnMoreButton { "sideways-ram" })
        var first: CheckButton?
        for module in BBCMicro.SidewaysModule.allCases {
            let radio = CheckButton("")
            if let first { radio.group(with: first) } else { first = radio }
            radio.accessibleLabel(module.displayName)
            let fitted = fittedLabel()
            let row = ActionRow(module.displayName, subtitle: module.blurb)
            row.prefix(radio)
            row.suffix(fitted)
            if module.extraRAM > 0 { row.suffix(badge("+\(module.extraRAM / 1024)K")) }
            row.activates(radio)
            radio.object.on("toggled") { [weak self, radio] in
                guard let self, radio.isOn, self.model.draft.expansions.sidewaysRAM != module else { return }
                self.model.draft.expansions.sidewaysRAM = module
            }
            moduleGroup.add(row)
            moduleRows.append((module, row, radio, fitted))
        }
        socketChoice.tooltip("The free motherboard socket the module plugs into, which is its first bank (the other two hold DFS and BASIC)")
            .accessibleLabel("Socket")
            .align(vertical: GTK_ALIGN_CENTER)
        socketChoice.object.onChange("active") { [weak self] in
            guard let self else { return }
            let socket = self.socketChoice.selected == 0 ? 12 : 13
            if self.model.draft.expansions.sidewaysRAMSocket != socket { self.model.draft.expansions.sidewaysRAMSocket = socket }
        }
        socketRow.suffix(socketChoice)
        secondChoice.tooltip("Where the module’s flying lead goes: IC76 pin 12 makes the second bank four below the first, pin 11 eight below")
            .accessibleLabel("Second bank")
            .align(vertical: GTK_ALIGN_CENTER)
        secondChoice.object.onChange("active") { [weak self] in
            guard let self else { return }
            let below = self.secondChoice.selected == 0 ? 4 : 8
            if self.model.draft.expansions.secondBankBelow != below { self.model.draft.expansions.secondBankBelow = below }
        }
        secondRow.suffix(secondChoice)
        for row in [socketRow, secondRow, assumedNote, protectNote, b12Note] {
            moduleGroup.add(row)
        }
    }

    // MARK: Firmware

    /// The ROM the board will use: the user's, if they've chosen one that's
    /// still there, else the bundled one.
    private var firmwareChoice: (firmware: Firmware?, path: String?, sha256: String) {
        let board = model.expansions.board
        if let path = model.draft.controllerROMPath, let data = FileManager.default.contents(atPath: path) {
            let bytes = [UInt8](data)
            if case .known(let firmware) = Firmware.identify(bytes, for: board) {
                return (firmware, path, Firmware.sha256(Array(bytes.prefix(firmware.size))))
            }
            return (nil, path, Firmware.sha256(bytes))
        }
        let standard = Firmware.standard(for: board)
        return (standard, nil, standard?.sha256 ?? "")
    }

    private func buildFirmware() {
        firmwareGroup.headerSuffix(learnMoreButton { [weak self] in self?.model.expansions.board.guidePage ?? "README" })
        let another = Button("Use Another Version…") { [weak self] in self?.chooseFirmware() }
            .tooltip("Use your own dump of the board’s ROM; MacBeeb checks it against the versions it knows")
            .align(vertical: GTK_ALIGN_CENTER)
        firmwareRow.suffix(another)
        firmwareHash.style("hw-mono").subtitleSelectable()
        bundledRow = ButtonRow("Use the Bundled ROM") { [weak self] in
            guard let self else { return }
            self.model.draft.controllerROMPaths[self.model.expansions.board] = nil
        }
        firmwareGroup.add(firmwareRow)
        firmwareGroup.add(firmwareHash)
        firmwareGroup.add(bundledRow)
    }

    private func updateFirmware() {
        let bank = model.expansions.controllerROMBank ?? 0
        let choice = firmwareChoice
        let title = choice.firmware.map { "\($0.name) \($0.version)" } ?? "Your ROM"
        let detail = choice.path.map {
            "\(($0 as NSString).lastPathComponent) · \(choice.firmware == nil ? "not a version MacBeeb knows" : "a known version") · in bank \(bank)"
        } ?? "Bundled with MacBeeb · in bank \(bank)"
        firmwareRow.set(title: title, subtitle: detail)
        firmwareHash.subtitle = choice.sha256
        bundledRow.isVisible = choice.path != nil
    }

    private func chooseFirmware() {
        let board = model.expansions.board
        ROMFileDialog.open(title: "A Dump of the \(board.displayName)’s ROM", accept: "_Use") { [weak self] urls in
            guard let self, let url = urls.first, let data = FileManager.default.contents(atPath: url.path) else { return }
            switch Firmware.identify([UInt8](data), for: board) {
            case .known:
                self.model.draft.controllerROMPaths[board] = url.path
            case .unknown(let sha256):
                AlertDialog("This isn’t a version of the ROM MacBeeb knows",
                            body: "Its SHA-256 is \(sha256). It may be another version, or a different ROM altogether. Use it anyway?")
                    .response("cancel", "_Cancel")
                    .response("use", "_Use It", .suggested)
                    .defaults(default: "use", close: "cancel")
                    .choose(over: self.window) { [weak self] response in
                        if response == "use" { self?.model.draft.controllerROMPaths[board] = url.path }
                    }
            case .wrongSize(let size, let expected):
                self.showError("That file is \(size) bytes; the \(board.displayName)’s ROM is \(expected / 1024)K (\(expected) bytes).")
            case .anotherBoard(let firmware):
                self.showError("That’s \(firmware.name) \(firmware.version), the ROM for the \(firmware.board.displayName).")
            }
        }
    }

    // MARK: Memory and shadow RAM

    private func buildMemory() {
        memoryGroup.add(memoryBar.widget)
        shadowGroup.headerSuffix(learnMoreButton { [weak self] in self?.model.expansions.board.guidePage ?? "README" })
        shadowGroup.add(Box(.vertical, spacing: 12) {
            ariesPool.widget
            shadowMap.widget
        })
    }

    private func updateShadow() {
        let pending = model.pending
        let snapshot = model.snapshot
        if model.expansions.board.isAries {
            let state = pending ? nil : snapshot?.aries
            ariesPool.update(state)
            let start = state.map { $0.shadowK == 20 ? 12 : $0.shadowK == 16 ? 16 : 32 } ?? 12
            let status: String
            if pending || state == nil {
                status = "Restart the BBC to fit the board"
            } else if state!.shadowK == 0 {
                status = "Shadow RAM is off (*XOFF): programs and the screen share main RAM"
            } else {
                status = state!.shadow ? "Now: programs see the B32’s RAM"
                    : "Now: the CPU sees main RAM (the ROM switches to it to draw, and at the prompt)"
            }
            shadowMap.update(shadowStartK: start, status: status, purple: state?.shadow == true,
                             help: "The B32’s ROM turns shadow RAM on (&FE3F) for programs and off (&FE3E) to draw on the screen.")
        } else {
            let mapping = pending ? nil : snapshot?.watfordMapping
            let status = switch mapping {
            case nil: "Restart the BBC to fit the board"
            case .upper: "Now: programs see the board’s RAM at &3000–&7FFF"
            case .all: "Now: the CPU sees the board’s RAM everywhere (&FFFC)"
            case .bbc: "Now: the CPU sees main RAM (the ROM switches to it to draw, and when the board is off)"
            }
            shadowMap.update(shadowStartK: 12, status: status, purple: mapping == .upper || mapping == .all,
                             help: "The board’s latch is set by writing to &FFFF (board RAM at &3000), &FFFE (BBC RAM) or &FFFC (board RAM everywhere). Its ROM switches it as the BBC draws on the screen.")
        }
    }

    // MARK: Banks

    private struct PlanKey: Hashable {
        var setup: MachineSetup
        var station: Bool
    }

    /// The banks of the machine the draft would build (cached: it reads the
    /// ROMs).
    private static var planCache: [PlanKey: [BBCMicro.SidewaysSlot]] = [:]

    private func planSlots() -> [BBCMicro.SidewaysSlot] {
        let key = PlanKey(setup: model.draftSetup, station: target.isStation)
        if let cached = Self.planCache[key] { return cached }
        let configuration = key.setup.configuration(econetStation: key.station ? 1 : nil, roms: target.romSource)
        let slots = BBCMicro(configuration: configuration).sidewaysSlots
        if Self.planCache.count > 50 { Self.planCache.removeAll() }
        Self.planCache[key] = slots
        return slots
    }

    private var plannedSlots: [PlannedSlot] {
        let pending = model.pending
        let snapshot = model.snapshot
        return planSlots().map { slot in
            let running = pending ? nil : snapshot?.slots.first { $0.bank == slot.bank }
            switch slot.kind {
            case .ram:
                // Its contents only carry over if it's RAM now too.
                let header = running?.kind == .ram ? running?.header : slot.header
                return PlannedSlot(bank: slot.bank, kind: .ram, title: header?.name ?? "Sideways RAM", detail: slot.owner,
                                   hasImage: header != nil)
            case .rom:
                return PlannedSlot(bank: slot.bank, kind: .rom, title: slot.header?.name ?? "ROM", detail: slot.owner, hasImage: true)
            case .empty:
                return slot.owner == "Not fitted"
                    ? PlannedSlot(bank: slot.bank, kind: .notFitted, title: "Not fitted", detail: "", hasImage: false)
                    : PlannedSlot(bank: slot.bank, kind: .emptySocket, title: "Empty socket", detail: slot.owner, hasImage: false)
            }
        }
    }

    private func buildBanks() {
        banksGroup.headerSuffix(learnMoreButton { "developer-reference" })
        banksGroup.add(Box(.vertical, spacing: 12) {
            bankStrip.widget
            ramBanks
        })
    }

    /// What the RAM banks' rows show.
    private struct RAMKey: Equatable {
        enum Mode { case off, pending, banks }
        var mode: Mode
        var banks: [BBCMicro.SidewaysSlot]
        var notes: [String?]
        var powerOn: [Int: String]
    }

    private func updateBanks() {
        let planned = plannedSlots
        let pending = model.pending
        let snapshot = model.snapshot
        bankStrip.update(planned, selected: pending ? nil : snapshot.map { Int($0.romsel & 0x0F) })
        let running = model.running
        let showsRAM = !model.expansions.sidewaysRAMBanks.isEmpty || !(snapshot?.slots.filter { $0.kind == .ram }.isEmpty ?? true)
            || (running == nil && planned.contains { $0.kind == .ram })
        ramBanks.isVisible = showsRAM
        guard showsRAM else { return }
        let banks = (snapshot?.slots ?? []).filter { $0.kind == .ram }
        let key = RAMKey(mode: running == nil ? .off : pending ? .pending : .banks, banks: banks,
                         notes: banks.map { ariesNote($0.bank) }, powerOn: target.setup.powerOnImagePaths)
        ramRebuilding.update(key, in: ramBanks) { register in
            ramBanks.removeAll()
            switch key.mode {
            case .off:
                ramBanks.append(noteRow("Its sideways RAM starts empty. Load ROM images into it while it's running.",
                                        icon: "system-shutdown-symbolic"))
            case .pending:
                ramBanks.append(noteRow("Restart to fit the new board, then load its RAM.", icon: "view-refresh-symbolic"))
            case .banks:
                for (slot, note) in zip(banks, key.notes) {
                    ramBanks.append(ramBankRow(slot, note: note, powerOnImage: key.powerOn[slot.bank], register: register))
                }
            }
        }
    }

    /// How much of an Aries bank shadow RAM is using.
    private func ariesNote(_ bank: Int) -> String? {
        guard let aries = model.snapshot?.aries else { return nil }
        switch (bank, aries.shadowK) {
        case (13, 16), (13, 20): return "Used for shadow RAM (&4000–&7FFF) while it’s on"
        case (14, 20): return "12K free (&8000–&AFFF): the top 4K is shadow RAM for &3000–&3FFF"
        default: return nil
        }
    }

    /// A sideways RAM bank in the running BBC: what's in it, and loading,
    /// saving and clearing it.
    private func ramBankRow(_ slot: BBCMicro.SidewaysSlot, note: String?, powerOnImage: String?,
                            register: (AnyHashable, Widget) -> Void) -> Widget {
        let bank = slot.bank
        var lines = [slot.header.map { "\($0.isLanguage ? "Language" : "Service") ROM · \($0.copyright)" } ?? "Empty, or data rather than a ROM"]
        if let note { lines.append(note) }
        if let powerOnImage { lines.append("At power on: \((powerOnImage as NSString).lastPathComponent)") }
        let row = ActionRow(slot.header?.name ?? "No ROM image", subtitle: lines.joined(separator: "\n"))
        if slot.header == nil { row.style("hw-quiet") }
        row.prefix(Label("\(bank)", style: "hw-number", "ram").centred())
        let load = Button("Load ROM Image…") { [weak self] in
            ROMFileDialog.open(title: "Load a ROM Image into Bank \(bank)", accept: "_Load") { urls in
                guard let url = urls.first else { return }
                self?.run { [weak self] in try await self?.model.running?.loadSidewaysImage(url, bank: bank) }
            }
        }
        .tooltip("Put a ROM image (up to 16K) into bank \(bank) now; the BBC finds it at the next Break")
        .align(vertical: GTK_ALIGN_CENTER)
        let menu = Menu {
            MenuSection {
                MenuItem("Save Contents…", "bank.save")
                MenuItem("Clear…", "bank.clear")
            }
            MenuSection {
                MenuItem(powerOnImage == nil ? "Load an Image at Power On…" : "Change Power-On Image…", "bank.power-on")
                if powerOnImage != nil {
                    MenuItem("Start Empty at Power On", "bank.start-empty")
                }
            }
        }
        let more = MenuButton(icon: "view-more-symbolic", menu: menu)
            .style("flat")
            .tooltip("More for bank \(bank)")
            .accessibleLabel("More for bank \(bank)")
            .align(vertical: GTK_ALIGN_CENTER)
        let actions = WidgetActions(on: row, prefix: "bank")
        actions.add("save") { [weak self] in
            ROMFileDialog.save(title: "Save the Contents of Bank \(bank)", suggestedName: "\(slot.header?.title ?? "Bank \(bank)").rom") { url in
                guard let url else { return }
                self?.run { [weak self] in try await self?.model.running?.saveSidewaysBank(bank, to: url) }
            }
        }
        actions.add("clear") { [weak self] in
            guard let self else { return }
            HardwareAlerts.confirm("Clear bank \(bank)?", "Everything in it is lost: a ROM image there disappears at the next Break.",
                                   action: "Clear Bank", over: self.window) { [weak self] in
                self?.run { [weak self] in try await self?.model.running?.clearSidewaysBank(bank) }
            }
        }
        actions.add("power-on") { [weak self] in
            ROMFileDialog.open(title: "An Image for Bank \(bank) at Power On", accept: "_Choose") { urls in
                guard let url = urls.first else { return }
                self?.model.running?.setPowerOnImage(url, bank: bank)
            }
        }
        actions.add("start-empty") { [weak self] in self?.model.running?.setPowerOnImage(nil, bank: bank) }
        row.suffix(load)
        row.suffix(more)
        register("load \(bank)", load)
        register("more \(bank)", more)
        return row
    }

    // MARK: Not a Model B

    private func buildModelB() {
        let row = ActionRow("Sideways RAM modules, and Watford and Aries memory boards, fit the BBC Model B.")
        row.prefix(Icon("media-flash-symbolic", size: 24).style("dim-label"))
        row.suffix(Button("Switch to a Model B") { [weak self] in self?.model.draft.model = .modelB }
            .align(vertical: GTK_ALIGN_CENTER))
        modelBGroup.add(row)
    }

    // MARK: Video

    private func buildVideo() {
        videoGroup.headerSuffix(learnMoreButton { "videonula" })
        nulaSwitch.tooltip("Fit VideoNuLA in place of the Video ULA (restarts the BBC)")
        adw_action_row_add_prefix(cast(nulaSwitch.widget), nulaIcon.widget)
        nulaSwitch.object.onChange("active") { [weak self] in
            guard let self, self.model.draft.videoNuLA != self.nulaSwitch.isOn else { return }
            self.model.draft.videoNuLA = self.nulaSwitch.isOn
        }
        paletteRow = CustomRow(palette.widget, title: "VideoNuLA colours")
        videoGroup.add(nulaSwitch)
        videoGroup.add(paletteRow)
    }

    // MARK: Restarting

    private func buildRestartBar() {
        restartTitle.wrap()
        restartDetail.wrap()
        let text = Box(.vertical, spacing: 2) {
            restartTitle
            restartDetail
        }
        text.expand(horizontal: true).align(vertical: GTK_ALIGN_CENTER)
        revertButton.onClicked { [weak self] in self?.revert() }
        revertButton.tooltip("Put everything back as it is now (Escape)").align(vertical: GTK_ALIGN_CENTER)
        applyButton.onClicked { [weak self] in self?.apply() }
        applyButton.align(vertical: GTK_ALIGN_CENTER)
        let bar = Box(.horizontal, spacing: 12) {
            Icon("system-reboot-symbolic", size: 24).style("hw-restart-icon").align(vertical: GTK_ALIGN_CENTER)
            text
            revertButton
            applyButton
        }
        bar.margin(top: 10, bottom: 10, start: 18, end: 18)
        toolbar.bottom(bar)
        adw_toolbar_view_set_bottom_bar_style(cast(toolbar.widget), ADW_TOOLBAR_RAISED_BORDER)
        adw_toolbar_view_set_reveal_bottom_bars(cast(toolbar.widget), 0)
        applyButton.isDefault(in: window)
        revertAction = window.action("revert") { [weak self] in self?.revert() }
        window.shortcut("Escape", action: "win.revert")
    }

    private func revert() {
        guard model.pending else { return }
        model.draft = target.hardwareDraft
    }

    private func apply() {
        guard model.pending else { return }
        target.apply(model.draft)
    }

    /// What applying the changes does.
    private var restartDetailText: String {
        if model.running != nil { return "As switching off and on: what’s in memory is lost. Discs stay in their drives." }
        if target is ConfigurationHardwareTarget { return "Saved in the configuration. Machines already set up from it stay as they are." }
        return "It’s switched off: it starts like this when you switch it on."
    }

    private var restartTitleText: String {
        guard model.running != nil else { return "Save the changes" }
        let draft = model.draft
        let current = target.hardwareDraft
        if draft.model != current.model {
            return "Switching to the \(draft.model.displayName) restarts the BBC"
        }
        if draft.expansions != current.expansions && draft.model == .modelB {
            return "Fitting \(draft.expansions.board == .none ? "no board" : "the " + draft.expansions.board.displayName) restarts the BBC"
        }
        if draft.videoNuLA != current.videoNuLA {
            return draft.videoNuLA ? "Fitting VideoNuLA restarts the BBC" : "Taking VideoNuLA out restarts the BBC"
        }
        if draft.sockets != current.sockets {
            return draft.sockets.cartridges != current.sockets.cartridges || draft.sockets.romLinks != current.sockets.romLinks
                ? "Changing the cartridges or links restarts the BBC" : "Changing the ROMs restarts the BBC"
        }
        return "Changing the board’s ROM restarts the BBC"
    }

    // MARK: Following state

    private func observe() {
        // The target's hardware changed (restarted with the draft, or set
        // from elsewhere): the draft starts again from it.
        window.track { [weak self] in
            guard let self else { return }
            let current = self.target.hardwareDraft
            if current != self.lastTargetDraft {
                self.lastTargetDraft = current
                self.model.draft = current
            }
        }
        window.track { [weak self] in
            guard let self else { return }
            let subtitle = self.target.hardwareTitle ?? ""
            self.windowTitle.subtitle = subtitle
            self.window.title = subtitle.isEmpty ? "Hardware" : "Hardware — \(subtitle)"
        }
        window.track { [weak self] in self?.updateDraft() }
        window.track { [weak self] in self?.updateLive() }
        // Changed (sideways RAM loaded or cleared, a restart): a fresh look.
        window.track { [weak self] in
            guard let self else { return }
            _ = self.target.hardwareChanges
            Task { await self.refresh() }
        }
        // The machine's messages ("Loaded … into bank 4"), here too.
        window.track { [weak self] in
            guard let self, let toast = self.model.running?.toast, self.window.isActive else { return }
            self.toasts.show(toast, timeout: 3)
        }
    }

    /// What follows the draft and the target's set-up.
    private func updateDraft() {
        let draft = model.draft
        let pending = model.pending
        let fitted = target.setup
        let isModelB = draft.model == .modelB
        let e = draft.expansions

        // The model.
        modelName.text = draft.model.displayName
        summary.text = isModelB ? memorySummary(e)
            : draft.model == .modelA ? "16K of RAM and four ROM sockets." : "Its shadow and sideways RAM are built in."
        modelPicker.selected = BBCMicro.Model.allCases.firstIndex(of: draft.model) ?? 0

        // The Model B's own.
        boardGroup.isVisible = isModelB
        moduleGroup.isVisible = isModelB
        memoryGroup.isVisible = isModelB
        modelBGroup.isVisible = !isModelB
        if isModelB {
            for (board, radio, fittedLabel) in boardRows {
                radio.isOn = e.board == board
                fittedLabel.isVisible = fitted.model == .modelB && fitted.expansions.board == board
            }
            ariesLink.isVisible = e.board.isAries
            ariesLink.isOn = e.ariesStartUpLink
            ariesLink.subtitle = e.ariesStartUpLink
                ? "Shadow RAM starts on (20K) at power on and Ctrl-Break, as the board comes."
                : "Shadow RAM starts off: *XON turns it on."
            ariesNote.isVisible = e.board.isAries
            ariesNote.subtitle = e.board == .ariesB32B12
                ? "With the B12, the BBC’s four ROMs move to its sockets 9–12 (BASIC in 12, DFS in 11) and bank 0 is 16K of RAM."
                : "The B32 renumbers the motherboard’s sockets 12, 9, 10, 11: BASIC is in bank 11 and DFS in 10."

            for (module, row, radio, fittedLabel) in moduleRows {
                let reason = !e.board.takesSidewaysModule && module != .none ? "The B12’s cable plugs into all four ROM sockets" : nil
                radio.isOn = e.sidewaysRAM == module
                row.isEnabled = reason == nil
                row.subtitle = reason ?? module.blurb
                row.tooltip(reason ?? module.blurb)
                fittedLabel.isVisible = fitted.model == .modelB && fitted.expansions.sidewaysRAM == module
            }
            let wired = e.sidewaysRAM != .none
            socketRow.isVisible = wired
            socketChoice.setLabel("Leftmost · bank \(e.bank(ofSocket: 12))", at: 0)
            socketChoice.setLabel("Next · bank \(e.bank(ofSocket: 13))", at: 1)
            socketChoice.selected = e.sidewaysRAMSocket == 12 ? 0 : 1
            socketRow.subtitle = e.board == .watford32K ? "The Watford ROM goes in the other: bank \(e.controllerROMBank ?? 13)"
                : e.board == .ariesB32 ? "The B32 renumbers the sockets 12, 9, 10, 11"
                : "The module’s first bank"
            let first = e.bank(ofSocket: e.sidewaysRAMSocket)
            secondRow.isVisible = wired && e.sidewaysRAM == .ram32
            secondChoice.setLabel("Bank \(first - 4)", at: 0)
            secondChoice.setLabel("Bank \(first - 8)", at: 1)
            secondChoice.selected = e.secondBankBelow == 4 ? 0 : 1
            secondRow.subtitle = e.secondBankBelow == 4 ? "Lead on IC76 pin 12" : "Lead on IC76 pin 11"
            assumedNote.isVisible = wired && e.secondBankIsAssumed
            protectNote.isVisible = wired && e.board == .ariesB32
            b12Note.isVisible = !wired && !e.board.takesSidewaysModule

            memoryBar.update(e)
        }
        firmwareGroup.isVisible = isModelB && e.controllerROMBank != nil
        if firmwareGroup.isVisible { updateFirmware() }
        shadowGroup.isVisible = isModelB && (e.board == .watford32K || e.board.isAries)
        ariesPool.widget.isVisible = e.board.isAries

        // The sockets.
        let setup = model.draftSetup
        sockets.widget.isVisible = setup.hasROMSockets
        if setup.hasROMSockets {
            sockets.update(setup: setup, econet: target.isStation, source: target.romSource)
        }

        // Video.
        nulaSwitch.isOn = draft.videoNuLA
        nulaSwitch.subtitle = draft.videoNuLA
            ? "Programs set colours by writing &FE23; the standard colours until they do."
            : "The stock Video ULA: eight colours, and eight flashing ones."
        nulaIcon.setStyle("accent", draft.videoNuLA)
        nulaIcon.setStyle("dim-label", !draft.videoNuLA)

        // Restarting, and saving.
        adw_toolbar_view_set_reveal_bottom_bars(cast(toolbar.widget), pending ? 1 : 0)
        restartTitle.text = restartTitleText
        restartDetail.text = restartDetailText
        applyButton.label = model.running == nil ? "_Save" : "_Restart BBC"
        applyButton.isEnabled = pending
        revertButton.isEnabled = pending
        revertAction.isEnabled = pending
        saveButton.isEnabled = !pending
        saveButton.tooltip(pending ? "Restart the BBC with these changes first, then save it as a machine configuration"
                           : "Save this machine's set-up under a name, to use in other windows and networks")
    }

    /// What follows the running machine (and the draft).
    private func updateLive() {
        let draft = model.draft
        updateBanks()
        if shadowGroup.isVisible || draft.model == .modelB && (draft.expansions.board == .watford32K || draft.expansions.board.isAries) {
            updateShadow()
        }
        let nula = draft.videoNuLA && !model.pending ? model.snapshot?.nula : nil
        paletteRow.isVisible = nula != nil
        if let nula { palette.update(nula) }
    }

    // MARK: The running machine

    /// Looks at the running machine again (the selected bank changes as the
    /// BBC runs) while the window's open.
    private func poll() {
        Task { [weak self] in
            while true {
                guard let self, !self.closed else { return }
                await self.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func refresh() async {
        let new = await model.running?.hardwareSnapshot()
        if new != model.snapshot {
            model.snapshot = new
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                showError("\(error)")
            }
        }
    }

    private func showError(_ message: String) {
        HardwareAlerts.show("Sideways RAM", message, over: window)
    }
}

// MARK: - What the window says about the hardware

extension BBCMicro.MemoryBoard {
    var blurb: String {
        switch self {
        case .none: "Just the 6502. The Model B as it came: 32K, BASIC and DFS in two of its four ROM sockets."
        case .watford32K: "Shadow RAM: programs keep 28K in every screen mode. Its own ROM switches the screen in and out."
        case .ariesB32: "32K shared between shadow and sideways RAM: 20K + 12K, 16K + 16K or none + 32K, with *XON and *XOFF."
        case .ariesB32B12: "The B32 with Aries’ ROM board: twelve ROM sockets and 16K more sideways RAM, sixteen banks in all."
        }
    }

    /// The guide page that explains it.
    var guidePage: String {
        switch self {
        case .none: "README"
        case .watford32K: "watford-shadow-ram"
        case .ariesB32, .ariesB32B12: "aries-b32-b12"
        }
    }
}

extension BBCMicro.SidewaysModule {
    var blurb: String {
        switch self {
        case .none: "The ROM sockets hold ROMs only."
        case .ram16: "A 16K bank of RAM in a ROM socket. Load ROM images from disc instead of fitting chips."
        case .ram32: "Two 16K banks on one module, wired like BeebMaster’s: room for two ROM images."
        }
    }
}

extension BBCMicro.Expansions {
    /// The guide page for what's fitted: the board's, else sideways RAM's.
    var guidePage: String {
        board != .none ? board.guidePage : sidewaysRAM != .none ? "sideways-ram" : "README"
    }
}
