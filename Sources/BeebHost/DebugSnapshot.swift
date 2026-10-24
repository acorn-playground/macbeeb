import BeebCore

/// What a debugger front end wants to see.
public struct DebugView: Sendable, Equatable {
    public var cpu: DebugCPU = .host
    /// Where the disassembly starts; nil follows the PC.
    public var disassemblyStart: UInt16?
    public var disassemblyLines = 48
    public var memorySpace: MemorySpace = .cpu(.host)
    public var memoryAddress = 0
    public var memoryLength = 512
    public var traceCount = 200
    /// Show the BASIC program (and gather `DebugSnapshot.basic`).
    public var basic = false
    /// BASIC arrays to show the elements of, by name (e.g. "grid%(").
    public var basicExpanded: Set<String> = []
    /// BASIC expressions to show the values of.
    public var basicWatches: [String] = []

    public init() {}
}

/// Everything a debugger front end shows, gathered on the emulation thread
/// in one go.
public struct DebugSnapshot: Sendable {
    public struct CPUState: Sendable, Equatable {
        public var cpu: DebugCPU
        public var kind: DebugCPUKind
        public var registers: [DebugRegister]
        public var flags: [DebugFlag]
        public var pc: UInt16
        public var atInstruction: Bool

        public func register(_ name: String) -> Int? {
            registers.first { $0.name == name }?.value
        }
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public var address: UInt16
        public var bytes: [UInt8]
        public var text: String
        public var isPC: Bool
        public var breakpoints: [Int]
        /// Labels at this address.
        public var labels: [String]
        public var source: SourceLocation?
        /// Share of the profile's cycles spent here, 0-1 (relative to the
        /// busiest instruction), if profiled.
        public var heat: Double?
        public var id: UInt16 { address }
    }

    public struct TraceLine: Sendable, Equatable, Identifiable {
        public var index: Int
        public var entry: TraceEntry
        public var text: String
        public var id: Int { index }
    }

    public var view: DebugView
    public var model: BBCMicro.Model
    public var stopReason: StopReason?
    public var isRunningCommand: Bool
    public var cycles: UInt64
    public var cpus: [CPUState]
    public var disassembly: [Line]
    public var memory: [UInt8?]
    /// The stack from S+1 up to &1FF (or a Z80's from SP; at most 48
    /// bytes).
    public var stack: [(address: UInt16, value: UInt8)]
    public var breakpoints: [Breakpoint]
    public var hardware: [HardwareSection]
    public var tracing: Bool
    public var trace: [TraceLine]
    public var log: [DebugLogEntry]
    public var regions: [MemoryRegion]
    public var profile: ProfileReport?
    public var isProfiling: Bool
    /// The BASIC program, if the view asks for it.
    public var basic: BasicDebugSnapshot?

    public var hasSecondProcessor: Bool { cpus.count > 1 }

    public func state(_ cpu: DebugCPU) -> CPUState? {
        cpus.first { $0.cpu == cpu }
    }

    public init(machine m: BBCMicro, view requested: DebugView) {
        var view = requested
        if !m.hasDebugCPU(view.cpu) {
            view.cpu = .host
        }
        self.view = view
        model = m.model
        let debugger = m.debugger
        stopReason = debugger.stopReason
        isRunningCommand = debugger.isRunningCommand
        cycles = m.cycles
        cpus = DebugCPU.allCases.compactMap { cpu in
            guard let kind = m.debugCPUKind(cpu) else { return nil }
            return CPUState(cpu: cpu, kind: kind, registers: m.registers(cpu), flags: m.flags(cpu),
                            pc: m.instructionAddress(cpu), atInstruction: m.isAtInstruction(cpu))
        }

        let cpu = view.cpu
        let pc = m.instructionAddress(cpu)
        let read = { (a: UInt16) in m.codeRead(cpu, Int(a)) ?? 0xFF }
        let disassembler = m.disassembler(cpu)
        // Instructions known to have run are reliable places to start.
        let known = Set(debugger.tracing ? debugger.trace(view.cpu).last(256).filter { !$0.interrupt }.map(\.pc) : [])
        let start = view.disassemblyStart ?? Self.start(before: pc, known: known, disassembler: disassembler, read: read)
        var address = start
        var lines: [Line] = []
        let executeBreakpoints = debugger.breakpoints.filter { $0.cpu == cpu && $0.kind.contains(.execute) }
        let symbols = debugger.symbols(cpu)
        for _ in 0..<view.disassemblyLines {
            let (text, length) = disassembler.disassemble(at: address, read: read)
            let bytes = (0..<length).map { read(address &+ UInt16($0)) }
            lines.append(Line(address: address, bytes: bytes, text: symbols.annotate(text), isPC: address == pc,
                              breakpoints: executeBreakpoints.filter { $0.start == address }.map(\.id),
                              labels: address < 0xFC00 || address >= 0xFF00 ? symbols.names(at: address) : [],
                              source: symbols.location(at: address), heat: nil))
            let next = address &+ UInt16(length)
            if next < address { break }
            address = next
        }
        disassembly = lines

        memory = (0..<view.memoryLength).map { m.debugRead(view.memorySpace, view.memoryAddress + $0) }
        stack = m.stackContents(cpu)
        breakpoints = debugger.breakpoints
        hardware = m.hardwareState
        tracing = debugger.tracing
        if tracing {
            let entries = debugger.trace(cpu).last(view.traceCount)
            trace = entries.enumerated().map { index, e in
                let text: String
                if e.interrupt {
                    text = "— interrupt —"
                } else {
                    text = disassembler.disassemble(at: e.pc) { e.byte(at: $0) }.text
                }
                return TraceLine(index: index, entry: e, text: text)
            }
        } else {
            trace = []
        }
        log = Array(debugger.log.suffix(200))
        regions = m.memoryRegions
        isProfiling = debugger.isProfiling
        basic = view.basic ? BasicDebugSnapshot(machine: m, view: view) : nil
        profile = debugger.profileReport(cpu, top: 30)
        if let profile, let busiest = profile.hottest.first?.cycles, busiest > 0 {
            for index in disassembly.indices {
                if let cycles = profile.cyclesByAddress[disassembly[index].address] {
                    disassembly[index].heat = Double(cycles) / Double(busiest)
                }
            }
        }
    }

    /// A disassembly start a few instructions before `pc` that lands on it:
    /// preferably one in `known` (addresses instructions ran from).
    static func start(before pc: UInt16, known: Set<UInt16> = [], disassembler: any InstructionDisassembler,
                      read: (UInt16) -> UInt8) -> UInt16 {
        func lands(from start: UInt16) -> Int? {
            var address = start
            var count = 0
            while address != pc && count < 30 {
                let next = address &+ UInt16(disassembler.disassemble(at: address, read: read).length)
                if next > pc && address < pc { return nil }
                address = next
                count += 1
            }
            return address == pc ? count : nil
        }
        for back in stride(from: 24, through: 1, by: -1) where known.contains(pc &- UInt16(back)) {
            if lands(from: pc &- UInt16(back)) != nil {
                return pc &- UInt16(back)
            }
        }
        for back in stride(from: 24, through: 1, by: -1) {
            var address = pc &- UInt16(back)
            var count = 0
            while address != pc && count < 30 {
                let length = disassembler.disassemble(at: address, read: read).length
                let next = address &+ UInt16(length)
                // Stepped over the PC: this start is out of step.
                if next > pc && address < pc { break }
                address = next
                count += 1
            }
            if address == pc && count >= 4 {
                return pc &- UInt16(back)
            }
        }
        return pc
    }
}
