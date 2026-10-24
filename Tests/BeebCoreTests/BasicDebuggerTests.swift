import Foundation
import Testing
@testable import BeebCore
import BeebHost
import BeebROMs

struct BasicExpressionTests {
    func evaluate(_ source: String) throws -> BasicValue {
        let memory = BasicMemory(read: { _ in 0 }, write: { _, _ in false })
        let context = BasicExpression.Context(variable: { ["A%": .integer(7), "x": .real(2.5), "s$": .string("hi")][$0] },
                                              element: { $0 == "a(" && $1 == [2] ? .integer(9) : nil }, memory: memory)
        return try BasicExpression(source).evaluate(context)
    }

    @Test func arithmeticAsBASIC() throws {
        #expect(try evaluate("1+2*3") == .integer(7))
        #expect(try evaluate("(1+2)*3") == .integer(9))
        #expect(try evaluate("7 DIV 2") == .integer(3))
        #expect(try evaluate("7 MOD 2") == .integer(1))
        #expect(try evaluate("7/2") == .real(3.5))
        #expect(try evaluate("2^10") == .real(1024))
        #expect(try evaluate("&FF AND 15") == .integer(15))
        #expect(try evaluate("-A%") == .integer(-7))
        #expect(try evaluate("NOT 0") == .integer(-1))
    }

    @Test func comparisonsAndLogic() throws {
        #expect(try evaluate("A%=7") == .integer(-1))
        #expect(try evaluate("A%<>7") == .integer(0))
        #expect(try evaluate("x>2 AND A%<=7") == .integer(-1))
        #expect(try evaluate("x>3 OR FALSE") == .integer(0))
        #expect(try evaluate("s$=\"hi\"") == .integer(-1))
        #expect(try evaluate("s$+\"!\"") == .string("hi!"))
        #expect(try evaluate("a(1+1)") == .integer(9))
    }

    @Test func errors() {
        #expect(throws: BasicExpression.ParseError.self) { try BasicExpression("1+") }
        #expect(throws: BasicExpression.ParseError.self) { try BasicExpression("(1") }
        #expect(throws: BasicExpression.EvaluationError.self) { try evaluate("nope") }
        #expect(throws: BasicExpression.EvaluationError.self) { try evaluate("s$+1") }
        #expect(throws: BasicExpression.EvaluationError.self) { try evaluate("1 DIV 0") }
    }

    @Test func formatsRealsAsPRINT() {
        #expect(BasicValue.real(12).description == "12")
        #expect(BasicValue.real(3.5).description == "3.5")
        #expect(BasicValue.real(1.0 / 3).description == "0.333333333")
        #expect(BasicValue.real(0.05).description == "5E-2")
        #expect(BasicValue.real(1e10).description == "1E10")
        #expect(BasicValue.real(-123456789).description == "-123456789")
        #expect(BasicValue.real(2.0 / 3 * 1e-5).description == "6.66666667E-6")
    }

    @Test func encodesRealsAsBASIC() {
        // 1, -1, 0.5, 10, as BASIC stores them.
        #expect(BasicMemory.encodeReal(1) == [0x81, 0x00, 0, 0, 0])
        #expect(BasicMemory.encodeReal(-1) == [0x81, 0x80, 0, 0, 0])
        #expect(BasicMemory.encodeReal(0.5) == [0x80, 0x00, 0, 0, 0])
        #expect(BasicMemory.encodeReal(10) == [0x84, 0x20, 0, 0, 0])
        for x in [1.0, -2.75, 1e-7, 123456.789, 3e30] {
            let bytes = BasicMemory.encodeReal(x)
            let m = BasicMemory(read: { bytes[$0] }, write: { _, _ in false })
            #expect(abs(m.real(at: 0) - x) <= abs(x) * 1e-9)
        }
    }
}

struct BasicDebuggerTests {
    static let program = """
    10 A%=1
    15 PROCouter
    20 total=0
    30 FOR I%=1 TO 3
    40 PROCadd(I%)
    50 NEXT
    60 name$="DONE"
    70 DIM grid%(2,3)
    75 grid%(1,2)=42
    80 END
    100 DEF PROCadd(N%)
    110 LOCAL T
    120 T=N%*2
    130 total=total+T
    140 ENDPROC
    300 DEF PROCouter
    310 LOCAL Z
    320 Z=1+FNinner(3)
    330 ENDPROC
    400 DEF FNinner(Q)
    410 =Q*2
    """

    func machine(_ model: BBCMicro.Model = .modelB, program: String = Self.program) -> BBCMicro {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: model))
        #expect(m.runUntilIdle())
        m.paste(program + "\n")
        #expect(m.runUntilIdle())
        return m
    }

    /// Types `text` (if any) and runs until the debugger stops it, or
    /// it's waiting for a key.
    @discardableResult
    func run(_ m: BBCMicro, _ text: String? = "RUN") -> StopReason? {
        m.debugger.resume()
        if let text { m.paste(text + "\n") }
        m.runUntilIdle(maxSeconds: 20)
        return m.debugger.stopReason
    }

    @discardableResult
    func step(_ m: BBCMicro, _ kind: BasicStep) -> StopReason? {
        m.debugger.run(basic: kind, maxCycles: 20_000_000) { m.run(cycles: $0) }
    }

    func value(_ m: BBCMicro, _ name: String) -> BasicValue? {
        m.debugger.basic.variable(name)?.value
    }

    @Test(arguments: [(BBCMicro.Model.modelB, "BASIC 2"), (.master128, "BASIC 4"), (.masterCompact, "BASIC 4r32")])
    func findsTheInterpreter(model: BBCMicro.Model, name: String) throws {
        let m = machine(model)
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 120))
        #expect(basic.interpreters.map(\.name) == [name])
        #expect(run(m) == .basicBreakpoint(id: 1, cpu: .host, line: 120))
        #expect(basic.stop?.location == BasicLocation(line: 120, statement: 1, address: basic.stop!.location.address))
        #expect(value(m, "N%") == .integer(1))
        #expect(basic.callStack().map(\.name) == ["PROCadd", nil])
        #expect(basic.callStack().map { $0.location?.line } == [120, 40])
        #expect(basic.variables().filter(\.isLocal).map(\.name).sorted() == ["N%", "T"])
        // Again for the next time round the loop.
        #expect(run(m, nil) == .basicBreakpoint(id: 1, cpu: .host, line: 120))
        #expect(value(m, "N%") == .integer(2))
        #expect(value(m, "total") == .real(2))
    }

    @Test(arguments: [BBCMicro.Model.modelB, .master128])
    func callStackThroughAnFNInAnExpression(model: BBCMicro.Model) throws {
        let m = machine(model)
        try m.debugger.basic.add(BasicBreakpoint(line: 410))
        #expect(run(m) == .basicBreakpoint(id: 1, cpu: .host, line: 410))
        let frames = m.debugger.basic.callStack()
        #expect(frames.map(\.name) == ["FNinner", "PROCouter", nil])
        #expect(frames.map { $0.location?.line } == [410, 320, 15])
        #expect(value(m, "Q") == .real(3))
    }

    @Test func steps() throws {
        let m = machine()
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 40))
        #expect(run(m) == .basicBreakpoint(id: 1, cpu: .host, line: 40))
        basic.removeAllBreakpoints()
        // Over the PROC.
        #expect(step(m, .over) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 50)
        #expect(value(m, "total") == .real(2))
        #expect(step(m, .over) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 40)
        // Into it, then out again.
        #expect(step(m, .into) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 110)
        #expect(step(m, .into) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 120)
        #expect(step(m, .out) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 50)
        #expect(value(m, "total") == .real(6))
        #expect(!m.debugger.isRunningCommand)
    }

    @Test func stepsOverAnFN() throws {
        let m = machine()
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 320))
        #expect(run(m) == .basicBreakpoint(id: 1, cpu: .host, line: 320))
        basic.removeAllBreakpoints()
        #expect(step(m, .over) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 330)
        #expect(value(m, "Z") == .real(7))
    }

    @Test(arguments: [BBCMicro.Model.modelB, .master128])
    func recursionWithStringLocals(model: BBCMicro.Model) throws {
        let program = """
        10 PROCrec(3,"a")
        20 END
        100 DEF PROCrec(N%,s$)
        110 LOCAL t$
        120 t$=s$+"b"
        130 IF N%>0 PROCrec(N%-1,t$)
        140 PRINT N%;s$
        150 ENDPROC
        """
        let m = machine(model, program: program)
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 140, condition: "N%=0"))
        #expect(run(m) == .basicBreakpoint(id: 1, cpu: .host, line: 140))
        let frames = basic.callStack()
        #expect(frames.map(\.name) == ["PROCrec", "PROCrec", "PROCrec", "PROCrec", nil])
        #expect(frames.map { $0.location?.line } == [140, 130, 130, 130, 10])
        #expect(value(m, "s$") == .string("abbb"))
        #expect(basic.variables().filter(\.isLocal).map(\.name).sorted() == ["N%", "s$", "t$"])
        // Out of one level, then over the rest.
        basic.removeAllBreakpoints()
        #expect(step(m, .out) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 140)
        #expect(value(m, "N%") == .integer(1))
        #expect(basic.callStack().map { $0.location?.line } == [140, 130, 130, 10])
    }

    @Test(arguments: [BBCMicro.Model.modelB, .master128])
    func callStackAtAnErrorPartWayThroughExpressions(model: BBCMicro.Model) throws {
        let program = """
        10 PROCa
        20 END
        100 DEF PROCa
        110 LOCAL x
        120 x=2+FNb(1)
        130 ENDPROC
        200 DEF FNb(y)
        210 =3+y/0
        """
        let m = machine(model, program: program)
        let basic = m.debugger.basic
        basic.errorStop = .untrapped
        #expect(run(m) == .basicError(cpu: .host, number: 18))
        let frames = basic.callStack()
        #expect(frames.map(\.name) == ["FNb", "PROCa", nil])
        #expect(frames.map { $0.location?.line } == [210, 120, 10])
        #expect(basic.variables().filter(\.isLocal).map(\.name) == ["y"])
    }

    @Test func stepsOverAndOutOfGOSUBs() throws {
        let m = machine(program: "10 GOSUB 100\n20 PRINT \"back\"\n30 GOSUB 100\n40 END\n100 A%=1\n110 A%=2\n120 RETURN")
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 10))
        #expect(run(m) == .basicBreakpoint(id: 1, cpu: .host, line: 10))
        basic.removeAllBreakpoints()
        #expect(step(m, .over) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 20)
        #expect(step(m, .over) == .basicStepped(.host))
        #expect(step(m, .into) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 100)
        #expect(step(m, .over) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 110)
        #expect(step(m, .out) == .basicStepped(.host))
        #expect(basic.stop?.location.line == 40)
    }

    @Test func conditionsAndHitCounts() throws {
        let m = machine()
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 130, condition: "N%=3"))
        #expect(run(m) == .basicBreakpoint(id: 1, cpu: .host, line: 130))
        #expect(value(m, "N%") == .integer(3))
        basic.removeAllBreakpoints()
        try basic.add(BasicBreakpoint(line: 120, hitTarget: 2))
        #expect(run(m) == .basicBreakpoint(id: 2, cpu: .host, line: 120))
        #expect(value(m, "N%") == .integer(2))
        #expect(throws: BasicExpression.ParseError.self) { try basic.add(BasicBreakpoint(line: 10, condition: "1+")) }
    }

    @Test func logPoints() throws {
        let m = machine()
        try m.debugger.basic.add(BasicBreakpoint(line: 130, logMessage: "N%={N%} T={T}"))
        #expect(run(m) == nil)
        #expect(m.debugger.log.map(\.text) == ["N%=1 T=2", "N%=2 T=4", "N%=3 T=6"])
    }

    @Test func aLineIsEnteredOncePerLoop() throws {
        let m = machine(program: "10 FOR I%=1 TO 3:PRINT I%:NEXT\n20 END")
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 10))
        var stops: [Int] = []
        var reason = run(m)
        while case .basicBreakpoint = reason {
            stops.append(basic.stop!.location.statement)
            reason = run(m, nil)
        }
        // FOR, then PRINT each time NEXT goes back.
        #expect(stops == [1, 2, 2])
        // A statement's breakpoint is for that statement.
        try basic.add(BasicBreakpoint(line: 10, statement: 3))
        basic.remove(id: 1)
        stops = []
        reason = run(m)
        while case .basicBreakpoint = reason {
            stops.append(basic.stop!.location.statement)
            reason = run(m, nil)
        }
        #expect(stops == [3, 3, 3])
    }

    @Test(arguments: [BBCMicro.Model.modelB, .master128])
    func stopsOnErrors(model: BBCMicro.Model) throws {
        let m = machine(model, program: "10 X=1\n20 PRINT X/0\n30 END")
        let basic = m.debugger.basic
        basic.errorStop = .untrapped
        #expect(run(m) == .basicError(cpu: .host, number: 18))
        #expect(basic.error?.message == "Division by zero")
        #expect(basic.error?.location.line == 20)
        #expect(basic.error?.trapped == false)
        #expect(basic.callStack().map { $0.location?.line } == [20])
        // A mistake typed in isn't stopped on.
        #expect(run(m, "PRINT 1/0") == nil)
    }

    @Test func trappedErrorsOnlyWhenAsked() throws {
        let program = "10 ON ERROR GOTO 100\n20 PRINT 1/0\n30 END\n100 PRINT \"trapped\":END"
        let m = machine(program: program)
        let basic = m.debugger.basic
        basic.errorStop = .untrapped
        #expect(run(m) == nil)
        basic.errorStop = .all
        #expect(run(m) == .basicError(cpu: .host, number: 18))
        #expect(basic.error?.trapped == true)
    }

    @Test func variablesAndArrays() throws {
        let m = machine()
        let basic = m.debugger.basic
        try basic.add(BasicBreakpoint(line: 80))
        #expect(run(m) == .basicBreakpoint(id: 1, cpu: .host, line: 80))
        #expect(value(m, "A%") == .integer(1))
        #expect(value(m, "total") == .real(12))
        #expect(value(m, "name$") == .string("DONE"))
        let grid = try #require(basic.variable("grid%("))
        #expect(grid.dimensions == [2, 3])
        #expect(try basic.evaluate("grid%(1,2)") == .integer(42))
        #expect(basic.elements(of: grid, from: 6, count: 1).first?.1 == .integer(42))
        #expect(try basic.evaluate("total/2+A%") == .real(7))
        // Setting them.
        try basic.set("total", to: "99.5")
        #expect(value(m, "total") == .real(99.5))
        try basic.set("A%", to: "-5")
        #expect(value(m, "A%") == .integer(-5))
        try basic.set("name$", to: "\"OK\"")
        #expect(value(m, "name$") == .string("OK"))
        #expect(throws: BasicDebugger.SetError.self) { try basic.set("name$", to: "\"MUCH LONGER\"") }
        try basic.set("grid%(", indices: [2, 3], to: "7")
        #expect(try basic.evaluate("grid%(2,3)") == .integer(7))
    }

    @Test func listsTheProgram() throws {
        let m = machine(program: "10 PRINT \"HI\":GOTO 10")
        #expect(m.debugger.basic.listing().map { "\($0.number)\($0.text)" } == ["10 PRINT \"HI\":GOTO 10"])
    }

    @Test func snapshotForTheDebuggerWindow() throws {
        let m = machine()
        try m.debugger.basic.add(BasicBreakpoint(line: 120, condition: "N%=2"))
        #expect(run(m) == .basicBreakpoint(id: 1, cpu: .host, line: 120))
        var view = DebugView()
        view.basic = true
        view.basicExpanded = ["grid%("]
        view.basicWatches = ["N%*10", "nope"]
        let snapshot = try #require(DebugSnapshot(machine: m, view: view).basic)
        #expect(snapshot.interpreters == ["BASIC 2"])
        #expect(snapshot.stop?.line == 120)
        #expect(snapshot.lines.first { $0.number == 120 }?.breakpoints.map(\.id) == [1])
        #expect(snapshot.lines.first { $0.number == 120 }?.text == " T=N%*2")
        #expect(snapshot.frames.map(\.name) == ["PROCadd", nil])
        #expect(snapshot.watches.first?.result == .success(.integer(20)))
        if case .success = snapshot.watches.last?.result { Issue.record("an unknown variable should fail") }
        // DIMmed at line 70, not yet.
        #expect(snapshot.elements.isEmpty)
        view.basic = false
        #expect(DebugSnapshot(machine: m, view: view).basic == nil)
    }

    @Test func hooksOffWithNothingSet() throws {
        let m = machine()
        let basic = m.debugger.basic
        let b = try basic.add(BasicBreakpoint(line: 120))
        #expect(m.debugHooks)
        basic.remove(id: b.id)
        #expect(!m.debugHooks)
    }
}
