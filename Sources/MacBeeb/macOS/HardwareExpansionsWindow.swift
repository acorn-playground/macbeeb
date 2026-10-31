import AppKit
import BeebCore
import BeebNetwork
import BeebROMs
import SwiftUI
import UniformTypeIdentifiers

/// Machine > Hardware: the ROMs in the machine's sockets (and the Master's
/// cartridges), the Model B's memory board and its physical memory, the
/// sixteen sideways banks, loading sideways RAM, and VideoNuLA.
///
/// The board is chosen as a draft: fitting it restarts the BBC (as
/// switching off and on would), so nothing changes until Restart. Loading
/// and clearing sideways RAM works on the running BBC straight away.
struct HardwareExpansionsWindow: View {
    static let windowID = "hardware-expansions"
    /// For a `HardwareRef`: a station, on or off, or a saved configuration.
    static let refWindowID = "hardware"
    let target: any HardwareTarget
    @State private var draft: MachineController.HardwareDraft
    @State private var snapshot: MachineController.HardwareSnapshot?
    @State private var error: String?
    @State private var clearing: Int?
    @Environment(\.openWindow) private var openWindow

    init(target: any HardwareTarget) {
        self.target = target
        _draft = State(initialValue: target.hardwareDraft)
    }

    init(machine: MachineController) {
        self.init(target: machine)
    }

    /// The running machine, for what's in its memory now.
    private var running: MachineController? { target.running }

    private var pending: Bool { draft != target.hardwareDraft }

    var body: some View {
        Group {
            if draft.model == .modelB {
                content
            } else {
                otherModel
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 760)
        .navigationTitle("Hardware")
        .toolbar {
            ToolbarItem {
                Button("Save Configuration…", systemImage: "square.and.arrow.down") { saveConfiguration(target.setup) }
                    .disabled(pending)
                    .help(pending ? "Restart the BBC with these changes first, then save it as a machine configuration"
                          : "Save this machine's set-up under a name, to use in other windows and networks")
            }
            ToolbarItem {
                Button("Guide", systemImage: "questionmark.circle") {
                    openWindow(id: GuideWindow.windowID, value: draft.expansions.guidePage)
                }
                .help("Open the Hardware Expansion Guide")
            }
        }
        .navigationSubtitle(target.hardwareTitle ?? "")
        .task(id: target.hardwareChanges) {
            // The running machine, refreshed while the window's open (the
            // selected bank changes as the BBC runs).
            while !Task.isCancelled {
                let new = await running?.hardwareSnapshot()
                if new != snapshot {
                    snapshot = new
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onChange(of: target.hardwareDraft) { draft = target.hardwareDraft }
        .alert("Sideways RAM", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog("Clear bank \(clearing ?? 0)?", isPresented: Binding(get: { clearing != nil },
                                                                              set: { if !$0 { clearing = nil } })) {
            Button("Clear Bank", role: .destructive) {
                if let bank = clearing { run { try await running?.clearSidewaysBank(bank) } }
            }
        } message: {
            Text("Everything in it is lost: a ROM image there disappears at the next Break.")
        }
    }

    // MARK: Not a Model B

    private var otherModel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                modelHeader(draft.model == .modelA ? "16K of RAM and four ROM sockets."
                            : "Its shadow and sideways RAM are built in.")
                if draftSetup.hasROMSockets {
                    socketsSection
                }
                banksSection
                HStack(spacing: 14) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("Sideways RAM modules, and Watford and Aries memory boards, fit the BBC Model B.")
                    Spacer()
                    Button("Switch to a Model B") { draft.model = .modelB }
                }
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                videoSection
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            restartBar
        }
        .animation(.snappy(duration: 0.25), value: draft)
    }

    // MARK: ROM sockets

    /// The machine as the draft would make it.
    private var draftSetup: MachineSetup {
        var setup = target.setup
        setup.model = draft.model
        setup.expansions = draft.expansions
        setup.controllerROMPaths = draft.controllerROMPaths
        setup.videoNuLA = draft.videoNuLA
        setup.sockets = draft.sockets
        return setup
    }

    private var socketsSection: some View {
        ROMSocketsSection(sockets: $draft.sockets, setup: draftSetup, econet: target.isStation, source: target.romSource)
    }

    // MARK: Video

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Video", detail: "VideoNuLA replaces the Video ULA: each of the sixteen colours can be any of 4,096. It fits any model, with any memory board.",
                         guide: "videonula")
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 26))
                        .foregroundStyle(draft.videoNuLA ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("VideoNuLA fitted", isOn: $draft.videoNuLA)
                            .toggleStyle(.switch)
                            .font(.headline)
                            .help("Fit VideoNuLA in place of the Video ULA (restarts the BBC)")
                        Text(draft.videoNuLA
                             ? "Programs set colours by writing &FE23; the standard colours until they do."
                             : "The stock Video ULA: eight colours, and eight flashing ones.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if draft.videoNuLA, !pending, let nula = snapshot?.nula {
                    NuLAPaletteView(nula: nula)
                        .transition(.opacity)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: The Model B

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                boardSection
                moduleSection
                if draft.expansions.controllerROMBank != nil {
                    firmwareSection
                }
                socketsSection
                memorySection
                if draft.expansions.board == .watford32K || draft.expansions.board.isAries {
                    shadowSection
                }
                banksSection
                videoSection
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            restartBar
        }
        .animation(.snappy(duration: 0.25), value: draft)
    }

    private var expansions: BBCMicro.Expansions { draft.expansions }

    private var header: some View {
        modelHeader(memorySummary(expansions))
    }

    /// The model, which can be changed here (as everything else, it takes
    /// effect when the BBC restarts), and what it has.
    private func modelHeader(_ summary: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.model.displayName)
                    .font(.largeTitle.weight(.semibold))
                    .contentTransition(.opacity)
                Text(summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Picker("Model", selection: $draft.model) {
                ForEach(BBCMicro.Model.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .fixedSize()
            .help("Which BBC Micro this is. It changes when the BBC restarts; discs stay in their drives.")
        }
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

    private var boardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("In the 6502’s Socket", detail: "A shadow RAM board fits between the 6502 and its socket. One at a time.",
                         guide: expansions.board.guidePage)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(BBCMicro.MemoryBoard.allCases, id: \.self) { board in
                    BoardCard(symbol: board.symbolName, name: board.displayName, blurb: board.blurb, extraRAM: board.extraRAM,
                              selected: expansions.board == board, fitted: target.setup.expansions.board == board) {
                        draft.expansions.board = board
                        // The B12 takes the module's socket.
                        if !board.takesSidewaysModule { draft.expansions.sidewaysRAM = .none }
                    }
                }
            }
            if expansions.board.isAries {
                ariesOptions
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Sideways RAM module

    private var moduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("In a ROM Socket", detail: "A sideways RAM module plugs into a free motherboard ROM socket, with or without a board.",
                         guide: "sideways-ram")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(BBCMicro.SidewaysModule.allCases, id: \.self) { module in
                    BoardCard(symbol: module.symbolName, name: module.displayName, blurb: module.blurb, extraRAM: module.extraRAM,
                              selected: expansions.sidewaysRAM == module, fitted: target.setup.expansions.sidewaysRAM == module,
                              disabledReason: !expansions.board.takesSidewaysModule && module != .none
                                  ? "The B12’s cable plugs into all four ROM sockets" : nil) {
                        draft.expansions.sidewaysRAM = module
                    }
                }
            }
            if expansions.sidewaysRAM != .none {
                wiring
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !expansions.board.takesSidewaysModule {
                Label("With the B12 there’s no free ROM socket for a module, but the B12 has 16K of sideways RAM of its own (bank 0).",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var wiring: some View {
        let first = expansions.bank(ofSocket: expansions.sidewaysRAMSocket)
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Socket:")
                    .gridColumnAlignment(.trailing)
                Picker("Socket", selection: $draft.expansions.sidewaysRAMSocket) {
                    Text("Leftmost · bank \(expansions.bank(ofSocket: 12))").tag(12)
                    Text("Next · bank \(expansions.bank(ofSocket: 13))").tag(13)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("The free motherboard socket the module plugs into, which is its first bank (the other two hold DFS and BASIC)")
                Text(expansions.board == .watford32K ? "The Watford ROM goes in the other: bank \(expansions.controllerROMBank ?? 13)"
                     : expansions.board == .ariesB32 ? "The B32 renumbers the sockets 12, 9, 10, 11"
                     : "The module’s first bank")
                    .foregroundStyle(.secondary)
            }
            if expansions.sidewaysRAM == .ram32 {
                GridRow {
                    Text("Second bank:")
                    Picker("Second bank", selection: $draft.expansions.secondBankBelow) {
                        Text("Bank \(first - 4)").tag(4)
                        Text("Bank \(first - 8)").tag(8)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Where the module’s flying lead goes: IC76 pin 12 makes the second bank four below the first, pin 11 eight below")
                    Text(expansions.secondBankBelow == 4 ? "Lead on IC76 pin 12" : "Lead on IC76 pin 11")
                        .foregroundStyle(.secondary)
                }
            }
            if expansions.secondBankIsAssumed {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Label("With the B32’s renumbering, where the second bank lands isn’t documented: MacBeeb assumes it moves with the first.",
                          systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
            if expansions.board == .ariesB32 {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Label("The B32 write-protects it until *RWRITE EXTERNAL.", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Firmware

    /// The ROM the board will use: the user's, if they've chosen one that's
    /// still there, else the bundled one.
    private var firmwareChoice: (firmware: Firmware?, path: String?, sha256: String) {
        let board = expansions.board
        if let path = draft.controllerROMPath, let data = FileManager.default.contents(atPath: path) {
            let bytes = [UInt8](data)
            if case .known(let firmware) = Firmware.identify(bytes, for: board) {
                return (firmware, path, Firmware.sha256(Array(bytes.prefix(firmware.size))))
            }
            return (nil, path, Firmware.sha256(bytes))
        }
        let standard = Firmware.standard(for: board)
        return (standard, nil, standard?.sha256 ?? "")
    }

    private var firmwareTitle: String {
        let choice = firmwareChoice
        return choice.firmware.map { "\($0.name) \($0.version)" } ?? "Your ROM"
    }

    private var firmwareSection: some View {
        let choice = firmwareChoice
        let bank = expansions.controllerROMBank ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Controller ROM", detail: "The board does nothing without its ROM: it switches the memory and adds the commands.",
                         guide: expansions.board.guidePage)
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "cpu")
                    .font(.system(size: 26))
                    .foregroundStyle(.blue)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(firmwareTitle)
                        .font(.headline)
                    Text(choice.path == nil ? "Bundled with MacBeeb · in bank \(bank)"
                         : "\((choice.path! as NSString).lastPathComponent) · \(choice.firmware == nil ? "not a version MacBeeb knows" : "a known version") · in bank \(bank)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("SHA-256 \(choice.sha256)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Use Another Version…") { chooseFirmware() }
                        .help("Use your own dump of the board’s ROM; MacBeeb checks it against the versions it knows")
                    if choice.path != nil {
                        Button("Use the Bundled ROM") { draft.controllerROMPaths[expansions.board] = nil }
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.prompt = "Use"
        panel.message = "A dump of the \(expansions.board.displayName)’s ROM"
        guard panel.runModal() == .OK, let url = panel.url, let data = FileManager.default.contents(atPath: url.path) else { return }
        let board = expansions.board
        switch Firmware.identify([UInt8](data), for: board) {
        case .known:
            draft.controllerROMPaths[board] = url.path
        case .unknown(let sha256):
            let alert = NSAlert()
            alert.messageText = "This isn’t a version of the ROM MacBeeb knows"
            alert.informativeText = "Its SHA-256 is \(sha256). It may be another version, or a different ROM altogether. Use it anyway?"
            alert.addButton(withTitle: "Use It")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                draft.controllerROMPaths[board] = url.path
            }
        case .wrongSize(let size, let expected):
            error = "That file is \(size) bytes; the \(board.displayName)’s ROM is \(expected / 1024)K (\(expected) bytes)."
        case .anotherBoard(let firmware):
            error = "That’s \(firmware.name) \(firmware.version), the ROM for the \(firmware.board.displayName)."
        }
    }

    // MARK: Shadow RAM

    private var shadowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Shadow RAM", detail: "Two views of the screen’s memory: programs use the board’s RAM while the screen stays in main RAM.",
                         guide: expansions.board.guidePage)
            if expansions.board.isAries {
                AriesPoolView(state: pending ? nil : snapshot?.aries)
                ShadowMapView(shadowStartK: (pending ? nil : snapshot?.aries).map { $0.shadowK == 20 ? 12 : $0.shadowK == 16 ? 16 : 32 } ?? 12,
                              status: ariesStatus, statusColour: snapshot?.aries?.shadow == true && !pending ? .purple : .blue,
                              help: "The B32’s ROM turns shadow RAM on (&FE3F) for programs and off (&FE3E) to draw on the screen.")
            } else {
                ShadowMapView(shadowStartK: 12, status: watfordStatus,
                              statusColour: snapshot?.watfordMapping == .upper || snapshot?.watfordMapping == .all ? .purple : .blue,
                              help: "The board’s latch is set by writing to &FFFF (board RAM at &3000), &FFFE (BBC RAM) or &FFFC (board RAM everywhere). Its ROM switches it as the BBC draws on the screen.")
            }
        }
    }

    private var watfordStatus: String {
        guard !pending, let mapping = snapshot?.watfordMapping else { return "Restart the BBC to fit the board" }
        return switch mapping {
        case .upper: "Now: programs see the board’s RAM at &3000–&7FFF"
        case .all: "Now: the CPU sees the board’s RAM everywhere (&FFFC)"
        case .bbc: "Now: the CPU sees main RAM (the ROM switches to it to draw, and when the board is off)"
        }
    }

    private var ariesStatus: String {
        guard !pending, let aries = snapshot?.aries else { return "Restart the BBC to fit the board" }
        if aries.shadowK == 0 { return "Shadow RAM is off (*XOFF): programs and the screen share main RAM" }
        return aries.shadow ? "Now: programs see the B32’s RAM" : "Now: the CPU sees main RAM (the ROM switches to it to draw, and at the prompt)"
    }

    private var ariesOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $draft.expansions.ariesStartUpLink) {
                Text("Start-up link fitted")
            }
            .help("The link by the 6502 on the B32: fitted, shadow RAM is on at power on and Ctrl-Break")
            Text(expansions.ariesStartUpLink
                 ? "Shadow RAM starts on (20K) at power on and Ctrl-Break, as the board comes."
                 : "Shadow RAM starts off: *XON turns it on.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if expansions.board == .ariesB32B12 {
                Text("With the B12, the BBC’s four ROMs move to its sockets 9–12 (BASIC in 12, DFS in 11) and bank 0 is 16K of RAM.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("The B32 renumbers the motherboard’s sockets 12, 9, 10, 11: BASIC is in bank 11 and DFS in 10.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Memory", detail: "The RAM chips, to scale.")
            PhysicalMemoryBar(expansions: expansions)
        }
    }

    // MARK: Banks

    private struct PlanKey: Hashable {
        var setup: MachineSetup
        var station: Bool
    }

    /// The banks of the machine the draft would build, for the bank strip
    /// (cached: it reads the ROMs).
    private static var planCache: [PlanKey: [BBCMicro.SidewaysSlot]] = [:]

    private func planSlots() -> [BBCMicro.SidewaysSlot] {
        let key = PlanKey(setup: draftSetup, station: target.isStation)
        if let cached = Self.planCache[key] { return cached }
        let configuration = key.setup.configuration(econetStation: key.station ? 1 : nil, roms: target.romSource)
        let slots = BBCMicro(configuration: configuration).sidewaysSlots
        if Self.planCache.count > 50 { Self.planCache.removeAll() }
        Self.planCache[key] = slots
        return slots
    }

    private var plannedSlots: [PlannedSlot] {
        planSlots().map { slot in
            let running = pending ? nil : snapshot?.slots[slot.bank]
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

    private var banksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Sideways Banks",
                         detail: "Sixteen bank numbers, chosen by ROMSEL (&FE30); the highest-numbered language starts at power on.",
                         guide: "developer-reference")
            BankStrip(slots: plannedSlots, selected: pending ? nil : snapshot.map { Int($0.romsel & 0x0F) })
            if !expansions.sidewaysRAMBanks.isEmpty || !(snapshot?.slots.filter { $0.kind == .ram }.isEmpty ?? true)
                || (running == nil && plannedSlots.contains { $0.kind == .ram }) {
                ramBanks
            }
        }
    }

    @ViewBuilder
    private var ramBanks: some View {
        let banks = (snapshot?.slots ?? []).filter { $0.kind == .ram }
        VStack(alignment: .leading, spacing: 0) {
            if running == nil {
                Label("Its sideways RAM starts empty. Load ROM images into it while it's running.", systemImage: "power")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if pending {
                Label("Restart to fit the new board, then load its RAM.", systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(Array(banks.enumerated()), id: \.element.bank) { index, slot in
                    if index > 0 { Divider() }
                    RAMBankRow(slot: slot, note: ariesNote(slot.bank), powerOnImage: target.setup.powerOnImagePaths[slot.bank],
                               load: { url in run { try await running?.loadSidewaysImage(url, bank: slot.bank) } },
                               save: { url in run { try await running?.saveSidewaysBank(slot.bank, to: url) } },
                               clear: { clearing = slot.bank },
                               setPowerOnImage: { running?.setPowerOnImage($0, bank: slot.bank) })
                }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// What applying the changes does.
    private var restartDetail: String {
        if running != nil { return "As switching off and on: what’s in memory is lost. Discs stay in their drives." }
        if target is ConfigurationHardwareTarget { return "Saved in the configuration. Machines already set up from it stay as they are." }
        return "It’s switched off: it starts like this when you switch it on."
    }

    private var restartTitle: String {
        guard running != nil else { return "Save the changes" }
        let current = target.hardwareDraft
        if draft.model != current.model {
            return "Switching to the \(draft.model.displayName) restarts the BBC"
        }
        if draft.expansions != current.expansions && draft.model == .modelB {
            return "Fitting \(expansions.board == .none ? "no board" : "the " + expansions.board.displayName) restarts the BBC"
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

    /// How much of an Aries bank shadow RAM is using.
    private func ariesNote(_ bank: Int) -> String? {
        guard let aries = snapshot?.aries else { return nil }
        switch (bank, aries.shadowK) {
        case (13, 16), (13, 20): return "Used for shadow RAM (&4000–&7FFF) while it’s on"
        case (14, 20): return "12K free (&8000–&AFFF): the top 4K is shadow RAM for &3000–&3FFF"
        default: return nil
        }
    }

    // MARK: Restart

    private var restartBar: some View {
        Group {
            if pending {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(restartTitle)
                            .font(.headline)
                        Text(restartDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revert") { draft = target.hardwareDraft }
                        .keyboardShortcut(.cancelAction)
                    Button(running == nil ? "Save" : "Restart BBC") { target.apply(draft) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: pending)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                self.error = "\(error)"
            }
        }
    }
}

// MARK: - Pieces

struct SectionTitle: View {
    let title: String
    let detail: String
    /// The guide page that explains it, for a Learn More link.
    var guide: String?
    @Environment(\.openWindow) private var openWindow

    init(_ title: String, detail: String, guide: String? = nil) {
        self.title = title
        self.detail = detail
        self.guide = guide
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            if let guide {
                Button("Learn More") { openWindow(id: GuideWindow.windowID, value: guide) }
                    .buttonStyle(.link)
                    .help("Open the Hardware Expansion Guide")
            }
        }
    }
}

extension BBCMicro.MemoryBoard {
    var symbolName: String {
        switch self {
        case .none: "rectangle.dashed"
        case .watford32K: "square.2.layers.3d"
        case .ariesB32: "square.3.layers.3d"
        case .ariesB32B12: "square.grid.3x3"
        }
    }

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
    var symbolName: String {
        switch self {
        case .none: "rectangle.dashed"
        case .ram16: "memorychip"
        case .ram32: "memorychip.fill"
        }
    }

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

private struct BoardCard: View {
    let symbol: String
    let name: String
    let blurb: String
    let extraRAM: Int
    let selected: Bool
    let fitted: Bool
    /// Why it can't be chosen with the rest, if it can't.
    var disabledReason: String?
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(height: 28)
                    Spacer()
                    if extraRAM > 0 {
                        Text("+\(extraRAM / 1024)K")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(disabledReason ?? blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if fitted {
                    Label("Fitted", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabledReason != nil)
        .opacity(disabledReason != nil ? 0.5 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(fitted ? "Fitted now" : disabledReason ?? "")
        .help(disabledReason ?? blurb)
    }
}

/// The physical memory: each chip's share, to scale.
private struct PhysicalMemoryBar: View {
    let expansions: BBCMicro.Expansions

    private struct Block: Identifiable {
        var id: String { name }
        var name: String
        var size: Int
        var colour: Color
        var help: String
    }

    private var blocks: [Block] {
        var blocks = [Block(name: "Main RAM", size: 32, colour: .blue, help: "32K of main RAM at &0000–&7FFF, for programs and the screen")]
        blocks += expansions.sidewaysRAMBanks.map { bank in
            Block(name: "Bank \(bank)", size: 16, colour: .green,
                  help: "16K of sideways RAM, seen at &8000–&BFFF while bank \(bank) is selected")
        }
        if expansions.board == .watford32K {
            blocks.append(Block(name: "Watford board", size: 32, colour: .purple,
                                help: "32K on the Watford board, in place of main RAM at &3000–&7FFF (or all of &0000–&7FFF)"))
        }
        if expansions.board.isAries {
            blocks.append(Block(name: "Aries B32", size: 32, colour: .purple,
                                help: "32K on the B32: banks 13 and 14, less what shadow RAM takes"))
        }
        return blocks
    }

    private var caption: String {
        var text = switch expansions.board {
        case .none: "Main RAM is &0000–&7FFF, for programs and the screen."
        case .watford32K: "The board’s RAM stands in for main RAM at the same addresses; the screen is always in main RAM."
        case .ariesB32, .ariesB32B12: "The B32’s 32K is banks 13 and 14, and what shadow RAM takes comes out of them; the screen is always in main RAM."
        }
        if !expansions.sidewaysRAMBanks.isEmpty {
            text += " Sideways RAM appears at &8000–&BFFF, one bank at a time."
        }
        return text
    }

    var body: some View {
        let total = blocks.reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    ForEach(blocks) { block in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(block.colour.gradient)
                            .overlay {
                                HStack(spacing: 6) {
                                    Text(block.name).fontWeight(.semibold)
                                    Text("\(block.size)K").opacity(0.8)
                                }
                                .font(.callout)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .padding(.horizontal, 4)
                            }
                            .frame(width: max(0, (geometry.size.width - CGFloat(blocks.count - 1) * 3) * CGFloat(block.size) / CGFloat(total)))
                            .help(block.help)
                            .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                    }
                }
            }
            .frame(height: 34)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(blocks.map(\.help).joined(separator: "; "))
    }
}

/// Shadow RAM's two views of memory: what programs see, and what the
/// video shows, to scale from &0000 to &8000; the board's state as the BBC
/// runs.
private struct ShadowMapView: View {
    /// Where the board's RAM starts for programs, in K: 12 (&3000), 16
    /// (&4000), or 32 for none.
    let shadowStartK: Int
    let status: String
    let statusColour: Color
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Programs", detail: "The CPU, with shadow RAM on", segments: shadowStartK >= 32
                ? [("Main RAM", "&0000", 32, .blue)]
                : [("Main RAM", "&0000", shadowStartK, .blue),
                   ("Board RAM", String(format: "&%04X", shadowStartK * 1024), 32 - shadowStartK, .purple)])
            row("Screen", detail: "The video, always", segments: [
                ("", "&0000", 12, .clear),
                ("Main RAM: the screen", "&3000", 20, .blue),
            ])
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColour)
                    .frame(width: 8, height: 8)
                Text(status)
                    .contentTransition(.opacity)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .help(help)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .animation(.snappy(duration: 0.3), value: shadowStartK)
    }

    private func row(_ title: String, detail: String, segments: [(String, String, Int, Color)]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        let (name, start, size, colour) = segment
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(colour == .clear ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(colour.gradient))
                            Text(name)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Text(start)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(colour == .clear ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white.opacity(0.8)))
                                .padding(4)
                        }
                        .frame(width: max(0, (geometry.size.width - CGFloat(segments.count - 1) * 2) * CGFloat(size) / 32))
                    }
                }
            }
            .frame(height: 34)
        }
    }
}

/// The Aries B32's 32K, as banks 13 and 14: how much is shadow RAM and how
/// much sideways RAM, and where writes go, as the BBC runs.
private struct AriesPoolView: View {
    let state: BBCMicro.AriesState?

    private struct Piece: Identifiable {
        var id: String { label + range }
        var label: String
        var range: String
        var size: Int
        var shadow: Bool
    }

    private var pieces: [Piece] {
        let k = state?.shadowK ?? 20
        let bank13 = k > 0
            ? Piece(label: "Shadow", range: "Bank 13 = &4000–&7FFF", size: 16, shadow: true)
            : Piece(label: "Sideways RAM", range: "Bank 13 · &8000–&BFFF", size: 16, shadow: false)
        if k == 20 {
            return [bank13,
                    Piece(label: "Sideways RAM", range: "Bank 14 · &8000–&AFFF", size: 12, shadow: false),
                    Piece(label: "Shadow", range: "= &3000–&3FFF", size: 4, shadow: true)]
        }
        return [bank13, Piece(label: "Sideways RAM", range: "Bank 14 · &8000–&BFFF", size: 16, shadow: false)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.map { $0.shadowAllocation.prefix(1).capitalized + $0.shadowAllocation.dropFirst() } ?? "20K shadow (&3000–&7FFF) + 12K sideways RAM")
                .font(.headline)
                .contentTransition(.opacity)
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    ForEach(pieces) { piece in
                        VStack(spacing: 2) {
                            Text(piece.label).font(.callout.weight(.semibold))
                            Text(piece.range).font(.system(size: 10, design: .monospaced)).opacity(0.85)
                        }
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 4)
                        .frame(width: max(0, (geometry.size.width - CGFloat(pieces.count - 1) * 3) * CGFloat(piece.size) / 32),
                               height: 44)
                        .background(RoundedRectangle(cornerRadius: 6).fill(piece.shadow ? Color.purple.gradient : Color.green.gradient))
                    }
                }
            }
            .frame(height: 44)
            if let state {
                HStack(spacing: 18) {
                    Label(state.shadow ? "Shadow on (&FE3F)" : "Shadow off (&FE3E)", systemImage: state.shadow ? "eye" : "eye.slash")
                    Label("Writes: \(state.writeTarget)", systemImage: "square.and.pencil")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text("*XON, *XON 16 and *XOFF choose the split; it changes at the next MODE or Break.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .animation(.snappy(duration: 0.3), value: state)
        .accessibilityElement(children: .combine)
    }
}

/// VideoNuLA's sixteen colours as the BBC has set them, live.
private struct NuLAPaletteView: View {
    let nula: MachineController.NuLAView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<16, id: \.self) { i in
                    let c = nula.colours[i]
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(red: Double(c >> 8 & 15) / 15, green: Double(c >> 4 & 15) / 15, blue: Double(c & 15) / 15))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                            .overlay(alignment: .topTrailing) {
                                if nula.flashing[i] {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 1)
                                        .padding(3)
                                }
                            }
                            .frame(height: 30)
                        Text("\(i)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        Text(String(format: "%03X", c & 0xFFF))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help(String(format: "Colour %d: RGB444 &%03X (#%02X%02X%02X)%@", i, c & 0xFFF, Int(c >> 8 & 15) * 17,
                                 Int(c >> 4 & 15) * 17, Int(c & 15) * 17, nula.flashing[i] ? ", flashing" : ""))
                }
            }
            .animation(.easeOut(duration: 0.2), value: nula.colours)
            HStack(spacing: 16) {
                Label(nula.disabled ? "Disabled by the BBC until power off" : nula.direct ? "Direct palette" : "Through the ULA’s palette",
                      systemImage: nula.disabled ? "nosign" : "arrow.triangle.branch")
                if nula.offset > 0 { Label("Offset \(nula.offset)", systemImage: "arrow.right.to.line") }
                if nula.blanking > 0 { Label("Left blanking \(nula.blanking)", systemImage: "rectangle.lefthalf.inset.filled") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("VideoNuLA colours: " + (0..<16).map { String(format: "%d %03X", $0, nula.colours[$0] & 0xFFF) }.joined(separator: ", "))
    }
}

struct PlannedSlot: Equatable {
    enum Kind { case rom, ram, emptySocket, notFitted }
    var bank: Int
    var kind: Kind
    var title: String
    var detail: String
    var hasImage: Bool
}

/// Banks 0-15 in a row: ROM, RAM, an empty socket or nothing; a dot under
/// the one selected in ROMSEL just now.
private struct BankStrip: View {
    let slots: [PlannedSlot]
    let selected: Int?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(slots, id: \.bank) { slot in
                VStack(spacing: 4) {
                    cell(slot)
                    Circle()
                        .fill(selected == slot.bank ? Color.accentColor : .clear)
                        .frame(width: 5, height: 5)
                }
                .help(help(slot))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(help(slot))
            }
        }
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private func cell(_ slot: PlannedSlot) -> some View {
        let colour: Color = switch slot.kind {
        case .rom: .blue
        case .ram: .green
        case .emptySocket, .notFitted: .secondary
        }
        return VStack(spacing: 2) {
            Text("\(slot.bank)")
                .font(.system(.headline, design: .rounded).monospacedDigit())
            Text(label(slot))
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .foregroundStyle(slot.kind == .notFitted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(colour))
        .frame(maxWidth: .infinity, minHeight: 46)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(slot.kind == .rom || slot.kind == .ram ? colour.opacity(0.14) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(slot.kind == .notFitted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(colour.opacity(0.5)),
                              style: StrokeStyle(lineWidth: 1, dash: slot.kind == .emptySocket || slot.kind == .notFitted ? [3, 2] : []))
        }
    }

    private func label(_ slot: PlannedSlot) -> String {
        switch slot.kind {
        case .rom: "ROM"
        case .ram: "RAM"
        case .emptySocket: "Empty"
        case .notFitted: "—"
        }
    }

    private func help(_ slot: PlannedSlot) -> String {
        var text = "Bank \(slot.bank): \(slot.title)"
        if !slot.detail.isEmpty { text += " (\(slot.detail))" }
        if selected == slot.bank { text += ". Selected now" }
        return text
    }
}

/// A sideways RAM bank in the running BBC: what's in it, and loading,
/// saving and clearing it.
private struct RAMBankRow: View {
    let slot: BBCMicro.SidewaysSlot
    var note: String?
    let powerOnImage: String?
    let load: (URL) -> Void
    let save: (URL) -> Void
    let clear: () -> Void
    let setPowerOnImage: (URL?) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(slot.bank)")
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(.green)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.header?.name ?? "No ROM image")
                    .font(.headline)
                    .foregroundStyle(slot.header == nil ? .secondary : .primary)
                Group {
                    if let header = slot.header {
                        Text("\(header.isLanguage ? "Language" : "Service") ROM · \(header.copyright)")
                    } else {
                        Text("Empty, or data rather than a ROM")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let note {
                    Label(note, systemImage: "square.2.layers.3d")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                if let powerOnImage {
                    Label("At power on: \((powerOnImage as NSString).lastPathComponent)", systemImage: "power")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Load ROM Image…") {
                if let url = chooseImage(prompt: "Load") { load(url) }
            }
            .help("Put a ROM image (up to 16K) into bank \(slot.bank) now; the BBC finds it at the next Break")
            Menu {
                Button("Save Contents…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "\(slot.header?.title ?? "Bank \(slot.bank)").rom"
                    if panel.runModal() == .OK, let url = panel.url { save(url) }
                }
                Button("Clear…", role: .destructive, action: clear)
                Divider()
                Button(powerOnImage == nil ? "Load an Image at Power On…" : "Change Power-On Image…") {
                    if let url = chooseImage(prompt: "Choose") { setPowerOnImage(url) }
                }
                if powerOnImage != nil {
                    Button("Start Empty at Power On") { setPowerOnImage(nil) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for bank \(slot.bank)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func chooseImage(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.message = "A sideways ROM image, up to 16K (.rom, .bin, or any file)"
        panel.allowedContentTypes = [.data]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
