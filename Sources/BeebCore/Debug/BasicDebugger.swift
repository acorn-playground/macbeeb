// Debugging BBC BASIC programs: breakpoints on lines, stepping by
// statement, stopping on errors, and the program's calls and variables.
//
// It works by the interpreter's own code (see BasicMemory): an internal
// execute hook where each statement starts, and one on BASIC's error
// handler. The hooks are on only while a BASIC breakpoint, step or error
// stop is set.

/// A breakpoint on a program line.
public struct BasicBreakpoint: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var line: Int
    /// Only this statement in the line (1 for the first). Without one, it
    /// stops as the line is entered: not at each statement in it, but
    /// again each time a loop goes back to it.
    public var statement: Int?
    /// A BASIC expression: only stop (or log) when it's true (not 0).
    public var condition: String?
    /// Only stop once hit this many times.
    public var hitTarget: Int?
    /// Log this (with {expression} replaced by its value) instead of
    /// stopping.
    public var logMessage: String?
    public var enabled = true
    public var hitCount = 0

    public init(id: Int = 0, line: Int, statement: Int? = nil, condition: String? = nil, hitTarget: Int? = nil,
                logMessage: String? = nil) {
        self.id = id
        self.line = line
        self.statement = statement
        self.condition = condition
        self.hitTarget = hitTarget
        self.logMessage = logMessage
    }
}

/// How far a BASIC step goes.
public enum BasicStep: String, Sendable, CaseIterable {
    /// To the next statement, into PROCs, FNs and GOSUBs.
    case into
    /// To the next statement in this PROC, FN or subroutine (or its
    /// caller's, once it returns).
    case over
    /// Until this PROC, FN or subroutine returns.
    case out
}

/// The error a BASIC program stopped on.
public struct BasicError: Sendable, Equatable {
    public var number: Int
    public var message: String
    public var location: BasicLocation
    /// Whether the program has an ON ERROR handler for it.
    public var trapped: Bool
}

public final class BasicDebugger {
    public enum ErrorStop: String, Sendable, CaseIterable {
        case off
        /// Errors without an ON ERROR to handle them (Escape too, and STOP).
        case untrapped
        /// Every error, before ON ERROR sees it.
        case all
    }

    unowned let debugger: Debugger
    var machine: BBCMicro { debugger.machine }

    /// The BASIC ROMs found when the hooks were last set (or looked for).
    public private(set) var interpreters: [BasicInterpreter] = []

    /// The interpreter on `cpu`, looking for it if need be.
    func interpreter(_ cpu: DebugCPU) -> BasicInterpreter? {
        if !interpreters.contains(where: { $0.cpu == cpu }) {
            interpreters = findInterpreters()
        }
        return interpreters.first { $0.cpu == cpu }
    }
    public private(set) var breakpoints: [BasicBreakpoint] = []
    private var nextBreakpointID = 1
    private var conditions: [Int: BasicExpression] = [:]
    public var errorStop = ErrorStop.off {
        didSet { if errorStop != oldValue { debugger.updateFlags() } }
    }

    /// Where the machine stopped in BASIC (until it resumes).
    public private(set) var stop: (cpu: DebugCPU, location: BasicLocation)?
    /// The error, if it stopped on one.
    public private(set) var error: BasicError?
    /// The stop's depth (see `BasicMemory.frameKey`), at a statement.
    private var stopKey: (frame: Int, gosubs: Int)?
    /// A step in progress, from a stop on `cpu` (or from anywhere, nil).
    private var step: (kind: BasicStep, cpu: DebugCPU?, key: (frame: Int, gosubs: Int)?)?
    /// Per CPU, per call depth: the last statement started, so a line's
    /// breakpoint stops only on entering it.
    private var lastStatements: [DebugCPU: [Int: BasicLocation]] = [:]
    private var lineCache: [DebugCPU: (page: Int, top: Int, lines: [BasicLine])] = [:]

    init(debugger: Debugger) {
        self.debugger = debugger
    }

    // MARK: Breakpoints

    @discardableResult
    public func add(_ breakpoint: BasicBreakpoint) throws(BasicExpression.ParseError) -> BasicBreakpoint {
        var b = breakpoint
        b.id = nextBreakpointID
        b.hitCount = 0
        if let condition = b.condition {
            conditions[b.id] = try BasicExpression(condition)
        }
        nextBreakpointID += 1
        breakpoints.append(b)
        debugger.updateFlags()
        return b
    }

    /// Replaces a breakpoint (same ID), keeping its hit count.
    public func update(_ breakpoint: BasicBreakpoint) throws(BasicExpression.ParseError) {
        guard let index = breakpoints.firstIndex(where: { $0.id == breakpoint.id }) else { return }
        conditions[breakpoint.id] = try breakpoint.condition.map { (c) throws(BasicExpression.ParseError) in try BasicExpression(c) }
        var b = breakpoint
        b.hitCount = breakpoints[index].hitCount
        breakpoints[index] = b
        debugger.updateFlags()
    }

    public func remove(id: Int) {
        breakpoints.removeAll { $0.id == id }
        conditions[id] = nil
        debugger.updateFlags()
    }

    public func removeAllBreakpoints() {
        breakpoints = []
        conditions = [:]
        debugger.updateFlags()
    }

    /// Takes on another machine's breakpoints and error stop.
    func adopt(_ other: BasicDebugger) {
        breakpoints = other.breakpoints
        nextBreakpointID = other.nextBreakpointID
        conditions = other.conditions
        errorStop = other.errorStop
    }

    // MARK: Hooks

    var watchesStatements: Bool { step != nil || breakpoints.contains { $0.enabled } }
    var isActive: Bool { watchesStatements || errorStop != .off }

    /// Finds the interpreters and sets their hooks' flags.
    func setHooks(host: inout [UInt8], parasite: inout [UInt8]) {
        guard isActive else { return }
        interpreters = findInterpreters()
        for i in interpreters {
            var addresses = [i.errorHandler]
            if errorStop == .off { addresses = [] }
            if watchesStatements { addresses.append(i.statement) }
            for a in addresses {
                if i.cpu == .host {
                    host[Int(a)] |= Debugger.basicHook
                } else {
                    parasite[Int(a)] |= Debugger.basicHook
                }
            }
        }
    }

    public func findInterpreters() -> [BasicInterpreter] {
        var found: [BasicInterpreter] = []
        for bank in 0..<16 {
            guard machine.debugRead(.sidewaysBank(bank), 0x8009) == 0x42 else { continue }
            let rom = (0x8000..<0xC000).map { machine.debugRead(.sidewaysBank(bank), $0) ?? 0 }
            if let i = BasicInterpreter.find(rom, cpu: .host, bank: bank) { found.append(i) }
        }
        if machine.secondProcessor != nil, machine.debugRead(.parasiteRAM, 0x8009) == 0x42 {
            let rom = (0x8000..<0xC000).map { machine.debugRead(.parasiteRAM, $0) ?? 0 }
            if let i = BasicInterpreter.find(rom, cpu: .parasite, bank: nil) { found.append(i) }
        }
        return found
    }

    /// An instruction with the hook flag is about to run.
    func executing(_ cpu: DebugCPU, _ address: UInt16) {
        guard let i = interpreters.first(where: { i in
            i.cpu == cpu && (address == i.statement || address == i.errorHandler)
                && (cpu == .parasite || Int(machine.romsel & 0x0F) == i.bank)
        }) else { return }
        if address == i.statement && watchesStatements {
            statement(cpu, i)
        } else if address == i.errorHandler && errorStop != .off {
            errorRaised(cpu, i)
        }
    }

    private func statement(_ cpu: DebugCPU, _ i: BasicInterpreter) {
        guard let y = machine.debugCPU(cpu)?.y else { return }
        let m = memory(cpu)
        // Commands typed in aren't stopped in.
        guard let location = location(of: m.word(0x0B) + Int(y), cpu: cpu) else { return }
        let key = (frame: m.frameKey(liveStack: { m[$0] }, bodyReturn: i.bodyReturn), gosubs: m.gosubs)
        let last = lastStatements[cpu]?[key.frame]
        // Deeper calls have returned.
        if lastStatements[cpu]?.keys.contains(where: { $0 < key.frame }) == true {
            lastStatements[cpu] = lastStatements[cpu]!.filter { $0.key > key.frame }
        }
        lastStatements[cpu, default: [:]][key.frame] = location

        if let step, step.cpu == nil || step.cpu == cpu {
            let done: Bool
            if let start = step.key, step.kind != .into {
                let shallower = key.frame > start.frame || key.frame == start.frame && key.gosubs < start.gosubs
                done = shallower || step.kind == .over && key.frame == start.frame && key.gosubs == start.gosubs
            } else {
                done = true
            }
            if done {
                stopHere(.basicStepped(cpu), cpu, location, key)
                return
            }
        }

        for index in breakpoints.indices where breakpoints[index].enabled && breakpoints[index].line == location.line {
            let b = breakpoints[index]
            if let statement = b.statement, statement != location.statement { continue }
            // Running on through the line (or statement) isn't entering it.
            if let last, last.line == location.line, location.address > last.address,
               b.statement == nil || last.statement == location.statement {
                continue
            }
            if let condition = conditions[b.id] {
                guard (try? condition.isTrue(context(cpu))) == true else { continue }
            }
            breakpoints[index].hitCount += 1
            if let target = b.hitTarget, breakpoints[index].hitCount < target { continue }
            if let message = b.logMessage {
                debugger.appendLog(interpolate(message, cpu: cpu), cpu: cpu)
                continue
            }
            stopHere(.basicBreakpoint(id: b.id, cpu: cpu, line: location.line), cpu, location, key)
            return
        }
    }

    private func errorRaised(_ cpu: DebugCPU, _ i: BasicInterpreter) {
        let m = memory(cpu)
        let report = m.word(0xFD)
        let number = Int(m[report])
        let trapped = number != 0 && m.word(0x16) != Int(i.defaultHandler)
        guard errorStop == .all || !trapped else { return }
        guard let location = location(of: m.word(0x0B) + max(Int(m[0x0A]) - 1, 0), cpu: cpu) else { return }
        var message: [UInt8] = []
        while message.count < 255, m[report + 1 + message.count] != 0 { message.append(m[report + 1 + message.count]) }
        let error = BasicError(number: number, message: BasicMemory.text(message), location: location, trapped: trapped)
        guard debugger.stopReason == nil else { return }
        debugger.stop(.basicError(cpu: cpu, number: number))
        stop = (cpu, location)
        self.error = error
        stopKey = nil
    }

    private func stopHere(_ reason: StopReason, _ cpu: DebugCPU, _ location: BasicLocation, _ key: (frame: Int, gosubs: Int)) {
        guard debugger.stopReason == nil else { return }
        debugger.stop(reason)
        stop = (cpu, location)
        stopKey = key
        error = nil
    }

    // MARK: Running

    /// Starts a step from where BASIC stopped (from anywhere else, all go
    /// to the next statement).
    func arm(_ kind: BasicStep, from origin: (cpu: DebugCPU, key: (frame: Int, gosubs: Int)?)?) {
        step = (kind, origin?.cpu, origin?.key)
        debugger.updateFlags()
    }

    var origin: (cpu: DebugCPU, key: (frame: Int, gosubs: Int)?)? {
        stop.map { ($0.cpu, stopKey) }
    }

    func disarm() {
        guard step != nil else { return }
        step = nil
        debugger.updateFlags()
    }

    /// The machine resumed.
    func resumed() {
        stop = nil
        error = nil
        stopKey = nil
    }

    /// Any stop ends a step.
    func stopped() {
        step = nil
    }

    public var isStepping: Bool { step != nil }

    // MARK: The program

    func memory(_ cpu: DebugCPU) -> BasicMemory {
        let machine = self.machine
        if cpu == .parasite {
            return BasicMemory(read: { machine.debugRead(.parasiteRAM, $0) ?? 0xFF },
                               write: { machine.debugWrite(.parasiteRAM, $0, $1) })
        }
        // BASIC's memory is main RAM, whatever's paged in for the screen.
        return BasicMemory(read: { a in machine.debugRead(a < 0x8000 ? .mainRAM : .cpu(.host), a) ?? 0xFF },
                           write: { a, v in machine.debugWrite(a < 0x8000 ? .mainRAM : .cpu(.host), a, v) })
    }

    /// The CPU BASIC is (or was last) stopped on, or the host.
    public var currentCPU: DebugCPU { stop?.cpu ?? .host }

    func lines(_ cpu: DebugCPU) -> [BasicLine] {
        let m = memory(cpu)
        let page = m.page, top = m.top
        if let cached = lineCache[cpu], cached.page == page, cached.top == top {
            return cached.lines
        }
        let lines = m.lines()
        lineCache[cpu] = (page, top, lines)
        return lines
    }

    /// The program line and statement `address` is in, if it's in one.
    public func location(of address: Int, cpu: DebugCPU) -> BasicLocation? {
        let m = memory(cpu)
        guard address >= m.page && address < m.top else { return nil }
        for attempt in 0..<2 {
            let lines = self.lines(cpu)
            // The last line starting before it.
            var low = 0, high = lines.count
            while low < high {
                let mid = (low + high) / 2
                if lines[mid].start < address { low = mid + 1 } else { high = mid }
            }
            if low > 0 {
                let line = lines[low - 1]
                // Edited in place (TOP the same)? Then look again.
                if m[line.start] == 0x0D, Int(m[line.start + 3]) == line.length,
                   Int(m[line.start + 1]) << 8 | Int(m[line.start + 2]) == line.number {
                    return address < line.start + line.length ? m.location(of: address, in: line) : nil
                }
            }
            if attempt == 0 { lineCache[cpu] = nil }
        }
        return nil
    }

    /// The program as LIST shows it, a line at a time.
    public func listing(cpu: DebugCPU? = nil) -> [(number: Int, text: String)] {
        let cpu = cpu ?? currentCPU
        let m = memory(cpu)
        return lines(cpu).map { line in (line.number, BBCBasic.listLine(m.bytes(line.text))) }
    }

    /// The calls being run, innermost first, ending with the main
    /// program (or if they couldn't all be followed, one named "?");
    /// empty unless stopped in BASIC.
    public func callStack() -> [BasicFrame] {
        guard let stop, let i = interpreter(stop.cpu) else { return [] }
        let m = memory(stop.cpu)
        let lines = self.lines(stop.cpu)
        let (calls, complete) = m.calls(liveStack: { m[$0] }, bodyReturn: i.bodyReturn, valuesOnTop: error != nil)
        var frames: [BasicFrame] = []
        var location: BasicLocation? = stop.location
        for call in calls {
            frames.append(BasicFrame(name: definition(containing: location, kind: call.token, lines, m), location: location))
            location = self.location(of: call.caller, cpu: stop.cpu)
        }
        // If the calls couldn't be followed out, the last caller is in a
        // PROC or FN that isn't known.
        frames.append(BasicFrame(name: complete ? nil : "?", location: location))
        return frames
    }

    /// The PROC or FN whose DEF is the last before `location`.
    private func definition(containing location: BasicLocation?, kind: UInt8, _ lines: [BasicLine], _ m: BasicMemory) -> String {
        let prefix = kind == 0xF2 ? "PROC" : "FN"
        guard let location, let index = lines.lastIndex(where: { $0.number <= location.line }) else { return prefix + "?" }
        for line in lines[...index].reversed() {
            if let name = m.definition(line), name.hasPrefix(prefix) { return name }
        }
        return prefix + "?"
    }

    // MARK: Variables

    /// The program's variables (with those LOCAL to the PROC or FN it's
    /// stopped in marked).
    public func variables(cpu: DebugCPU? = nil) -> [BasicVariable] {
        let cpu = cpu ?? currentCPU
        let m = memory(cpu)
        var variables = m.variables()
        if stop?.cpu == cpu, let i = interpreter(cpu),
           let locals = m.calls(liveStack: { m[$0] }, bodyReturn: i.bodyReturn, valuesOnTop: error != nil).calls.first?.locals {
            // A LOCAL's descriptor has the value's address.
            for index in variables.indices where locals.contains(variables[index].address) {
                variables[index].isLocal = true
            }
        }
        return variables
    }

    public func variable(_ name: String, cpu: DebugCPU? = nil) -> BasicVariable? {
        variables(cpu: cpu).first { $0.name == name }
    }

    /// An array's elements, from `first` (in the order BASIC stores them:
    /// the last index changing fastest).
    public func elements(of array: BasicVariable, from first: Int = 0, count: Int, cpu: DebugCPU? = nil) -> [([Int], BasicValue)] {
        guard let dimensions = array.dimensions else { return [] }
        let m = memory(cpu ?? currentCPU)
        let total = dimensions.reduce(1) { $0 * ($1 + 1) }
        return (first..<min(first + count, total)).map { offset in
            var indices: [Int] = []
            var rest = offset
            for highest in dimensions.reversed() {
                indices.insert(rest % (highest + 1), at: 0)
                rest /= highest + 1
            }
            return (indices, m.value(array.kind, at: array.address + offset * m.elementSize(array.kind)))
        }
    }

    func context(_ cpu: DebugCPU) -> BasicExpression.Context {
        let m = memory(cpu)
        return BasicExpression.Context(
            variable: { name in
                if name.count == 2, name.hasSuffix("%"), let c = name.unicodeScalars.first, ("@"..."Z").contains(c) {
                    return m.integer(at: 0x0400 + Int(c.value - 0x40) * 4)
                }
                return m.variables().first { $0.name == name }?.value
            },
            element: { name, indices in
                m.variables().first { $0.name == name }.flatMap { m.element($0, indices) }
            },
            memory: m)
    }

    /// Evaluates a BASIC expression with the program's variables.
    public func evaluate(_ source: String, cpu: DebugCPU? = nil) throws -> BasicValue {
        try BasicExpression(source).evaluate(context(cpu ?? currentCPU))
    }

    public enum SetError: Error, CustomStringConvertible {
        case noVariable(String)
        case badValue(String)

        public var description: String {
            switch self {
            case .noVariable(let name): "no variable \(name)"
            case .badValue(let why): why
            }
        }
    }

    /// Sets a variable (or with `indices`, an array element) to an
    /// expression's value.
    public func set(_ name: String, indices: [Int]? = nil, to source: String, cpu: DebugCPU? = nil) throws {
        let cpu = cpu ?? currentCPU
        let value = try evaluate(source, cpu: cpu)
        let m = memory(cpu)
        guard let variable = variables(cpu: cpu).first(where: { $0.name == name }) else { throw SetError.noVariable(name) }
        var address = variable.address
        if let indices {
            guard let dimensions = variable.dimensions, indices.count == dimensions.count,
                  let offset = m.elementOffset(dimensions, indices) else {
                throw SetError.badValue("\(name) has no element (\(indices.map(String.init).joined(separator: ",")))")
            }
            address += offset * m.elementSize(variable.kind)
        } else if variable.dimensions != nil {
            throw SetError.badValue("\(name) is an array: give the element's indices")
        }
        guard m.set(variable.kind, at: address, to: value) else {
            throw SetError.badValue(variable.kind == .string
                ? "a string can't be set to a number, or made longer than the space BASIC gave it (\(Int(m[address + 2])) characters)"
                : "a number can't be set to a string (or it's too big)")
        }
    }

    /// Replaces each {expression} in `text` with its value.
    func interpolate(_ text: String, cpu: DebugCPU) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let source = String(rest[rest.index(after: open)..<close])
            if let value = try? BasicExpression(source).evaluate(context(cpu)) {
                if case .string(let s) = value { result += s } else { result += "\(value)" }
            } else {
                result += "{\(source)?}"
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }
}
