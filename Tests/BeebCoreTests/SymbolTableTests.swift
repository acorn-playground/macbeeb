import Foundation
import Testing
@testable import BeebAgentKit
@testable import BeebCore
import BeebHost
import BeebROMs

struct SymbolTableTests {
    var resources: String { testResources.appendingPathComponent("symbols").path }

    @Test func ld65DebugInfo() throws {
        // Made by Examples/hello-ca65's Makefile (ca65 -g, ld65 --dbgfile).
        let table = try SymbolTable.load(path: resources + "/hello.dbg")
        #expect(table.address(of: "start") == 0x2000)
        #expect(table.address(of: "print") == 0x2011)
        #expect(table.address(of: "count") == 0x2023)
        #expect(table.name(at: 0x2011) == "print")
        // ca65's predefined CPU_ constants aren't symbols; equates don't
        // name addresses.
        #expect(table.address(of: "CPU_6502") == nil)
        #expect(table.address(of: "OSWRCH") == 0xFFEE && table.name(at: 0xFFEE) == nil)

        let source = resources + "/hello.s"
        #expect(table.location(at: 0x2000) == SourceLocation(file: source, line: 9))
        #expect(table.location(at: 0x2014) == SourceLocation(file: source, line: 20))
        #expect(table.addresses(file: "hello.s", line: 12)?.addresses == [0x2007])
        // A line with no code moves to the next that has some.
        let moved = table.addresses(file: source, line: 17)
        #expect(moved?.line == 19 && moved?.addresses == [0x2011])
        #expect(table.addresses(file: "other.s", line: 1) == nil)
    }

    @Test func labelFiles() throws {
        let ld65 = try SymbolTable.load(path: resources + "/hello.lbl")
        #expect(ld65.symbolCount == 6 && ld65.address(of: "loop") == 0x2002)

        let table = SymbolTable.parse("""
            main = $1900
            foo=&2000
            .bar $3000
            baz EQU $4000
            al C:5000 .qux
            ; a comment
            Mixed: $6000
            """)
        #expect(table.address(of: "main") == 0x1900)
        #expect(table.address(of: "foo") == 0x2000)
        #expect(table.address(of: "bar") == 0x3000)
        #expect(table.address(of: "baz") == 0x4000)
        #expect(table.address(of: "qux") == 0x5000)
        #expect(table.address(of: "mixed") == 0x6000)
        #expect(throws: SymbolTable.LoadError.self) { try SymbolTable.load(path: "/nonexistent") }
    }

    @Test func builtInsAndAnnotation() {
        var table = SymbolTable.builtIn(model: .master128, cpu: .host)
        #expect(table.address(of: "OSWRCH") == 0xFFEE && table.address(of: "wrchv") == 0x20E)
        #expect(table.address(of: "ACCCON") == 0xFE34 && table.address(of: "SYSVIA_IFR") == 0xFE4D)
        #expect(SymbolTable.builtIn(model: .modelB, cpu: .host).address(of: "ACCCON") == nil)
        #expect(SymbolTable.builtIn(model: .modelB, cpu: .parasite).address(of: "TUBE_R1DATA") == 0xFEF9)
        table.add("print", 0x2011)
        #expect(table.annotate("JSR $2011") == "JSR print")
        #expect(table.annotate("JMP ($020E)") == "JMP (WRCHV)")
        #expect(table.annotate("LDA $70") == "LDA $70")
        #expect(table.annotate("LDA $1234,X") == "LDA $1234,X")
        #expect(table.nearest(below: 0x2015)! == ("print", 4))
    }

    @Test func newSymbolsReplaceOld() {
        var table = SymbolTable()
        var first = SymbolTable()
        first.add("print", 0x2011)
        first.addLine(SourceLocation(file: "/a.asm", line: 23), address: 0x2011)
        first.addLine(SourceLocation(file: "/a.asm", line: 30), address: 0x2020)
        table.merge(first)
        // A rebuild: print moved, and line 30 has gone.
        var rebuilt = SymbolTable()
        rebuilt.add("print", 0x2014)
        rebuilt.addLine(SourceLocation(file: "/a.asm", line: 24), address: 0x2014)
        table.merge(rebuilt)
        #expect(table.address(of: "print") == 0x2014 && table.name(at: 0x2011) == nil)
        #expect(table.location(at: 0x2020) == nil && table.addresses(file: "/a.asm", line: 23)?.line == 24)
        // Another program at the same address takes it over.
        var other = SymbolTable()
        other.addLine(SourceLocation(file: "/b.s", line: 19), address: 0x2014)
        table.merge(other)
        #expect(table.location(at: 0x2014)?.file == "/b.s")
    }

    @Test func debuggingWithSourceLines() throws {
        let session = HeadlessSession { BBCMicro(configuration: BeebROMs.configuration(for: .modelB)) }
        session.machine.runUntilIdle()
        let tools = AgentTools(context: session)
        func text(_ result: ToolResult) -> String {
            result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
        }
        let binary = try [UInt8](Data(contentsOf: URL(fileURLWithPath: resources + "/hello.bin")))
        session.machine.load(binary, at: 0x2000)
        let loaded = text(tools.call("load_symbols", arguments: ["path": .string(resources + "/hello.dbg")]))
        #expect(loaded.hasPrefix("loaded 8 symbols"), "\(loaded)")
        // Break at the print routine's source line, by name.
        #expect(!tools.call("set_breakpoint", arguments: ["address": "hello.s:19"]).isError)
        let stop = text(tools.call("run_command", arguments: ["text": "CALL &2000"]))
        #expect(stop.contains("stopped in the debugger: breakpoint 1 (execute &2011)"), "\(stop)")
        let registers = text(tools.call("registers", arguments: [:]))
        #expect(registers.contains("A=&48"), "\(registers)") // "H"
        let code = text(tools.call("disassemble", arguments: ["count": 2]))
        #expect(code.contains("print:") && code.contains("INC count") && code.contains("; hello.s:19"), "\(code)")
        #expect(code.contains("JMP OSWRCH"), "\(code)")
        #expect(text(tools.call("lookup_symbol", arguments: ["address": "&2015"])).contains("print+4"))
        #expect(text(tools.call("lookup_symbol", arguments: ["name": "message"])).contains("&2017"))
    }
}
