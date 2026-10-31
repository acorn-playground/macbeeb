import Foundation
import Testing
@testable import BeebAgentKit
@testable import BeebCore
import BeebHost
import BeebROMs

struct BeebAsmTests {
    var resources: String { testResources.appendingPathComponent("beebasm").path }

    func table(_ name: String) throws -> SymbolTable {
        let listing = try String(contentsOfFile: "\(resources)/\(name).lst", encoding: .utf8)
        let labels = try String(contentsOfFile: "\(resources)/\(name).labels", encoding: .utf8)
        return SymbolTable.beebAsm(listing: listing, symbols: labels, source: "\(resources)/\(name).asm")
    }

    func line(_ table: SymbolTable, _ address: UInt16) -> String? {
        table.location(at: address).map { "\(($0.file as NSString).lastPathComponent):\($0.line)" }
    }

    @Test func symbolDump() {
        let table = SymbolTable.parse("[{'.outer':6400L,'.outer.inner':6401L,'.a.x':1L,'.b.x':2L,'start':8192L}]")
        #expect(table.address(of: "outer") == 6400 && table.address(of: "start") == 8192)
        #expect(table.address(of: "outer.inner") == 6401)
        // Short names for scoped labels, unless they're ambiguous.
        #expect(table.address(of: "inner") == 6401 && table.address(of: "x") == nil)
    }

    @Test func helloLinesUp() throws {
        // Captured from beebasm -v -dd for Examples/hello-beebasm.
        let t = try table("hello")
        #expect(t.address(of: "print") == 0x2011 && t.address(of: "message") == 0x2017)
        let expected: [UInt16: Int] = [0x2000: 10, 0x2002: 12, 0x2005: 13, 0x2007: 14, 0x200A: 15, 0x200B: 16,
                                       0x200D: 18, 0x2010: 19, 0x2011: 23, 0x2014: 24]
        for (address, number) in expected {
            #expect(line(t, address) == "hello.asm:\(number)", "&\(String(address, radix: 16))")
        }
        #expect(t.addresses(file: "hello.asm", line: 21)?.addresses == [0x2011])
    }

    @Test func scopesLoopsMacrosAndIncludes() throws {
        let t = try table("features")
        let expected: [UInt16: String] = [
            0x1900: "features.asm:9", 0x1902: "features.asm:10",
            // FOR loop: each pass to the body.
            0x1903: "features.asm:15", 0x1904: "features.asm:16", 0x1905: "features.asm:15",
            0x1906: "features.asm:16", 0x1907: "features.asm:15", 0x1908: "features.asm:16",
            // Label and two statements on one line.
            0x1909: "features.asm:18", 0x190B: "features.asm:18",
            // Macro: its own lines (the call's line also gets the first).
            0x190D: "features.asm:21", 0x190E: "features.asm:22", 0x190F: "features.asm:27",
            0x1910: "features-inc.asm:3", 0x1912: "features-inc.asm:4",
        ]
        for (address, place) in expected {
            #expect(line(t, address) == place, "&\(String(address, radix: 16))")
        }
        #expect(t.addresses(file: "features.asm", line: 26)?.addresses == [0x190D])
        #expect(t.addresses(file: "features.asm", line: 15)?.addresses.sorted() == [0x1903, 0x1905, 0x1907])
        #expect(t.address(of: "inner") == 0x1900 && t.address(of: "included") == 0x1910)
    }

    @Test func statements() {
        #expect(BeebAsmAligner.splitStatements(".x LDA #1:STA &70 \\ comment") == [".x LDA #1", "STA &70"])
        #expect(BeebAsmAligner.splitStatements("EQUS \"a:b;c\" ; note") == ["EQUS \"a:b;c\""])
    }

    // With beebasm available (make beebasm, or on the PATH): the real thing.
    static let beebasm = BeebAsm.locate(ProcessInfo.processInfo.environment["MACBEEB_BEEBASM"])

    @Test(.enabled(if: beebasm != nil))
    func assemblesAndRuns() throws {
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Examples/hello-beebasm/hello.asm").path
        let build = try BeebAsm.assemble(source: example, beebasm: Self.beebasm)
        #expect(build.savedFiles == ["HELLO"])
        #expect(build.symbols.addresses(file: example, line: 23)?.addresses == [0x2011])

        let session = HeadlessSession { BBCMicro(configuration: BeebROMs.configuration(for: .modelB)) }
        session.machine.runUntilIdle()
        let tools = AgentTools(context: session)
        func text(_ r: ToolResult) -> String { r.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined() }
        _ = tools.call("set_breakpoint", arguments: ["address": "hello.asm:23"]) // fails: no symbols yet
        let run = text(tools.call("assemble", arguments: ["source": .string(example), "beebasm": .string(Self.beebasm!)]))
        #expect(run.contains("HELLO WORLD"), "\(run)")
        #expect(text(tools.call("set_breakpoint", arguments: ["address": "hello.asm:23"])).hasPrefix("breakpoint 1: execute &2011"))
        let stop = text(tools.call("run_command", arguments: ["text": "*RUN HELLO"]))
        #expect(stop.contains("stopped in the debugger: breakpoint 1"), "\(stop)")

        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID()).asm")
        try "ORG &2000\n.x LDQ #1\nSAVE \"X\", x, x+2\n".write(to: broken, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: broken) }
        #expect(throws: BeebAsm.BuildError.self) { try BeebAsm.assemble(source: broken.path, beebasm: Self.beebasm) }
    }
}
