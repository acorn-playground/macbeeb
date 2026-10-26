// The Acorn Master 512 co-processor: an 80186 with its own RAM and a 16K
// BIOS ROM, talking to a Master 128 through the Tube, for DOS Plus and GEM.
//
// Wired as BeebEm has it (Master512CoPro.cpp, Copyright (C) 2020 Chris
// Needham, Carl and MAME contributors, BSD-3-Clause):
//
// - Memory: a flat 1MB. &00000-&EFFFF is RAM (BeebEm's help calls it 1MB);
//   &F0000-&FFFFF is the BIOS, its 16K repeated four times, and ignores
//   writes. The CPU starts at F000:FFF0.
// - Tube: I/O ports &80-&8F, the parasite register being (port - &80) / 2
//   (so each register appears at an even and an odd port). Other ports read
//   &FF.
// - Interrupts: the Tube's parasite IRQ (R1 and R4) is the 80186's INT0,
//   which its interrupt controller presents as type 12. BeebEm doesn't
//   model the interrupt controller (no masking, priorities or EOI), the
//   timers or the chip selects, so neither does this.
// - DMA: the Tube's parasite NMI (R3, for disc transfers) is wired to DMA
//   channel 0's request, not to the CPU's NMI. As in BeebEm, only that
//   channel's source and destination pointers are modelled (written at
//   ports &FFC0-&FFC6, the default peripheral control block); while the
//   request is asserted one byte moves after each instruction: from the
//   Tube to memory if the source is an I/O port (below &100), otherwise
//   from memory to the Tube. The pointer on the memory side counts up.
// - Clock: 8MHz (BeebEm's figure; the real board runs at 10MHz), so 4
//   clocks for each 2MHz host cycle.
// - Reset: power on and Break reset the CPU, clear RAM and reload the BIOS
//   (as BeebEm's Reset). The Tube's P bit holds the CPU in reset (as on the
//   real board; BeebEm ignores it), leaving memory alone.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public final class Master512: I80186Bus {
    public private(set) lazy var cpu = I80186(bus: self)
    /// 1MB: RAM below `romBase`, the BIOS (repeated) above.
    let memory: UnsafeMutablePointer<UInt8>
    /// 64K: the BIOS image repeated to fill the top segment.
    let rom: [UInt8]
    /// Clocks owed: 4 more each host cycle.
    var debt = 0
    unowned(unsafe) let machine: BBCMicro

    public static let memorySize = 0x100000
    public static let romBase = 0xF0000
    /// 80186 clocks per 2MHz host cycle.
    public static let clocksPerHostCycle = 4
    /// The interrupt type of INT0 (the Tube's parasite IRQ).
    public static let tubeInterruptType: UInt8 = 12

    /// DMA channel 0, as BeebEm models it.
    public struct DMAChannel: Codable, Sendable, Equatable {
        public var source: UInt32 = 0
        public var destination: UInt32 = 0
        public var count: UInt16 = 0
        public var control: UInt16 = 0
    }

    public internal(set) var dma = DMAChannel()

    init(rom romImage: [UInt8], machine: BBCMicro) {
        precondition(!romImage.isEmpty && romImage.count <= 0x10000 && 0x10000 % romImage.count == 0,
                     "the Master 512 BIOS must divide 64K")
        var top = [UInt8]()
        while top.count < 0x10000 { top += romImage }
        rom = top
        memory = .allocate(capacity: Master512.memorySize)
        memory.initialize(repeating: 0, count: Master512.memorySize)
        self.machine = machine
        reset()
    }

    deinit {
        memory.deallocate()
    }

    /// Power on or Break (BeebEm's Reset): RAM cleared, the BIOS reloaded,
    /// the CPU at F000:FFF0 with every register zero.
    func reset() {
        memory.update(repeating: 0, count: Master512.romBase)
        rom.withUnsafeBufferPointer {
            (memory + Master512.romBase).update(from: $0.baseAddress!, count: 0x10000)
        }
        resetCPU()
        cpu.ax = 0; cpu.bx = 0; cpu.cx = 0; cpu.dx = 0
        cpu.sp = 0; cpu.bp = 0; cpu.si = 0; cpu.di = 0
        dma = DMAChannel()
        debt = 0
    }

    /// The CPU's reset input, leaving memory alone.
    func resetCPU() {
        cpu.reset()
        cpu.cs = 0xF000
        cpu.ip = 0xFFF0
        cpu.intr = false
        cpu.nmiLine = false
        cpu.interruptType = Master512.tubeInterruptType
    }

    /// Reads memory without side effects.
    public func peek(_ address: Int) -> UInt8 {
        memory[address & 0xFFFFF]
    }

    public func poke(_ address: Int, _ value: UInt8) {
        let address = address & 0xFFFFF
        if address < Master512.romBase {
            memory[address] = value
        }
    }

    // MARK: I80186Bus

    public func read(_ address: Int) -> UInt8 {
        memory[address]
    }

    public func write(_ address: Int, _ value: UInt8) {
        if address < Master512.romBase {
            memory[address] = value
        }
    }

    public func input(_ port: UInt16) -> UInt8 {
        if port & 0xFFF0 == 0x80 {
            return machine.tube.parasiteRead(Int(port - 0x80) >> 1)
        }
        return 0xFF
    }

    public func output(_ port: UInt16, _ value: UInt8) {
        switch port {
        case 0x80...0x8F:
            machine.tube.parasiteWrite(Int(port - 0x80) >> 1, value)
        case 0xFFC0...0xFFCB:
            writeDMA(Int(port - 0xFFC0), value)
        default:
            break
        }
    }

    /// DMA channel 0's registers in the peripheral control block, a byte at
    /// a time: source (low, high, upper 4 bits), destination, count,
    /// control.
    func writeDMA(_ offset: Int, _ value: UInt8) {
        let v = UInt32(value)
        switch offset {
        case 0x0: dma.source = (dma.source & 0xFFF00) | v
        case 0x1: dma.source = (dma.source & 0xF00FF) | v << 8
        case 0x2: dma.source = (dma.source & 0x0FFFF) | (v & 0x0F) << 16
        case 0x4: dma.destination = (dma.destination & 0xFFF00) | v
        case 0x5: dma.destination = (dma.destination & 0xF00FF) | v << 8
        case 0x6: dma.destination = (dma.destination & 0x0FFFF) | (v & 0x0F) << 16
        case 0x8: dma.count = (dma.count & 0xFF00) | UInt16(value)
        case 0x9: dma.count = (dma.count & 0x00FF) | UInt16(value) << 8
        case 0xA: dma.control = (dma.control & 0xFF00) | UInt16(value)
        case 0xB: dma.control = (dma.control & 0x00FF) | UInt16(value) << 8
        default: break
        }
    }

    /// One DMA transfer, for the Tube's request (BeebEm's DoDMA).
    func transferDMA() {
        if dma.source < 0x100 {
            write(Int(dma.destination & 0xFFFFF), input(UInt16(dma.source)))
            dma.destination = (dma.destination &+ 1) & 0xFFFFF
        } else {
            output(UInt16(truncatingIfNeeded: dma.destination), read(Int(dma.source & 0xFFFFF)))
            dma.source = (dma.source &+ 1) & 0xFFFFF
        }
    }

    /// Runs the clocks one host cycle owes (4, at 8MHz), an instruction at
    /// a time.
    @inline(__always)
    func step() {
        debt += Master512.clocksPerHostCycle
        while debt > 0 {
            if machine.tube.tubeResetRequested {
                machine.tube.reset()
            }
            if machine.tube.parasiteResetRequested {
                // Held in reset.
                resetCPU()
                debt = 0
                return
            }
            cpu.intr = machine.tube.parasiteIRQ
            if cpu.halted && !(cpu.intr && cpu.flags & I80186.flagI != 0) {
                debt = 0
                return
            }
            debt -= cpu.step()
            if machine.tube.parasiteNMI && !cpu.halted {
                transferDMA()
            }
        }
    }

    // MARK: State

    struct State: Codable, Sendable {
        var ax, bx, cx, dx, sp, bp, si, di, es, cs, ss, ds, ip, flags: UInt16
        var halted, intr, nmiPending, nmiLine, interruptShadow, repeating, escapeTrap: Bool
        /// The RAM, LZ4 compressed: it's 960K, and rewind keeps hundreds of
        /// these.
        var memory: Data
        var dma: DMAChannel
        var debt: Int
    }

    var state: State {
        let c = cpu
        return State(ax: c.ax, bx: c.bx, cx: c.cx, dx: c.dx, sp: c.sp, bp: c.bp, si: c.si, di: c.di,
                     es: c.es, cs: c.cs, ss: c.ss, ds: c.ds, ip: c.ip, flags: c.flags,
                     halted: c.halted, intr: c.intr, nmiPending: c.nmiPending, nmiLine: c.nmiLine,
                     interruptShadow: c.interruptShadow, repeating: c.repeating, escapeTrap: c.escapeTrap,
                     memory: Self.compress(Data(bytes: memory, count: Master512.romBase)), dma: dma, debt: debt)
    }

    func restore(_ s: State) {
        let c = cpu
        c.ax = s.ax; c.bx = s.bx; c.cx = s.cx; c.dx = s.dx
        c.sp = s.sp; c.bp = s.bp; c.si = s.si; c.di = s.di
        c.es = s.es; c.cs = s.cs; c.ss = s.ss; c.ds = s.ds; c.ip = s.ip; c.flags = s.flags
        c.halted = s.halted; c.intr = s.intr; c.nmiPending = s.nmiPending; c.nmiLine = s.nmiLine
        c.interruptShadow = s.interruptShadow; c.repeating = s.repeating; c.escapeTrap = s.escapeTrap
        c.interruptType = Master512.tubeInterruptType
        let ram = Self.decompress(s.memory)
        ram.withUnsafeBytes {
            memory.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: min(ram.count, Master512.romBase))
        }
        dma = s.dma
        debt = s.debt
    }

    /// (Stored as it is where there's no Compression framework.)
    static func compress(_ data: Data) -> Data {
        #if canImport(Darwin)
        (try? (data as NSData).compressed(using: .lz4) as Data) ?? data
        #else
        data
        #endif
    }

    /// Uncompressed RAM (from an older state, or saved without the
    /// Compression framework) is taken as it is.
    static func decompress(_ data: Data) -> Data {
        guard data.count != Master512.romBase else { return data }
        #if canImport(Darwin)
        return (try? (data as NSData).decompressed(using: .lz4) as Data) ?? data
        #else
        return LZ4.decompress(data) ?? data
        #endif
    }
}
