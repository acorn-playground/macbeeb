// The Acorn Z80 Second Processor: a 6MHz Z80 with 64K of RAM, talking to
// the host through the Tube on its I/O ports, for CP/M.
//
// Wired as BeebEm has it (Z80Support.cpp): from reset the 4K client ROM is
// read in place of the low 32K (it copies itself to &F000 and runs there)
// until the first read at &8000 or above; writes always go to RAM. NMI pages
// the ROM back in for its handler at &0066. Ports 0-7 are the Tube's
// parasite-side registers; its R1/R4 interrupts are INT, its NMI is NMI.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public final class Z80SecondProcessor: Z80Bus {
    public private(set) lazy var cpu = Z80(bus: self)
    let ram: UnsafeMutablePointer<UInt8>
    /// 8K, the ROM in the first 4K (as BeebEm).
    let rom: [UInt8]
    public internal(set) var inROM = true
    /// T-states owed: 3 more each host cycle.
    var debt = 0
    unowned(unsafe) let machine: BBCMicro
    /// Set while the debugger wants to see every instruction and access.
    unowned(unsafe) var debugger: Debugger?
    /// The host cycle `step()` last ran in, and the instructions (or
    /// interrupts) it ran: where in history the Z80 is.
    var stepCycle: UInt64 = 0
    var executed = 0
    /// True if the last `step()` stopped early, for the debugger.
    var stoppedEarly = false

    init(rom romImage: [UInt8], machine: BBCMicro) {
        precondition(romImage.count <= 8192, "Z80 ROM too big")
        rom = romImage + [UInt8](repeating: 0, count: 8192 - romImage.count)
        ram = .allocate(capacity: 0x10000)
        ram.initialize(repeating: 0, count: 0x10000)
        self.machine = machine
        reset()
    }

    deinit {
        ram.deallocate()
    }

    /// As the Tube's reset (BeebEm's Z80Init): the ROM in, registers zero.
    func reset() {
        cpu.reset()
        cpu.a = 0; cpu.f = 0; cpu.b = 0; cpu.c = 0; cpu.d = 0; cpu.e = 0; cpu.h = 0; cpu.l = 0
        cpu.sp = 0; cpu.ix = 0; cpu.iy = 0
        cpu.afPrime = 0; cpu.bcPrime = 0; cpu.dePrime = 0; cpu.hlPrime = 0
        // The ROM sets IM 2 with I = &FF; BeebEm's vector is always at &FFFE.
        cpu.interruptDataBus = 0xFE
        inROM = true
    }

    public func peek(_ address: UInt16) -> UInt8 {
        inROM && address < 0x8000 ? rom[Int(address & 0x1FFF)] : ram[Int(address)]
    }

    // MARK: Z80Bus

    @inline(__always)
    func memoryRead(_ address: UInt16) -> UInt8 {
        if address >= 0x8000 {
            inROM = false
        }
        return inROM ? rom[Int(address & 0x1FFF)] : ram[Int(address)]
    }

    public func read(_ address: UInt16) -> UInt8 {
        debugger?.z80Accessed(address, write: false)
        return memoryRead(address)
    }

    public func fetchOpcode(_ address: UInt16) -> UInt8 {
        memoryRead(address)
    }

    public func fetchOperand(_ address: UInt16) -> UInt8 {
        memoryRead(address)
    }

    public func write(_ address: UInt16, _ value: UInt8) {
        debugger?.z80Accessed(address, write: true)
        ram[Int(address)] = value
    }

    public func input(_ port: UInt16) -> UInt8 {
        port & 0xFF < 8 ? machine.tube.parasiteRead(Int(port & 7)) : 0
    }

    public func output(_ port: UInt16, _ value: UInt8) {
        if port & 0xFF < 8 {
            machine.tube.parasiteWrite(Int(port & 7), value)
        }
    }

    /// Runs the T-states one host cycle owes (3, at 6MHz), an instruction at
    /// a time. A debugger stop can leave some owed until the next.
    @inline(__always)
    func step() {
        debt += 3
        stepCycle = machine.cycles
        executed = 0
        stoppedEarly = false
        while debt > 0 {
            if debugger != nil && machine.stopRequested {
                stoppedEarly = true
                return
            }
            if machine.tube.tubeResetRequested {
                machine.tube.reset()
            }
            if machine.tube.parasiteResetRequested {
                reset()
            }
            cpu.irq = machine.tube.parasiteIRQ
            cpu.setNMI(machine.tube.parasiteNMI)
            // This step takes the NMI: its handler is in the ROM.
            if cpu.nmiPending {
                inROM = true
            }
            if let debugger {
                // It's about to run: stop before it?
                if debugger.z80WillStep(self) {
                    stoppedEarly = true
                    return
                }
                let pc = cpu.pc
                let tStates = cpu.step()
                debugger.z80Stepped(pc: pc, tStates: tStates)
                debt -= tStates
            } else {
                debt -= cpu.step()
            }
            executed += 1
        }
    }

    /// Whether the next step takes an interrupt.
    var interruptNext: Bool {
        cpu.nmiPending || (cpu.irq && cpu.iff1 && !cpu.eiDelay)
    }

    /// Where the Z80 is in history: the host cycle, and the instructions
    /// run in it.
    var position: (cycle: UInt64, executed: Int) {
        stoppedEarly ? (stepCycle, executed) : (machine.cycles, 0)
    }

    // MARK: State

    struct State: Codable, Sendable {
        var a, f, b, c, d, e, h, l: UInt8
        var afPrime, bcPrime, dePrime, hlPrime, ix, iy, sp, pc, wz: UInt16
        var i, r, im, q, interruptDataBus: UInt8
        var iff1, iff2, halted, eiDelay, afterLDAIR, nmiPending, nmiLine, irq: Bool
        var ram: Data
        var inROM: Bool
        var debt: Int
    }

    var state: State {
        let c = cpu
        return State(a: c.a, f: c.f, b: c.b, c: c.c, d: c.d, e: c.e, h: c.h, l: c.l,
                     afPrime: c.afPrime, bcPrime: c.bcPrime, dePrime: c.dePrime, hlPrime: c.hlPrime,
                     ix: c.ix, iy: c.iy, sp: c.sp, pc: c.pc, wz: c.wz,
                     i: c.i, r: c.r, im: c.im, q: c.q, interruptDataBus: c.interruptDataBus,
                     iff1: c.iff1, iff2: c.iff2, halted: c.halted, eiDelay: c.eiDelay, afterLDAIR: c.afterLDAIR,
                     nmiPending: c.nmiPending, nmiLine: c.nmiLine, irq: c.irq,
                     ram: Data(bytes: ram, count: 0x10000), inROM: inROM, debt: debt)
    }

    func restore(_ s: State) {
        let c = cpu
        c.a = s.a; c.f = s.f; c.b = s.b; c.c = s.c; c.d = s.d; c.e = s.e; c.h = s.h; c.l = s.l
        c.afPrime = s.afPrime; c.bcPrime = s.bcPrime; c.dePrime = s.dePrime; c.hlPrime = s.hlPrime
        c.ix = s.ix; c.iy = s.iy; c.sp = s.sp; c.pc = s.pc; c.wz = s.wz
        c.i = s.i; c.r = s.r; c.im = s.im; c.q = s.q; c.interruptDataBus = s.interruptDataBus
        c.iff1 = s.iff1; c.iff2 = s.iff2; c.halted = s.halted; c.eiDelay = s.eiDelay; c.afterLDAIR = s.afterLDAIR
        c.nmiPending = s.nmiPending; c.nmiLine = s.nmiLine; c.irq = s.irq
        s.ram.withUnsafeBytes { ram.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: min(s.ram.count, 0x10000)) }
        inROM = s.inROM
        debt = s.debt
    }
}
