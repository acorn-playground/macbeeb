// The Acorn ARM Second Processor (the ARM Evaluation System): an 8MHz ARM1
// with 4MB of RAM, talking to the host through the Tube.
//
// Mapped as BeebEm has it (Arm.cpp): RAM in the bottom 16MB (4MB, repeated),
// the Tube's parasite-side registers at &1000000-&100001F (register n at
// &1000000 + 4n, byte accesses only: word reads give &FF and word writes
// are dropped, as BeebEm), and the 16K ROM at &3000000. At reset the ROM is
// copied into the bottom of RAM, where it runs. The Tube's R1/R4
// interrupts are IRQ, its NMI is FIQ. Anything else aborts.

#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

public final class ARMSecondProcessor: ARMBus {
    public static let ramSize = 0x40_0000
    public static let romSize = 0x4000
    /// Save states keep RAM in pages, and reuse the unchanged ones.
    static let pageSize = 0x4000
    static let pageCount = ramSize / pageSize

    public private(set) lazy var cpu = ARM<ARMSecondProcessor>(bus: self)
    /// `cpu`, for the hot path (no lazy check or retain).
    private var cpuReference: Unmanaged<ARM<ARMSecondProcessor>>!
    let ram: UnsafeMutablePointer<UInt8>
    let rom: [UInt8]
    /// Pages written since the last save state, and that state's pages.
    let dirty: UnsafeMutablePointer<Bool>
    var savedPages: [Data] = []
    /// Cycles owed: 4 more each host cycle (8MHz).
    var debt = 0
    /// True while the Tube holds the processor in reset.
    var heldInReset = false
    /// Set when the ARM touches the Tube, so its interrupt lines are looked
    /// at again. (Otherwise they only change between host cycles.)
    var tubeTouched = false
    unowned(unsafe) let machine: BBCMicro

    init(rom romImage: [UInt8], machine: BBCMicro) {
        precondition(romImage.count <= Self.romSize, "ARM ROM too big")
        rom = romImage + [UInt8](repeating: 0, count: Self.romSize - romImage.count)
        ram = .allocate(capacity: Self.ramSize)
        ram.initialize(repeating: 0, count: Self.ramSize)
        dirty = .allocate(capacity: Self.pageCount)
        dirty.initialize(repeating: true, count: Self.pageCount)
        self.machine = machine
        cpuReference = .passUnretained(cpu)
        reset()
    }

    deinit {
        ram.deallocate()
        dirty.deallocate()
    }

    /// As BeebEm: the ROM copied to RAM at 0, the CPU reset.
    func reset() {
        rom.withUnsafeBufferPointer { ram.update(from: $0.baseAddress!, count: Self.romSize) }
        for page in 0..<Self.romSize / Self.pageSize { dirty[page] = true }
        cpu.reset()
        debt = 0
    }

    /// A byte as the ARM would read it, without side effects.
    public func peek(_ address: UInt32) -> UInt8 {
        switch address {
        case ..<0x100_0000: ram[Int(address) & (Self.ramSize - 1)]
        case 0x300_0000..<0x300_4000: rom[Int(address) & (Self.romSize - 1)]
        default: 0xFF
        }
    }

    /// A word as the ARM would read it, without side effects.
    public func peekWord(_ address: UInt32) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(peek((address & ~3) &+ UInt32($1))) << ($1 * 8) }
    }

    // MARK: ARMBus

    @inline(__always)
    public func readWord(_ address: UInt32) -> UInt32 {
        if address < 0x100_0000 {
            return UInt32(littleEndian: UnsafeRawPointer(ram + Int(address) & (Self.ramSize - 4)).load(as: UInt32.self))
        }
        if address & ~0x1F == 0x100_0000 { return 0xFF }
        if address & ~UInt32(Self.romSize - 1) == 0x300_0000 {
            return rom.withUnsafeBytes { UInt32(littleEndian: $0.load(fromByteOffset: Int(address) & (Self.romSize - 4), as: UInt32.self)) }
        }
        cpuReference._withUnsafeGuaranteedRef { $0.abort() }
        return 0xFF
    }

    @inline(__always)
    public func fetch(_ address: UInt32) -> UInt32 {
        readWord(address)
    }

    public func readByte(_ address: UInt32) -> UInt8 {
        if address < 0x100_0000 { return ram[Int(address) & (Self.ramSize - 1)] }
        if address & ~0x1F == 0x100_0000 {
            tubeTouched = true
            return machine.tube.parasiteRead(Int(address >> 2) & 7)
        }
        if address & ~UInt32(Self.romSize - 1) == 0x300_0000 { return rom[Int(address) & (Self.romSize - 1)] }
        cpuReference._withUnsafeGuaranteedRef { $0.abort() }
        return 0xFF
    }

    @inline(__always)
    public func writeWord(_ address: UInt32, _ value: UInt32) {
        if address < 0x100_0000 {
            let offset = Int(address) & (Self.ramSize - 4)
            UnsafeMutableRawPointer(ram + offset).storeBytes(of: value.littleEndian, as: UInt32.self)
            dirty[offset / Self.pageSize] = true
        } else if address & ~0x1F != 0x100_0000 {
            cpuReference._withUnsafeGuaranteedRef { $0.abort() }
        }
    }

    public func writeByte(_ address: UInt32, _ value: UInt8) {
        if address < 0x100_0000 {
            let offset = Int(address) & (Self.ramSize - 1)
            ram[offset] = value
            dirty[offset / Self.pageSize] = true
        } else if address & ~0x1F == 0x100_0000 {
            tubeTouched = true
            machine.tube.parasiteWrite(Int(address >> 2) & 7, value)
        } else {
            cpuReference._withUnsafeGuaranteedRef { $0.abort() }
        }
    }

    /// Runs the cycles one host cycle owes (4, at 8MHz).
    @inline(__always)
    func step() {
        debt += 4
        guard syncTube() else { return }
        cpuReference._withUnsafeGuaranteedRef { cpu in
            while debt > 0 {
                debt -= cpu.step()
                if tubeTouched {
                    tubeTouched = false
                    guard syncTube() else { return }
                }
            }
        }
    }

    /// Acts on the Tube's reset bits and passes its interrupts on. Returns
    /// false while the ARM is held in reset.
    @inline(__always)
    func syncTube() -> Bool {
        if machine.tube.tubeResetRequested {
            machine.tube.reset()
        }
        if machine.tube.parasiteResetRequested {
            // Held in reset: once is enough.
            if !heldInReset {
                reset()
                heldInReset = true
            }
            debt = 0
            return false
        }
        heldInReset = false
        let irq = machine.tube.parasiteIRQ, fiq = machine.tube.parasiteNMI
        cpuReference._withUnsafeGuaranteedRef { cpu in
            cpu.irq = irq
            cpu.fiq = fiq
        }
        return true
    }

    // MARK: State

    struct State: Codable, Sendable {
        var registers: [UInt32]
        var mode: ARMMode
        var n, z, c, v, irqDisabled, fiqDisabled, irq, fiq: Bool
        /// RAM in 16K pages.
        var ram: [Data]
        var debt: Int
        var heldInReset: Bool
    }

    var state: State {
        if savedPages.count != Self.pageCount {
            savedPages = (0..<Self.pageCount).map { _ in Data() }
        }
        for page in 0..<Self.pageCount where dirty[page] {
            savedPages[page] = Data(bytes: ram + page * Self.pageSize, count: Self.pageSize)
            dirty[page] = false
        }
        let c = cpu
        return State(registers: (0..<ARM<ARMSecondProcessor>.registerCount).map { c.regs[$0] }, mode: c.mode,
                     n: c.n, z: c.z, c: c.c, v: c.v, irqDisabled: c.irqDisabled, fiqDisabled: c.fiqDisabled,
                     irq: c.irq, fiq: c.fiq, ram: savedPages, debt: debt, heldInReset: heldInReset)
    }

    func restore(_ s: State) {
        let c = cpu
        for (i, value) in s.registers.prefix(ARM<ARMSecondProcessor>.registerCount).enumerated() { c.regs[i] = value }
        c.mode = s.mode
        c.n = s.n; c.z = s.z; c.c = s.c; c.v = s.v
        c.irqDisabled = s.irqDisabled; c.fiqDisabled = s.fiqDisabled
        c.irq = s.irq; c.fiq = s.fiq
        for (page, data) in s.ram.prefix(Self.pageCount).enumerated() where data.count == Self.pageSize {
            data.withUnsafeBytes { ram.advanced(by: page * Self.pageSize).update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: Self.pageSize) }
        }
        savedPages = s.ram.count == Self.pageCount ? s.ram : []
        dirty.update(repeating: savedPages.isEmpty, count: Self.pageCount)
        debt = s.debt
        heldInReset = s.heldInReset
    }
}
