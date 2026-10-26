// Memory and registers for the debugger: every address space by name, read
// and written without side effects.

/// Somewhere memory lives.
public enum MemorySpace: Hashable, Sendable, Codable, CustomStringConvertible {
    /// As the CPU sees it now (with the current paging; I/O is peeked).
    case cpu(DebugCPU)
    /// The 32K at &0000-&7FFF.
    case mainRAM
    /// Shadow RAM, at the addresses it shadows (&3000-&7FFF).
    case shadowRAM
    /// The Master's ANDY (4K at &8000) or the B+'s 12K at &8000.
    case andy
    /// The Master's HAZEL (8K at &C000).
    case hazel
    /// A sideways ROM or RAM bank, at &8000-&BFFF.
    case sidewaysBank(Int)
    /// The OS ROM, at &C000-&FFFF.
    case osROM
    /// The second processor's 64K.
    case parasiteRAM
    /// A Model B expansion board's own RAM (the Watford board's 32K), at
    /// the addresses it can stand in for (&0000-&7FFF).
    case boardRAM

    public var description: String {
        switch self {
        case .cpu(let cpu): cpu == .host ? "host" : "parasite"
        case .mainRAM: "main"
        case .shadowRAM: "shadow"
        case .andy: "andy"
        case .hazel: "hazel"
        case .sidewaysBank(let bank): "bank\(String(bank, radix: 16, uppercase: true))"
        case .osROM: "os"
        case .parasiteRAM: "parasite_ram"
        case .boardRAM: "board"
        }
    }

    /// Parses `description`'s form (and "rom9" etc. for banks).
    public init?(name: String) {
        let lower = name.lowercased()
        switch lower {
        case "host", "cpu": self = .cpu(.host)
        case "parasite", "tube", "second_processor": self = .cpu(.parasite)
        case "main": self = .mainRAM
        case "shadow": self = .shadowRAM
        case "andy": self = .andy
        case "hazel": self = .hazel
        case "os", "mos": self = .osROM
        case "parasite_ram": self = .parasiteRAM
        case "board": self = .boardRAM
        default:
            for prefix in ["bank", "rom"] where lower.hasPrefix(prefix) {
                if let bank = Int(lower.dropFirst(prefix.count), radix: 16), (0..<16).contains(bank) {
                    self = .sidewaysBank(bank)
                    return
                }
            }
            return nil
        }
    }
}

public enum DebugCPUKind: String, Sendable, Codable {
    case mos6502
    case z80
}

public struct DebugRegister: Sendable, Equatable, Identifiable {
    public var name: String
    public var value: Int
    /// Hex digits to show.
    public var digits: Int
    public var id: String { name }
}

public struct DebugFlag: Sendable, Equatable, Identifiable {
    public var label: String
    /// The register name it's set by, or nil if it can't be.
    public var register: String?
    public var set: Bool
    public var id: String { label }
}

public protocol InstructionDisassembler: Sendable {
    /// The instruction at `address` (read with `read`): its text and
    /// length.
    func disassemble(at address: UInt16, read: (UInt16) -> UInt8) -> (text: String, length: Int)
}

extension M6502Disassembler: InstructionDisassembler {}
extension Z80Disassembler: InstructionDisassembler {}

public struct MemoryRegion: Sendable, Equatable {
    public var space: MemorySpace
    public var name: String
    /// The CPU address of the region's first byte.
    public var base: Int
    public var size: Int
    public var isROM: Bool
}

extension BBCMicro {
    /// The debugger, created on first use.
    public var debugger: Debugger {
        if let existing = debuggerIfCreated {
            return existing
        }
        let created = Debugger(machine: self)
        debuggerIfCreated = created
        return created
    }

    /// A 6502 being debugged (nil for a Z80 second processor: see
    /// `debugCPUKind(_:)`).
    public func debugCPU(_ which: DebugCPU) -> M6502? {
        which == .host ? cpu : secondProcessor?.cpu
    }

    /// What `which` is, or nil if it isn't fitted.
    public func debugCPUKind(_ which: DebugCPU) -> DebugCPUKind? {
        switch which {
        case .host: .mos6502
        case .parasite: secondProcessor != nil ? .mos6502 : z80Processor != nil ? .z80 : nil
        }
    }

    public func hasDebugCPU(_ which: DebugCPU) -> Bool {
        debugCPUKind(which) != nil
    }

    /// The address of the instruction `which` is executing, or about to.
    public func instructionAddress(_ which: DebugCPU) -> UInt16 {
        if which == .parasite, let z = z80Processor {
            return z.cpu.pc
        }
        guard let c = debugCPU(which) else { return 0 }
        return c.isAboutToExecute ? c.abus : c.opcodePC
    }

    /// Whether `which` is between instructions (a Z80 always is when
    /// stopped).
    public func isAtInstruction(_ which: DebugCPU) -> Bool {
        debugCPU(which)?.isAboutToExecute ?? true
    }

    /// The stack pointer: S, or the Z80's SP.
    public func stackPointer(_ which: DebugCPU) -> Int? {
        if which == .parasite, let z = z80Processor {
            return Int(z.cpu.sp)
        }
        return debugCPU(which).map { Int($0.s) }
    }

    /// What's on the stack, top first: from S+1 to &1FF on a 6502, from SP
    /// up on a Z80.
    public func stackContents(_ which: DebugCPU, count: Int = 48) -> [(address: UInt16, value: UInt8)] {
        guard let sp = stackPointer(which) else { return [] }
        let addresses = debugCPUKind(which) == .z80
            ? Array(sp..<min(0x10000, sp + count))
            : Array(0x100 + sp + 1..<min(0x200, 0x100 + sp + 1 + count))
        return addresses.map { (UInt16($0), debugRead(.cpu(which), $0) ?? 0xFF) }
    }

    /// The current instruction, then likely callers: return addresses on
    /// the stack that follow a JSR (or a Z80 CALL).
    public func callStack(_ which: DebugCPU, limit: Int = 16) -> [UInt16] {
        guard let sp = stackPointer(which) else { return [] }
        let read = { (a: Int) in Int(self.debugRead(.cpu(which), a & 0xFFFF) ?? 0) }
        let code = { (a: Int) in Int(self.codeRead(which, a & 0xFFFF) ?? 0) }
        var addresses = [instructionAddress(which)]
        if debugCPUKind(which) == .z80 {
            var a = sp
            while a < 0xFFFF && addresses.count < limit && a < sp + 64 {
                let pushed = read(a) | read(a + 1) << 8
                if pushed >= 3, code(pushed - 3) == 0xCD || code(pushed - 3) & 0xC7 == 0xC4 {
                    addresses.append(UInt16(pushed - 3))
                    a += 2
                } else {
                    a += 1
                }
            }
            return addresses
        }
        var s = sp + 1
        while s < 0xFF && addresses.count < limit {
            let pushed = read(0x100 + s) | read(0x100 + s + 1) << 8
            if pushed >= 2 && code(pushed - 2) == 0x20 {
                addresses.append(UInt16(truncatingIfNeeded: pushed - 2))
                s += 2
            } else {
                s += 1
            }
        }
        return addresses
    }

    /// If the instruction at `pc` calls (JSR; a Z80 CALL or RST, or a
    /// repeating block instruction), its length: stepping over it runs to
    /// the instruction after.
    func callLength(_ which: DebugCPU, at pc: UInt16) -> Int? {
        let read = { (a: UInt16) in self.codeRead(which, Int(a)) ?? 0 }
        let op = read(pc)
        if debugCPUKind(which) == .z80 {
            if op == 0xCD || op & 0xC7 == 0xC4 { return 3 }
            if op & 0xC7 == 0xC7 { return 1 }
            if op == 0xED, [0xB0, 0xB1, 0xB2, 0xB3, 0xB8, 0xB9, 0xBA, 0xBB].contains(read(pc &+ 1)) { return 2 }
            return nil
        }
        return op == 0x20 ? 3 : nil
    }

    /// The memory regions this machine has.
    public var memoryRegions: [MemoryRegion] {
        var regions = [
            MemoryRegion(space: .cpu(.host), name: "Host CPU's view", base: 0, size: 0x10000, isROM: false),
            MemoryRegion(space: .mainRAM, name: "Main RAM", base: 0, size: 0x8000, isROM: false),
        ]
        if model != .modelB {
            regions.append(MemoryRegion(space: .shadowRAM, name: "Shadow RAM", base: 0x3000, size: 0x5000, isROM: false))
            regions.append(MemoryRegion(space: .andy, name: model == .bPlus ? "Paged RAM (12K)" : "ANDY",
                                        base: 0x8000, size: model == .bPlus ? 0x3000 : 0x1000, isROM: false))
        }
        if model == .master128 {
            regions.append(MemoryRegion(space: .hazel, name: "HAZEL", base: 0xC000, size: 0x2000, isROM: false))
        }
        if watfordFitted {
            regions.append(MemoryRegion(space: .boardRAM, name: "Watford board RAM", base: 0, size: 0x8000, isROM: false))
        }
        if ariesFitted {
            regions.append(MemoryRegion(space: .boardRAM, name: "Aries B32 RAM (bank 13, then 14)", base: 0, size: 0x8000, isROM: false))
        }
        for bank in 0..<16 where sidewaysStorage(bank) != nil {
            let ram = isSidewaysRAM(bank)
            regions.append(MemoryRegion(space: .sidewaysBank(bank),
                                        name: "Sideways \(ram ? "RAM" : "ROM") \(String(bank, radix: 16, uppercase: true))",
                                        base: 0x8000, size: 0x4000, isROM: !ram))
        }
        regions.append(MemoryRegion(space: .osROM, name: "OS ROM", base: 0xC000, size: 0x4000, isROM: true))
        if secondProcessor != nil || z80Processor != nil {
            regions.append(MemoryRegion(space: .cpu(.parasite), name: "Second processor's view", base: 0, size: 0x10000, isROM: false))
        }
        if secondProcessor != nil || z80Processor != nil {
            regions.append(MemoryRegion(space: .parasiteRAM, name: "Second processor RAM", base: 0, size: 0x10000, isROM: false))
        }
        return regions
    }

    /// The storage behind a physical space's CPU address, if it exists.
    private func storage(_ space: MemorySpace, _ address: Int) -> UnsafeMutablePointer<UInt8>? {
        switch space {
        case .cpu:
            return nil
        case .mainRAM:
            return (0..<0x8000).contains(address) ? ram + address : nil
        case .shadowRAM:
            return model != .modelB && (0x3000..<0x8000).contains(address) ? ram + Self.shadowOffset + address : nil
        case .boardRAM:
            return (watfordFitted || ariesFitted) && (0..<0x8000).contains(address) ? ram + Self.shadowOffset + address : nil
        case .andy:
            let size = model == .bPlus ? 0x3000 : model == .master128 ? 0x1000 : 0
            return (0x8000..<0x8000 + size).contains(address) ? ram + Self.andyOffset + address - 0x8000 : nil
        case .hazel:
            return model == .master128 && (0xC000..<0xE000).contains(address) ? ram + Self.hazelOffset + address - 0xC000 : nil
        case .sidewaysBank(let bank):
            guard (0..<16).contains(bank), (0x8000..<0xC000).contains(address) else { return nil }
            return sidewaysStorage(bank).map { $0 + address - 0x8000 }
        case .osROM:
            return (0xC000..<0x10000).contains(address) ? osROM + address - 0xC000 : nil
        case .parasiteRAM:
            guard (0..<0x10000).contains(address), let ram = secondProcessor?.ram ?? z80Processor?.ram else { return nil }
            return ram + address
        }
    }

    /// Reads memory without side effects; nil if the space or address
    /// doesn't exist (or, for a CPU's view, nothing answers there).
    public func debugRead(_ space: MemorySpace, _ address: Int) -> UInt8? {
        switch space {
        case .cpu(.host):
            guard (0..<0x10000).contains(address) else { return nil }
            let a = UInt16(address)
            if a >= 0xFC00 && a < 0xFF00 {
                return peekIO(a)
            }
            return readPages[pageTable + address >> 12]?[address & 0xFFF]
        case .cpu(.parasite):
            guard (0..<0x10000).contains(address) else { return nil }
            let a = UInt16(address)
            if let z = z80Processor {
                return z.peek(a)
            }
            guard let p = secondProcessor else { return nil }
            return a & 0xFFF0 == 0xFEF0 ? tube.parasitePeek(Int(a)) : p.peek(a)
        default:
            return storage(space, address)?.pointee
        }
    }

    /// Memory as code at `address` sees it: on the B+ and Masters, code in
    /// the VDU drivers' pages (&C000-&DFFF, and the B+'s &A000-&AFFF) sees
    /// shadow RAM where other code sees main RAM, so `debugRead(.cpu)`,
    /// the current instruction's view, can show other code the wrong RAM.
    /// For disassembling.
    public func codeRead(_ which: DebugCPU, _ address: Int) -> UInt8? {
        guard which == .host, (0..<0x10000).contains(address), address < 0xFC00 || address >= 0xFF00 else {
            return debugRead(.cpu(which), address)
        }
        return readPages[codePageTables[address >> 12] + address >> 12]?[address & 0xFFF]
    }

    /// Writes memory, ROM included, without side effects; I/O isn't
    /// written. Returns false if there's nothing there.
    @discardableResult
    public func debugWrite(_ space: MemorySpace, _ address: Int, _ value: UInt8) -> Bool {
        switch space {
        case .cpu(.host):
            guard (0..<0x10000).contains(address), address < 0xFC00 || address >= 0xFF00,
                  let page = readPages[pageTable + address >> 12] else { return false }
            page[address & 0xFFF] = value
            rewinder?.keyframe()
            return true
        case .cpu(.parasite) where z80Processor != nil:
            // Writes go to RAM, under the ROM too.
            guard (0..<0x10000).contains(address) else { return false }
            z80Processor!.ram[address] = value
            rewinder?.keyframe()
            return true
        case .cpu(.parasite):
            guard let p = secondProcessor, (0..<0x10000).contains(address), address & 0xFFF0 != 0xFEF0 else { return false }
            if p.bootMode && address >= 0xF000 { return false }
            p.ram[address] = value
            rewinder?.keyframe()
            return true
        default:
            guard let pointer = storage(space, address) else { return false }
            pointer.pointee = value
            rewinder?.keyframe()
            return true
        }
    }

    // MARK: Registers

    /// The registers to show, in order.
    public func registers(_ which: DebugCPU) -> [DebugRegister] {
        let names: [(String, Int)] = switch debugCPUKind(which) {
        case .mos6502: [("PC", 4), ("A", 2), ("X", 2), ("Y", 2), ("S", 2), ("P", 2)]
        case .z80: [("PC", 4), ("AF", 4), ("BC", 4), ("DE", 4), ("HL", 4), ("IX", 4), ("IY", 4), ("SP", 4),
                    ("AF'", 4), ("BC'", 4), ("DE'", 4), ("HL'", 4), ("I", 2), ("R", 2), ("IM", 1)]
        case nil: []
        }
        return names.compactMap { name, digits in
            register(name, cpu: which).map { DebugRegister(name: name, value: $0, digits: digits) }
        }
    }

    /// The flags to show, in order (P's bits, or F's and the interrupt
    /// flip-flops).
    public func flags(_ which: DebugCPU) -> [DebugFlag] {
        switch debugCPUKind(which) {
        case .mos6502:
            let p = register("P", cpu: which) ?? 0
            return zip(["N", "V", "-", "B", "D", "I", "Z", "C"], (0..<8).reversed()).map { name, bit in
                DebugFlag(label: name, register: ["-", "B"].contains(name) ? nil : name, set: p & 1 << bit != 0)
            }
        case .z80:
            let f = register("F", cpu: which) ?? 0
            let registers: [String?] = ["SF", "ZF", nil, "HF", nil, "PF", "NF", "CF"]
            var flags = zip(zip(["S", "Z", "Y", "H", "X", "P/V", "N", "C"], registers), (0..<8).reversed()).map { pair, bit in
                DebugFlag(label: pair.0, register: pair.1, set: f & 1 << bit != 0)
            }
            for name in ["IFF1", "IFF2"] {
                flags.append(DebugFlag(label: name, register: name, set: register(name, cpu: which) == 1))
            }
            return flags
        case nil:
            return []
        }
    }

    /// A register or flag: A X Y S P PC, C Z I D V N, or CYCLES. On a Z80:
    /// A F B C D E H L, AF BC DE HL IX IY SP PC, IXH IXL IYH IYL, AF' BC'
    /// DE' HL', I R IM, the flags SF ZF HF PF (or VF) NF CF, and IFF1 IFF2.
    public func register(_ name: String, cpu which: DebugCPU) -> Int? {
        if which == .parasite, let z = z80Processor {
            return z80Register(name.uppercased(), z.cpu)
        }
        guard let c = debugCPU(which) else { return nil }
        switch name.uppercased() {
        case "A": return Int(c.a)
        case "X": return Int(c.x)
        case "Y": return Int(c.y)
        case "S", "SP": return Int(c.s)
        case "P": return Int(c.p)
        case "PC": return Int(instructionAddress(which))
        case "C": return c.c ? 1 : 0
        case "Z": return c.z ? 1 : 0
        case "I": return c.i ? 1 : 0
        case "D": return c.d ? 1 : 0
        case "V": return c.v ? 1 : 0
        case "N": return c.n ? 1 : 0
        case "CYCLES": return Int(truncatingIfNeeded: cycles)
        default: return nil
        }
    }

    public enum RegisterError: Error, CustomStringConvertible {
        case unknown(String)
        case notAtInstruction
        case noSuchCPU

        public var description: String {
            switch self {
            case .unknown(let name): "unknown register \(name)"
            case .notAtInstruction: "PC can only be set between instructions"
            case .noSuchCPU: "there's no second processor"
            }
        }
    }

    /// Sets a register or flag. PC can only be changed between
    /// instructions (the new instruction's opcode is fetched now).
    public func setRegister(_ name: String, cpu which: DebugCPU, to value: Int) throws(RegisterError) {
        if which == .parasite, let z = z80Processor {
            guard setZ80Register(name.uppercased(), z.cpu, value) else { throw .unknown(name) }
            rewinder?.keyframe()
            return
        }
        guard let c = debugCPU(which) else { throw .noSuchCPU }
        let byte = UInt8(truncatingIfNeeded: value)
        switch name.uppercased() {
        case "A": c.a = byte
        case "X": c.x = byte
        case "Y": c.y = byte
        case "S", "SP": c.s = byte
        case "P":
            c.n = byte & 0x80 != 0
            c.v = byte & 0x40 != 0
            c.d = byte & 0x08 != 0
            c.i = byte & 0x04 != 0
            c.z = byte & 0x02 != 0
            c.c = byte & 0x01 != 0
        case "C": c.c = value != 0
        case "Z": c.z = value != 0
        case "I": c.i = value != 0
        case "D": c.d = value != 0
        case "V": c.v = value != 0
        case "N": c.n = value != 0
        case "PC":
            guard c.isAboutToExecute else { throw .notAtInstruction }
            c.jump(to: UInt16(truncatingIfNeeded: value))
            // The fetch already happened this cycle: do it again.
            c.dbus = codeRead(which, Int(c.abus)) ?? 0xFF
        default:
            throw .unknown(name)
        }
        rewinder?.keyframe()
    }

    private static let z80Flags: [String: UInt8] = ["SF": Z80.flagS, "ZF": Z80.flagZ, "HF": Z80.flagH, "PF": Z80.flagPV,
                                                     "VF": Z80.flagPV, "NF": Z80.flagN, "CF": Z80.flagC]

    private func z80Register(_ name: String, _ c: Z80) -> Int? {
        switch name {
        case "A": Int(c.a)
        case "F": Int(c.f)
        case "B": Int(c.b)
        case "C": Int(c.c)
        case "D": Int(c.d)
        case "E": Int(c.e)
        case "H": Int(c.h)
        case "L": Int(c.l)
        case "AF": Int(c.af)
        case "BC": Int(c.bc)
        case "DE": Int(c.de)
        case "HL": Int(c.hl)
        case "IX": Int(c.ix)
        case "IY": Int(c.iy)
        case "IXH": Int(c.ix >> 8)
        case "IXL": Int(c.ix & 0xFF)
        case "IYH": Int(c.iy >> 8)
        case "IYL": Int(c.iy & 0xFF)
        case "SP": Int(c.sp)
        case "PC": Int(c.pc)
        case "AF'": Int(c.afPrime)
        case "BC'": Int(c.bcPrime)
        case "DE'": Int(c.dePrime)
        case "HL'": Int(c.hlPrime)
        case "I": Int(c.i)
        case "R": Int(c.r)
        case "IM": Int(c.im)
        case "IFF1": c.iff1 ? 1 : 0
        case "IFF2": c.iff2 ? 1 : 0
        case "CYCLES": Int(truncatingIfNeeded: cycles)
        default: Self.z80Flags[name].map { c.f & $0 != 0 ? 1 : 0 }
        }
    }

    private func setZ80Register(_ name: String, _ c: Z80, _ value: Int) -> Bool {
        let byte = UInt8(truncatingIfNeeded: value)
        let word = UInt16(truncatingIfNeeded: value)
        switch name {
        case "A": c.a = byte
        case "F": c.f = byte
        case "B": c.b = byte
        case "C": c.c = byte
        case "D": c.d = byte
        case "E": c.e = byte
        case "H": c.h = byte
        case "L": c.l = byte
        case "AF": c.a = UInt8(word >> 8); c.f = UInt8(word & 0xFF)
        case "BC": c.b = UInt8(word >> 8); c.c = UInt8(word & 0xFF)
        case "DE": c.d = UInt8(word >> 8); c.e = UInt8(word & 0xFF)
        case "HL": c.h = UInt8(word >> 8); c.l = UInt8(word & 0xFF)
        case "IX": c.ix = word
        case "IY": c.iy = word
        case "IXH": c.ix = c.ix & 0xFF | UInt16(byte) << 8
        case "IXL": c.ix = c.ix & 0xFF00 | UInt16(byte)
        case "IYH": c.iy = c.iy & 0xFF | UInt16(byte) << 8
        case "IYL": c.iy = c.iy & 0xFF00 | UInt16(byte)
        case "SP": c.sp = word
        case "PC": c.pc = word; c.halted = false
        case "AF'": c.afPrime = word
        case "BC'": c.bcPrime = word
        case "DE'": c.dePrime = word
        case "HL'": c.hlPrime = word
        case "I": c.i = byte
        case "R": c.r = byte
        case "IM": c.im = min(byte, 2)
        case "IFF1": c.iff1 = value != 0
        case "IFF2": c.iff2 = value != 0
        default:
            guard let mask = Self.z80Flags[name] else { return false }
            c.f = value != 0 ? c.f | mask : c.f & ~mask
        }
        return true
    }

    /// The disassembler for a CPU.
    public func disassembler(_ which: DebugCPU) -> any InstructionDisassembler {
        if debugCPUKind(which) == .z80 {
            return Z80Disassembler()
        }
        return M6502Disassembler(variant: debugCPU(which)?.variant ?? .nmos)
    }

    /// Whether the debugger has stopped the machine.
    public var isStoppedByDebugger: Bool {
        debuggerIfCreated?.stopReason != nil
    }
}

/// Where a cell of the TV picture came from.
public struct VideoSource: Sendable, Equatable {
    /// The screen memory address read for it.
    public var address: UInt16
    /// The CRTC's raster within the character row.
    public var raster: UInt8
    /// In the display area (not border or blanking).
    public var display: Bool
    public var teletext: Bool

    /// Decodes a TV metadata word; nil if nothing was recorded there.
    public init?(metadata: UInt32) {
        guard metadata & 0x2000_0000 != 0 else { return nil }
        address = UInt16(truncatingIfNeeded: metadata)
        raster = UInt8(truncatingIfNeeded: metadata >> 16)
        display = metadata & 0x8000_0000 != 0
        teletext = metadata & 0x4000_0000 != 0
    }
}

extension BBCMicro {
    @inline(__always)
    static func videoMetadata(address: UInt16, raster: UInt8, display: Bool, teletext: Bool) -> UInt32 {
        UInt32(address) | UInt32(raster & 0x1F) << 16 | 0x2000_0000
            | (display ? 0x8000_0000 : 0) | (teletext ? 0x4000_0000 : 0)
    }
}
