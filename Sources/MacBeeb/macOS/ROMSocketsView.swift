import AppKit
import BeebCore
import BeebNetwork
import SwiftUI
import UniformTypeIdentifiers

/// The machine's ROM sockets, as the hardware has them, and what's in
/// them: the standard ROMs, the user's from the ROM library, or nothing.
/// On the Master, its cartridge slots and the links that make banks 4-7
/// ROM sockets.
struct ROMSocketsSection: View {
    @Binding var sockets: SocketSetup
    /// The machine as it would be with `sockets`.
    let setup: MachineSetup
    /// A network's station: its Econet ROM takes a socket.
    let econet: Bool
    let source: ROMSource
    @State private var error: String?
    @Environment(\.openWindow) private var openWindow

    private var library: ROMLibrary { ROMLibrary.shared }

    var body: some View {
        let groups = setup.socketGroups(econet: econet)
        let problems = setup.socketProblems(econet: econet, source: source)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(setup.model == .master128 ? "Cartridges and ROM Sockets" : "ROM Sockets",
                         detail: detail)
            ForEach(groups) { group in
                groupCard(group, problems: problems)
            }
            HStack {
                Label("Add ROMs to the library to plug them in: drop .rom files on a socket, or use its menu.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("ROM Library…") { openWindow(id: ROMLibraryWindow.windowID) }
            }
        }
        .alert("ROM", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var detail: String {
        switch setup.model {
        case .master128: "Two cartridge slots at the front of the keyboard, and links that make banks 4–7 ROM sockets."
        case .bPlus: "Five sockets that each take a 32K chip (two banks), and BASIC and the DFS."
        default: "The ROMs plugged into the motherboard. The highest-numbered language starts at power on."
        }
    }

    // MARK: Groups

    private func groupCard(_ group: ROMSocketGroup, problems: [Int: String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol(group))
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.headline)
                    Text(group.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                groupControl(group)
            }
            .padding(12)
            ForEach(group.sockets) { socket in
                Divider()
                socketRow(socket, in: group, problem: problems[socket.bank])
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func symbol(_ group: ROMSocketGroup) -> String {
        switch group.kind {
        case .motherboard: "cpu"
        case .board: "square.grid.3x3"
        case .cartridge: "rectangle.portrait.bottomhalf.inset.filled"
        case .link: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    @ViewBuilder
    private func groupControl(_ group: ROMSocketGroup) -> some View {
        switch group.kind {
        case .cartridge(let slot):
            Picker("Cartridge", selection: Binding(
                get: { sockets.cartridges[slot] },
                set: { setCartridge($0, slot: slot) }
            )) {
                Text("No Cartridge").tag(Cartridge?.none)
                ForEach(Cartridge.allCases, id: \.self) { cartridge in
                    Text(cartridge.displayName).tag(Cartridge?.some(cartridge))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("What's plugged into this slot")
        case .link(let bank):
            Picker("Link", selection: Binding(
                get: { sockets.romLinks.contains(bank) },
                set: { setLink($0, bank: bank) }
            )) {
                Text("Sideways RAM").tag(false)
                Text("ROM Socket").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(bank == 4 ? "Link LK19: West for sideways RAM in banks 4 and 5, East for ROMs in IC37"
                  : "Link LK18: West for sideways RAM in banks 6 and 7, East for ROMs in IC41")
        case .motherboard, .board:
            EmptyView()
        }
    }

    // (Each makes its changes to a copy and writes it once: writes in a
    // row through the binding each start from what it was before.)

    private func setCartridge(_ cartridge: Cartridge?, slot: Int) {
        var new = sockets
        new.cartridges[slot] = cartridge
        // Its ROMs come out with it.
        if cartridge != .roms {
            new.roms[slot * 2] = nil
            new.roms[slot * 2 + 1] = nil
        }
        sockets = new
    }

    private func setLink(_ rom: Bool, bank: Int) {
        var new = sockets
        if rom {
            new.romLinks.insert(bank)
        } else {
            new.romLinks.remove(bank)
            new.roms[bank] = nil
            new.roms[bank + 1] = nil
        }
        sockets = new
    }

    // MARK: Sockets

    /// The two-bank ROM whose upper half is in `bank`, if there is one.
    private func pairCovering(_ bank: Int, in group: ROMSocketGroup) -> PluggedROM? {
        guard group.takesPairs, bank % 2 == 1, let rom = sockets.roms[bank - 1]?.rom, rom.layout == .pair else { return nil }
        return rom
    }

    private func socketRow(_ socket: ROMSocket, in group: ROMSocketGroup, problem: String?) -> some View {
        let covering = pairCovering(socket.bank, in: group)
        let content = sockets.roms[socket.bank]
        return HStack(alignment: .center, spacing: 12) {
            Text("\(socket.answersAs)")
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(socket.takenBy != nil || covering != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.blue))
                .frame(width: 36)
                .help("Bank \(socket.answersAs)")
            VStack(alignment: .leading, spacing: 2) {
                if let takenBy = socket.takenBy {
                    Label(takenBy, systemImage: "lock")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } else if let covering {
                    Text("\(covering.name) (upper half)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Its 32K chip takes banks \(socket.answersAs - 1) and \(socket.answersAs).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    contentLabel(content, standard: socket.standard)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if socket.takenBy == nil && covering == nil {
                socketMenu(socket, in: group)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard socket.takenBy == nil, covering == nil, let url = urls.first else { return false }
            plugFile(url, into: socket, group: group)
            return true
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func contentLabel(_ content: SocketContent?, standard: String?) -> some View {
        switch content {
        case .rom(let rom):
            Text(rom.name)
                .font(.headline)
            Text(library[rom.id]?.summary ?? rom.layout.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .empty:
            Text("Empty")
                .font(.headline)
                .foregroundStyle(.secondary)
            if let standard {
                Text("\(standard) taken out")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case nil:
            if let standard {
                Text(standard)
                    .font(.headline)
                Text("As standard")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Empty")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fits(_ rom: UserROM, _ socket: ROMSocket, in group: ROMSocketGroup) -> Bool {
        guard rom.layout == .pair else { return true }
        return group.takesPairs && socket.bank % 2 == 0 && group.sockets.contains { $0.bank == socket.bank + 1 && $0.takenBy == nil }
    }

    private func socketMenu(_ socket: ROMSocket, in group: ROMSocketGroup) -> some View {
        Menu {
            let roms = library.roms.filter { fits($0, socket, in: group) }
            if !roms.isEmpty {
                Section("ROM Library") {
                    ForEach(roms) { rom in
                        Button {
                            plug(rom, into: socket)
                        } label: {
                            Text(rom.name) + Text("  \(rom.summary)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button("Add ROM File…") { chooseFile(for: socket, group: group) }
            Divider()
            if let standard = socket.standard {
                Button("Put Back \(standard)") { sockets.roms[socket.bank] = nil }
                    .disabled(sockets.roms[socket.bank] == nil)
                Button("Take Out \(standard)") { sockets.roms[socket.bank] = .empty }
                    .disabled(sockets.roms[socket.bank] == .empty)
            } else {
                Button("Empty Socket") { sockets.roms[socket.bank] = nil }
                    .disabled(sockets.roms[socket.bank] == nil)
            }
        } label: {
            Text(sockets.roms[socket.bank]?.rom == nil ? "Plug In" : "Change")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Choose what's in bank \(socket.answersAs)")
    }

    private func plug(_ rom: UserROM, into socket: ROMSocket) {
        var new = sockets
        new.roms[socket.bank] = .rom(rom.plugged)
        // A two-bank chip takes the upper bank too.
        if rom.layout == .pair { new.roms[socket.bank + 1] = nil }
        sockets = new
    }

    private func chooseFile(for socket: ROMSocket, group: ROMSocketGroup) {
        let panel = NSOpenPanel()
        panel.prompt = "Add"
        panel.message = "A sideways ROM image: 16K or less, or a 32K, 64K or 128K ROM. It's copied into the ROM library."
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK, let url = panel.url {
            plugFile(url, into: socket, group: group)
        }
    }

    private func plugFile(_ url: URL, into socket: ROMSocket, group: ROMSocketGroup) {
        do {
            let rom = try library.add(fileAt: url)
            guard fits(rom, socket, in: group) else {
                error = "\(rom.name) is two 16K ROMs in a 32K chip, which needs a socket that takes two banks. It's in the ROM library, where you can change how it's laid out."
                return
            }
            plug(rom, into: socket)
        } catch {
            self.error = "\(error)"
        }
    }
}
