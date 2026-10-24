// Breakpoints, stepping and tracing, for the host CPU and the second
// processor.
//
// The machine calls in only while something is set (breakpoints, a step in
// progress, tracing), so an idle debugger costs one test per cycle. Stops
// happen on the exact cycle: for an execute breakpoint, the cycle the
// opcode is fetched, so the CPU is about to execute it; for a read or
// write, the cycle of the access, mid-instruction.
//
// A stop is sticky: the machine won't run again until `resume()`.

public enum DebugCPU: String, CaseIterable, Codable, Sendable {
    case host
    case parasite
}

public struct Breakpoint: Codable, Sendable, Equatable, Identifiable {
    public struct Kind: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let execute = Kind(rawValue: 1)
        public static let read = Kind(rawValue: 2)
        public static let write = Kind(rawValue: 4)
        public static let access: Kind = [.read, .write]
    }

    public var id: Int
    public var cpu: DebugCPU
    public var kind: Kind
    public var start: UInt16
    public var end: UInt16
    /// Host only: only while this sideways bank is paged in at &8000-&BFFF.
    public var romBank: Int?
    /// Only stop (or log) when this expression is true.
    public var condition: String?
    /// Only stop once hit this many times.
    public var hitTarget: Int?
    /// Log this (with {expression} replaced by its value) instead of
    /// stopping.
    public var logMessage: String?
    public var enabled = true
    public var hitCount = 0

    public init(id: Int = 0, cpu: DebugCPU = .host, kind: Kind = .execute, start: UInt16, end: UInt16? = nil,
                romBank: Int? = nil, condition: String? = nil, hitTarget: Int? = nil, logMessage: String? = nil) {
        self.id = id
        self.cpu = cpu
        self.kind = kind
        self.start = start
        self.end = end ?? start
        self.romBank = romBank
        self.condition = condition
        self.hitTarget = hitTarget
        self.logMessage = logMessage
    }

    func covers(_ address: UInt16) -> Bool {
        start <= end ? (start...end).contains(address) : address >= start || address <= end
    }
}

public enum StopReason: Equatable, Sendable, CustomStringConvertible {
    case breakpoint(id: Int, cpu: DebugCPU, address: UInt16, kind: Breakpoint.Kind)
    /// A step finished.
    case stepped(DebugCPU)
    case frame
    case scanline
    /// An interrupt (or reset) sequence is about to start.
    case interrupt(DebugCPU)
    /// Stopped on request (e.g. Pause in the debugger).
    case requested
    /// Went back as far as the rewind history goes.
    case historyStart
    /// A BASIC program reached a line with a breakpoint.
    case basicBreakpoint(id: Int, cpu: DebugCPU, line: Int)
    /// A BASIC step finished.
    case basicStepped(DebugCPU)
    /// A BASIC program hit an error (`BasicDebugger.error` has it).
    case basicError(cpu: DebugCPU, number: Int)

    public var description: String {
        switch self {
        case .breakpoint(let id, let cpu, let address, let kind):
            let what = kind == .execute ? "execute" : kind == .read ? "read" : "write"
            return "breakpoint \(id) (\(what) &\(Self.hex(address))) on the \(cpu.rawValue)"
        case .stepped(let cpu): return "step finished on the \(cpu.rawValue)"
        case .frame: return "start of frame"
        case .scanline: return "start of scanline"
        case .interrupt(let cpu): return "interrupt on the \(cpu.rawValue)"
        case .requested: return "stopped"
        case .historyStart: return "reached the start of the rewind history"
        case .basicBreakpoint(let id, let cpu, let line):
            return "BASIC breakpoint \(id) (line \(line))" + (cpu == .parasite ? " on the parasite" : "")
        case .basicStepped(let cpu): return "BASIC step finished" + (cpu == .parasite ? " on the parasite" : "")
        case .basicError(let cpu, let number):
            return "BASIC error \(number)" + (cpu == .parasite ? " on the parasite" : "")
        }
    }

    /// A stop in a BASIC program.
    public var isBasic: Bool {
        switch self {
        case .basicBreakpoint, .basicStepped, .basicError: true
        default: false
        }
    }

    static func hex(_ value: UInt16) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}

/// What the debugger can do with the machine.
public enum RunCommand: Equatable, Sendable {
    /// Run until a breakpoint (or the time limit).
    case `continue`
    /// To the next instruction.
    case stepInstruction
    /// Over a JSR (to the instruction after it); otherwise as
    /// `stepInstruction`.
    case stepOver
    /// Until the current subroutine (or interrupt handler) returns.
    case stepOut
    /// One 2MHz host cycle.
    case stepCycle
    case runToAddress(UInt16)
    case nextScanline
    case nextFrame
    case nextInterrupt
}

public struct TraceEntry: Sendable, Equatable {
    /// A Z80's registers (where a 6502 has A X Y S P).
    public struct Z80Registers: Sendable, Equatable {
        public var af, bc, de, hl, ix, iy, sp: UInt16
    }

    public var cycle: UInt64
    public var pc: UInt16
    public var a: UInt8
    public var x: UInt8
    public var y: UInt8
    public var s: UInt8
    public var p: UInt8
    /// The instruction's bytes when it ran (up to 4 for a Z80).
    public var bytes: (UInt8, UInt8, UInt8, UInt8)
    /// True for an interrupt starting (the fetch at `pc` was discarded).
    public var interrupt: Bool
    /// Set for a Z80 (and A X Y S P aren't).
    public var z80: Z80Registers?

    /// The registers, e.g. "A=&12 X=&34 Y=&56 S=&F0 nv-bdIzc".
    public var registerText: String {
        func hex(_ v: Int, _ digits: Int) -> String {
            let s = String(v, radix: 16, uppercase: true)
            return "&" + String(repeating: "0", count: max(0, digits - s.count)) + s
        }
        if let z = z80 {
            return "AF=\(hex(Int(z.af), 4)) BC=\(hex(Int(z.bc), 4)) DE=\(hex(Int(z.de), 4)) HL=\(hex(Int(z.hl), 4)) "
                + "IX=\(hex(Int(z.ix), 4)) IY=\(hex(Int(z.iy), 4)) SP=\(hex(Int(z.sp), 4))"
        }
        let flags = zip("NV-BDIZC", (0..<8).reversed()).map { ch, bit in p & 1 << bit != 0 ? ch : Character(ch.lowercased()) }
        return "A=\(hex(Int(a), 2)) X=\(hex(Int(x), 2)) Y=\(hex(Int(y), 2)) S=\(hex(Int(s), 2)) \(String(flags))"
    }

    /// The instruction's bytes, for disassembling it.
    public func byte(at address: UInt16) -> UInt8 {
        switch Int(address &- pc) % 4 {
        case 0: bytes.0
        case 1: bytes.1
        case 2: bytes.2
        default: bytes.3
        }
    }

    public static func == (l: TraceEntry, r: TraceEntry) -> Bool {
        l.cycle == r.cycle && l.pc == r.pc && l.a == r.a && l.x == r.x && l.y == r.y && l.s == r.s && l.p == r.p
            && l.bytes == r.bytes && l.interrupt == r.interrupt && l.z80 == r.z80
    }
}

/// The last `capacity` instructions.
public struct TraceBuffer: Sendable {
    public let capacity: Int
    private var entries: [TraceEntry] = []
    private var next = 0

    public init(capacity: Int) {
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    mutating func append(_ entry: TraceEntry) {
        if entries.count < capacity {
            entries.append(entry)
        } else {
            entries[next] = entry
        }
        next = (next + 1) % capacity
    }

    /// The newest `count` entries, oldest first.
    public func last(_ count: Int) -> [TraceEntry] {
        let n = min(count, entries.count)
        if entries.count < capacity {
            return Array(entries.suffix(n))
        }
        return (0..<n).map { entries[(next - n + $0 + capacity) % capacity] }
    }

    public var count: Int { entries.count }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        next = 0
    }
}

public struct DebugLogEntry: Sendable, Equatable {
    public var cycle: UInt64
    public var cpu: DebugCPU
    public var text: String
}

public final class Debugger {
    unowned let machine: BBCMicro

    public private(set) var breakpoints: [Breakpoint] = []
    private var nextBreakpointID = 1
    var conditions: [Int: DebugExpression] = [:]
    /// Per CPU, per address: the breakpoint kinds set there.
    var hostFlags = [UInt8](repeating: 0, count: 0x10000)
    var parasiteFlags = [UInt8](repeating: 0, count: 0x10000)
    /// The flag for BASIC's hooks (with the breakpoint kinds' bits).
    static let basicHook: UInt8 = 8
    /// Debugging BASIC programs.
    public private(set) lazy var basic = BasicDebugger(debugger: self)

    public private(set) var stopReason: StopReason?
    /// Counts stops, so two in a row for the same reason can be told apart.
    public private(set) var stopCount = 0
    private var command: RunCommand?
    private var commandCPU = DebugCPU.host
    private var stepTarget: UInt16 = 0
    private var stepStack = 0
    /// The Z80 stopped before an instruction: don't stop there again on
    /// resuming.
    var z80Skip = false
    /// A Z80 command is starting from an instruction it hasn't stopped at:
    /// run that one without checking it (so a step goes somewhere).
    private var z80Unchecked = false
    /// While going back in history: stop the Z80 when it's run this many
    /// instructions in the cycle.
    var z80SeekTarget: Int?

    /// Opcode fetches seen per CPU (while the hooks are on), and the
    /// instruction a data breakpoint last stopped in: read-modify-write
    /// instructions write twice, but one stop per instruction is enough.
    private var fetches: [DebugCPU: Int] = [:]
    private var lastDataStop: (cpu: DebugCPU, address: UInt16, fetch: Int)?

    /// Log points' output, oldest first.
    public private(set) var log: [DebugLogEntry] = []
    public static let logLimit = 1000
    /// Symbols and source lines, per CPU (the OS's and hardware's built
    /// in).
    public private(set) lazy var hostSymbols = SymbolTable.builtIn(model: machine.model, cpu: .host)
    public private(set) lazy var parasiteSymbols = SymbolTable.builtIn(model: machine.model, cpu: .parasite,
                                                                       z80: machine.z80Processor != nil)

    public func symbols(_ cpu: DebugCPU) -> SymbolTable {
        cpu == .host ? hostSymbols : parasiteSymbols
    }

    /// Adds symbols (e.g. from `SymbolTable.load(path:)`) for code on `cpu`.
    public func addSymbols(_ table: SymbolTable, cpu: DebugCPU = .host) {
        if cpu == .host {
            hostSymbols.merge(table)
        } else {
            parasiteSymbols.merge(table)
        }
    }

    /// Back to just the built-in symbols, for one CPU or (nil) both.
    public func clearSymbols(_ cpu: DebugCPU? = nil) {
        if cpu != .parasite {
            hostSymbols = SymbolTable.builtIn(model: machine.model, cpu: .host)
        }
        if cpu != .host {
            parasiteSymbols = SymbolTable.builtIn(model: machine.model, cpu: .parasite, z80: machine.z80Processor != nil)
        }
    }

    public private(set) var hostTrace = TraceBuffer(capacity: 1)
    public private(set) var parasiteTrace = TraceBuffer(capacity: 1)
    public private(set) var tracing = false

    init(machine: BBCMicro) {
        self.machine = machine
    }

    // MARK: Breakpoints

    /// Adds a breakpoint; returns it with its ID. Throws if its condition
    /// doesn't parse.
    @discardableResult
    public func add(_ breakpoint: Breakpoint) throws(DebugExpression.ParseError) -> Breakpoint {
        var b = breakpoint
        b.id = nextBreakpointID
        b.hitCount = 0
        if let condition = b.condition {
            conditions[b.id] = try DebugExpression(condition)
        }
        nextBreakpointID += 1
        breakpoints.append(b)
        updateFlags()
        return b
    }

    /// Replaces a breakpoint (same ID), keeping its hit count.
    public func update(_ breakpoint: Breakpoint) throws(DebugExpression.ParseError) {
        guard let index = breakpoints.firstIndex(where: { $0.id == breakpoint.id }) else { return }
        conditions[breakpoint.id] = try breakpoint.condition.map { (c) throws(DebugExpression.ParseError) in try DebugExpression(c) }
        var b = breakpoint
        b.hitCount = breakpoints[index].hitCount
        breakpoints[index] = b
        updateFlags()
    }

    public func remove(id: Int) {
        breakpoints.removeAll { $0.id == id }
        conditions[id] = nil
        updateFlags()
    }

    public func removeAllBreakpoints() {
        breakpoints = []
        conditions = [:]
        updateFlags()
    }

    func updateFlags() {
        hostFlags = [UInt8](repeating: 0, count: 0x10000)
        parasiteFlags = [UInt8](repeating: 0, count: 0x10000)
        for b in breakpoints where b.enabled {
            var address = b.start
            while true {
                if b.cpu == .host {
                    hostFlags[Int(address)] |= b.kind.rawValue
                } else {
                    parasiteFlags[Int(address)] |= b.kind.rawValue
                }
                if address == b.end { break }
                address &+= 1
            }
        }
        basic.setHooks(host: &hostFlags, parasite: &parasiteFlags)
        updateHooks()
    }

    var profiler: Profiler? {
        didSet { profilingActive = profiler != nil }
    }
    var profilingActive = false

    /// Forces the hooks on (for searching history).
    var forceHooks = false {
        didSet { updateHooks() }
    }

    func updateHooks() {
        let any = breakpoints.contains { $0.enabled } || command != nil || tracing || forceHooks || profilingActive
            || basic.isActive
        machine.debugHooks = any
        machine.debugVideoHooks = command == .nextFrame || command == .nextScanline || profilingActive
        machine.secondProcessor?.debugger = any ? self : nil
        machine.z80Processor?.debugger = any ? self : nil
    }

    /// Takes on `other`'s breakpoints (with their hit counts), symbols,
    /// tracing and log: the old machine's, when a snapshot, save state or
    /// power cycle replaces it. Not its stop. Symbols carry over only to
    /// the same model, whose built-in ones they include.
    public func adopt(_ other: Debugger) {
        breakpoints = other.breakpoints
        nextBreakpointID = other.nextBreakpointID
        conditions = other.conditions
        if other.machine.model == machine.model {
            hostSymbols = other.hostSymbols
            parasiteSymbols = other.parasiteSymbols
        }
        log = other.log
        basic.adopt(other.basic)
        if other.tracing {
            setTracing(capacity: other.hostTrace.capacity)
        }
        updateFlags()
    }

    // MARK: Running

    /// Clears the stop, so the machine can run.
    public func resume() {
        stopReason = nil
        machine.stopRequested = false
        basic.resumed()
    }

    /// Stops the machine at the end of the current cycle.
    public func requestStop() {
        stop(.requested)
    }

    /// Starts `command` on `cpu` and returns at once: the machine stops
    /// when it's done, as it runs normally. (`.stepCycle` isn't
    /// supported: run one cycle instead.)
    public func begin(_ command: RunCommand, cpu: DebugCPU = .host) {
        precondition(command != .stepCycle)
        resume()
        arm(command, cpu: cpu)
    }

    /// Whether a command from `begin` is still running.
    public var isRunningCommand: Bool { command != nil || basic.isStepping }

    /// Runs `command` on `cpu`, using `advance` to run the machine (so
    /// recording and the display keep up), for at most `maxCycles`. Returns
    /// why it stopped, or nil if the time ran out.
    @discardableResult
    public func run(_ command: RunCommand, cpu: DebugCPU = .host, maxCycles: Int,
                    advance: (Int) -> Void) -> StopReason? {
        resume()
        arm(command, cpu: cpu)
        defer { disarm() }
        if command == .stepCycle {
            advance(1)
            if stopReason == nil {
                stop(.stepped(cpu))
            }
            return stopReason
        }
        return runUntilStopped(maxCycles: maxCycles, advance: advance)
    }

    private func runUntilStopped(maxCycles: Int, advance: (Int) -> Void) -> StopReason? {
        var remaining = maxCycles
        while stopReason == nil && remaining > 0 {
            let before = machine.cycles
            advance(min(remaining, 20_000))
            let ran = Int(machine.cycles - before)
            remaining -= max(ran, 1)
        }
        return stopReason
    }

    /// Steps a BASIC program (from where it stopped), as `run`.
    @discardableResult
    public func run(basic step: BasicStep, maxCycles: Int, advance: (Int) -> Void) -> StopReason? {
        let origin = basic.origin
        resume()
        basic.arm(step, from: origin)
        defer { basic.disarm() }
        return runUntilStopped(maxCycles: maxCycles, advance: advance)
    }

    /// Starts a BASIC step and returns at once, as `begin`.
    public func begin(basic step: BasicStep) {
        let origin = basic.origin
        resume()
        basic.arm(step, from: origin)
    }

    private func arm(_ command: RunCommand, cpu: DebugCPU) {
        self.command = command == .continue ? nil : command
        commandCPU = cpu
        guard let stack = machine.stackPointer(cpu) else { return }
        let pc = machine.instructionAddress(cpu)
        stepStack = stack
        z80Unchecked = cpu == .parasite && machine.z80Processor != nil && command != .continue && !z80Skip
        switch command {
        case .stepOver:
            // JSR (or CALL): run to the instruction after it, at the same
            // stack depth.
            if let length = machine.callLength(cpu, at: pc) {
                stepTarget = pc &+ UInt16(length)
            } else {
                self.command = .stepInstruction
            }
        case .runToAddress(let address):
            stepTarget = address
        default:
            break
        }
        updateHooks()
    }

    private func disarm() {
        command = nil
        updateHooks()
    }

    func stop(_ reason: StopReason) {
        guard stopReason == nil else { return }
        stopReason = reason
        stopCount += 1
        machine.stopRequested = true
        // Whatever was running is done.
        if command != nil {
            command = nil
            updateHooks()
        }
        if basic.isStepping {
            basic.stopped()
            updateFlags()
        }
    }

    func appendLog(_ text: String, cpu: DebugCPU) {
        log.append(DebugLogEntry(cycle: machine.cycles, cpu: cpu, text: text))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    // MARK: Tracing

    /// Starts (or with 0, stops) recording the last `capacity` instructions
    /// of each CPU.
    public func setTracing(capacity: Int) {
        tracing = capacity > 0
        hostTrace = TraceBuffer(capacity: max(capacity, 1))
        parasiteTrace = TraceBuffer(capacity: max(capacity, 1))
        updateHooks()
    }

    public func trace(_ cpu: DebugCPU) -> TraceBuffer {
        cpu == .host ? hostTrace : parasiteTrace
    }

    // MARK: Expressions

    /// The context expressions on `cpu` are evaluated in.
    public func expressionContext(_ cpu: DebugCPU) -> DebugExpression.Context {
        let machine = self.machine
        let table = symbols(cpu)
        return DebugExpression.Context(
            register: { name in machine.register(name, cpu: cpu) },
            readByte: { machine.debugRead(.cpu(cpu), Int($0)) ?? 0xFF },
            symbol: { table.address(of: $0) })
    }

    /// Replaces each {expression} in `text` with its value.
    public func interpolate(_ text: String, cpu: DebugCPU) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let source = String(rest[rest.index(after: open)..<close])
            if let expression = try? DebugExpression(source),
               let value = try? expression.evaluate(expressionContext(cpu)) {
                result += value >= 0 && value < 0x100 ? "&\(String(value, radix: 16, uppercase: true))" : "\(value)"
            } else {
                result += "{\(source)?}"
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    // MARK: Hooks

    /// While rewinding, sees accesses instead of the breakpoints.
    var replayObserver: ((DebugCPU, UInt16, M6502.BusAccess) -> Void)?

    /// Every host cycle, while the hooks are on.
    @inline(__always)
    func hostCycle() {
        if profilingActive, machine.rewinder?.isReplaying != true {
            profiler!.cycle(.host, pc: machine.cpu.opcodePC)
        }
    }

    @inline(never)
    func hostAccessed(_ address: UInt16, _ access: M6502.BusAccess) {
        if z80SeekTarget != nil { return }
        if machine.rewinder?.isReplaying == true {
            replayObserver?(.host, address, access)
            return
        }
        accessed(.host, address, access, flags: hostFlags[Int(address)])
    }

    @inline(never)
    func parasiteAccessed(_ address: UInt16, _ access: M6502.BusAccess) {
        if machine.rewinder?.isReplaying == true {
            replayObserver?(.parasite, address, access)
            return
        }
        if profilingActive, let p = machine.secondProcessor {
            profiler!.cycle(.parasite, pc: p.cpu.opcodePC)
        }
        accessed(.parasite, address, access, flags: parasiteFlags[Int(address)])
    }

    private func accessed(_ cpu: DebugCPU, _ address: UInt16, _ access: M6502.BusAccess, flags: UInt8) {
        let kind: Breakpoint.Kind
        switch access {
        case .opcode:
            executing(cpu, address, opcode: machine.debugCPU(cpu)?.dbus ?? 0, flags: flags)
            return
        case .interrupt:
            if profilingActive {
                profiler!.fetch(cpu, address, opcode: 0, interrupt: true)
            }
            if tracing { record(cpu, address, interrupt: true) }
            if command == .nextInterrupt && commandCPU == cpu {
                stop(.interrupt(cpu))
            }
            return
        case .write: kind = .write
        case .data, .address: kind = .read
        default: return
        }
        dataAccessed(cpu, address, kind, flags: flags)
    }

    /// An instruction at `address` is about to run.
    private func executing(_ cpu: DebugCPU, _ address: UInt16, opcode: UInt8, flags: UInt8, check: Bool = true) {
        if profilingActive {
            profiler!.fetch(cpu, address, opcode: opcode, interrupt: false)
        }
        fetches[cpu, default: 0] += 1
        if tracing { record(cpu, address, interrupt: false) }
        guard check else { return }
        if let command, commandCPU == cpu, let stack = machine.stackPointer(cpu) {
            switch command {
            case .stepInstruction:
                stop(.stepped(cpu))
            case .stepOver:
                if address == stepTarget && stack >= stepStack { stop(.stepped(cpu)) }
            case .stepOut:
                if stack > stepStack { stop(.stepped(cpu)) }
            case .runToAddress:
                if address == stepTarget { stop(.stepped(cpu)) }
            default:
                break
            }
        }
        if flags & Self.basicHook != 0 {
            basic.executing(cpu, address)
        }
        breakpointCheck(cpu, address, .execute, flags: flags)
    }

    private func dataAccessed(_ cpu: DebugCPU, _ address: UInt16, _ kind: Breakpoint.Kind, flags: UInt8) {
        breakpointCheck(cpu, address, kind, flags: flags)
    }

    private func breakpointCheck(_ cpu: DebugCPU, _ address: UInt16, _ kind: Breakpoint.Kind, flags: UInt8) {
        guard flags & kind.rawValue != 0 else { return }
        if kind != .execute, let last = lastDataStop, last.cpu == cpu, last.address == address,
           last.fetch == fetches[cpu, default: 0] {
            return
        }
        for index in matchingBreakpoints(cpu, address, kind) {
            breakpoints[index].hitCount += 1
            let b = breakpoints[index]
            if let target = b.hitTarget, b.hitCount < target { continue }
            if let message = b.logMessage {
                appendLog(interpolate(message, cpu: cpu), cpu: cpu)
                continue
            }
            if kind != .execute {
                lastDataStop = (cpu, address, fetches[cpu, default: 0])
            }
            stop(.breakpoint(id: b.id, cpu: cpu, address: address, kind: kind))
            return
        }
    }

    /// The enabled breakpoints matching an access, with their conditions
    /// true (hit counts aren't touched).
    func matchingBreakpoints(_ cpu: DebugCPU, _ address: UInt16, _ kind: Breakpoint.Kind) -> [Int] {
        var matches: [Int] = []
        for index in breakpoints.indices {
            let b = breakpoints[index]
            guard b.enabled, b.cpu == cpu, b.kind.contains(kind), b.covers(address) else { continue }
            if let bank = b.romBank, cpu == .host {
                guard address >= 0x8000 && address < 0xC000 && Int(machine.romsel & 0x0F) == bank else { continue }
            }
            if let condition = conditions[b.id] {
                guard (try? condition.isTrue(expressionContext(cpu))) == true else { continue }
            }
            matches.append(index)
        }
        return matches
    }

    /// Before each Z80 step, while the hooks are on. Returns true to stop
    /// before it.
    @inline(never)
    func z80WillStep(_ z: Z80SecondProcessor) -> Bool {
        if let target = z80SeekTarget {
            if z.executed == target {
                machine.stopRequested = true
                return true
            }
            return false
        }
        let pc = z.cpu.pc
        if machine.rewinder?.isReplaying == true {
            if z.interruptNext {
                replayObserver?(.parasite, pc, .interrupt)
            } else if !z.cpu.halted {
                replayObserver?(.parasite, pc, .opcode)
            }
            return false
        }
        if z80Skip {
            // Stopped here already (and traced it).
            z80Skip = false
            return false
        }
        let check = !z80Unchecked
        z80Unchecked = false
        let before = stopCount
        if z.interruptNext {
            if tracing { record(.parasite, pc, interrupt: true) }
            if check && command == .nextInterrupt && commandCPU == .parasite {
                stop(.interrupt(.parasite))
            }
        } else if !z.cpu.halted {
            executing(.parasite, pc, opcode: z.peek(pc), flags: parasiteFlags[Int(pc)], check: check)
        }
        if stopCount != before {
            z80Skip = true
            return true
        }
        return false
    }

    /// After each Z80 step: its T-states, for the profiler.
    @inline(__always)
    func z80Stepped(pc: UInt16, tStates: Int) {
        if profilingActive, z80SeekTarget == nil, machine.rewinder?.isReplaying != true {
            profiler!.cycles(.parasite, pc: pc, count: tStates)
        }
    }

    /// A Z80 memory access (not an opcode or operand fetch). A stop
    /// happens once the instruction's done.
    @inline(never)
    func z80Accessed(_ address: UInt16, write: Bool) {
        if z80SeekTarget != nil { return }
        if machine.rewinder?.isReplaying == true {
            replayObserver?(.parasite, address, write ? .write : .data)
            return
        }
        dataAccessed(.parasite, address, write ? .write : .read, flags: parasiteFlags[Int(address)])
    }

    func video(_ output: CRTC6845.Output, last: CRTC6845.Output) {
        if machine.rewinder?.isReplaying == true || z80SeekTarget != nil { return }
        if profilingActive && output.vsync && !last.vsync {
            profiler!.frame()
        }
        if command == .nextFrame && output.vsync && !last.vsync {
            stop(.frame)
        } else if command == .nextScanline && output.hsync && !last.hsync {
            stop(.scanline)
        }
    }

    private func record(_ cpu: DebugCPU, _ address: UInt16, interrupt: Bool) {
        let read = { (a: UInt16) in self.machine.codeRead(cpu, Int(a)) ?? 0xFF }
        let bytes = (read(address), read(address &+ 1), read(address &+ 2), read(address &+ 3))
        let entry: TraceEntry
        if cpu == .parasite, let z = machine.z80Processor?.cpu {
            entry = TraceEntry(cycle: machine.cycles, pc: address, a: z.a, x: 0, y: 0, s: 0, p: z.f,
                               bytes: bytes, interrupt: interrupt,
                               z80: .init(af: z.af, bc: z.bc, de: z.de, hl: z.hl, ix: z.ix, iy: z.iy, sp: z.sp))
        } else {
            guard let c = machine.debugCPU(cpu) else { return }
            entry = TraceEntry(cycle: machine.cycles, pc: address, a: c.a, x: c.x, y: c.y, s: c.s, p: c.p,
                               bytes: bytes, interrupt: interrupt)
        }
        if cpu == .host {
            hostTrace.append(entry)
        } else {
            parasiteTrace.append(entry)
        }
    }
}
