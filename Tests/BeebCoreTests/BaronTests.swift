import Foundation
import Testing
@testable import BeebAgentKit
@testable import BeebCore
@testable import BeebHost
import BeebROMs

struct BaronTests {
    var resources: String { Bundle.module.resourceURL!.appendingPathComponent("Resources/baron").path }
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    func line(_ table: SymbolTable, _ address: UInt16) -> String? {
        table.location(at: address).map { "\(($0.file as NSString).lastPathComponent):\($0.line)" }
    }

    @Test func symbols() throws {
        // Captured from baron -v --symbols features.json for features.6502.
        let json = try Data(contentsOf: URL(fileURLWithPath: "\(resources)/features.json"))
        let dump = try #require(BaronSymbols(json, directory: resources))
        #expect(dump.savedFiles == ["FEAT"])
        #expect(dump.sources == ["\(resources)/features.6502", "\(resources)/features-inc.6502"])
        let t = dump.table
        #expect(t.address(of: "outer") == 0x1900 && t.address(of: "outer.inner") == 0x1900 && t.address(of: "included") == 0x191A)
        // Scoped labels by their own name too; constants by name only.
        #expect(t.address(of: "inner") == 0x1900)
        #expect(t.address(of: "CONST") == 42 && !t.names(at: 42).contains("CONST"))
        // Loop variables are Baron's internals.
        #expect(t.address(of: "n") == nil)
        #expect(dump.loops[SourceLocation(file: "\(resources)/features.6502", line: 23)] == 3)
        #expect(dump.loops[SourceLocation(file: "\(resources)/features.6502", line: 25)] == 6)
    }

    @Test func listingLinesUp() throws {
        let json = try Data(contentsOf: URL(fileURLWithPath: "\(resources)/features.json"))
        let listing = try String(contentsOfFile: "\(resources)/features.lst", encoding: .utf8)
        let t = SymbolTable.baron(symbols: json, listings: [("features.6502", listing)], directory: resources)
        let expected: [UInt16: String] = [
            0x1900: "features.6502:18", 0x1902: "features.6502:19",
            // Nested FOR loops: each pass to the body.
            0x1903: "features.6502:24", 0x1904: "features.6502:26", 0x1905: "features.6502:26",
            0x1906: "features.6502:24", 0x1907: "features.6502:26", 0x1908: "features.6502:26",
            0x1909: "features.6502:24", 0x190A: "features.6502:26", 0x190B: "features.6502:26",
            // A label and two statements on one line, then the same twice.
            0x190C: "features.6502:29", 0x190E: "features.6502:29", 0x1910: "features.6502:30", 0x1911: "features.6502:30",
            // Macros: their own lines (the call's line also gets the first).
            0x1912: "features.6502:6", 0x1913: "features.6502:7", 0x1914: "features.6502:11", 0x1915: "features.6502:11",
            0x1917: "features.6502:6", 0x1918: "features.6502:7", 0x1919: "features.6502:36",
            // An included file (with an INY in a comment, which isn't code).
            0x191A: "features-inc.6502:3", 0x191C: "features-inc.6502:4",
        ]
        for (address, place) in expected {
            #expect(line(t, address) == place, "&\(String(address, radix: 16))")
        }
        #expect(t.addresses(file: "features.6502", line: 33)?.addresses == [0x1912])
        #expect(t.addresses(file: "features.6502", line: 35)?.addresses == [0x1917])
        #expect(t.addresses(file: "features.6502", line: 24)?.addresses.sorted() == [0x1903, 0x1906, 0x1909])
    }

    @Test func outputSwitchesAreMacBeebs() {
        #expect(Baron.userArguments(["-D", "X=1", "-o", "a.ssd", "-v", "--opt", "3", "-log0", "l.txt", "--symbols", "s.json", "-p", "."])
                == ["-D", "X=1", "--opt", "3"])
    }

    // With baron available (make baron, or on the PATH): the real thing.
    static let baron = Baron.locate(ProcessInfo.processInfo.environment["MACBEEB_BARON"])

    @Test(.enabled(if: baron != nil))
    func assemblesAndRuns() throws {
        let example = Self.repository.appendingPathComponent("Examples/hello-baron/hello.6502").path
        let build = try Baron.assemble(sources: [example], baron: Self.baron)
        #expect(build.savedFiles == ["HELLO"] && build.bootOption == 0)
        #expect(build.symbols.address(of: "print") == 0x2011)
        #expect(build.symbols.addresses(file: example, line: 22)?.addresses == [0x2011])

        let session = HeadlessSession { BBCMicro(configuration: BeebROMs.configuration(for: .modelB)) }
        session.machine.runUntilIdle()
        let tools = AgentTools(context: session)
        func text(_ r: ToolResult) -> String { r.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined() }
        let run = text(tools.call("assemble_baron", arguments: ["sources": .array([.string(example)]), "baron": .string(Self.baron!)]))
        #expect(run.contains("HELLO WORLD"), "\(run)")
        #expect(text(tools.call("set_breakpoint", arguments: ["address": "hello.6502:22"])).hasPrefix("breakpoint 1: execute &2011"))
        let stop = text(tools.call("run_command", arguments: ["text": "*RUN HELLO"]))
        #expect(stop.contains("stopped in the debugger: breakpoint 1"), "\(stop)")

        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID()).6502")
        try "SECTION X, org=&2000, filename=\"X\"\n LDQ #1\nENDSECTION\n".write(to: broken, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: broken) }
        #expect(throws: Baron.BuildError.self) { try Baron.assemble(sources: [broken.path], baron: Self.baron) }
    }

    /// Baron's own examples: several files to a bootable disc, includes,
    /// macros, loops, inline BASIC, zero-page allocation.
    @Test(.enabled(if: baron != nil && FileManager.default.fileExists(atPath: repository.appendingPathComponent("ThirdParty/baron/examples").path)),
          // (The compressors are alternatives, all at &1900, so one at a time.)
          arguments: [("starglobe", ["boot.6502", "loader.6502", "demo.6502"]), ("compress", ["boot.6502", "compress_zx02.6502"]),
                      ("compress", ["compress_lz.6502"]), ("compress", ["compress_exomizer.6502"]), ("compress", ["compress_exolite.6502"])])
    func baronsExamples(_ name: String, _ files: [String]) throws {
        let directory = Self.repository.appendingPathComponent("ThirdParty/baron/examples/\(name)").path
        let build = try Baron.assemble(sources: files.map { "\(directory)/\($0)" }, arguments: ["--opt", "3"], baron: Self.baron)
        #expect(build.bootOption == 3)
        if files[0] == "boot.6502" { #expect(build.savedFiles.first == "!BOOT") }
        // Every instruction has a line, and it's the line with that
        // statement on it.
        for (index, file) in files.enumerated() {
            let listing = try listing(of: "\(directory)/\(file)", index: index)
            var missing: [String] = []
            for item in BaronAligner.items(listing) {
                guard case .code(let address, let text) = item, !text.first!.isNumber else { continue }  // (not inline BASIC)
                guard let location = build.symbols.location(at: address),
                      let source = try? String(contentsOfFile: location.file, encoding: .utf8) else {
                    missing.append("&\(String(address, radix: 16)) \(text)")
                    continue
                }
                let sourceLine = source.components(separatedBy: "\n")[location.line - 1]
                if !sourceLine.contains(text) { missing.append("&\(String(address, radix: 16)) \(text) at \(location)") }
            }
            #expect(missing.isEmpty, "\(file): \(missing.prefix(10))")
        }
    }

    private func listing(of source: String, index: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.baron!)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("baron-\(UUID()).ssd")
        defer { try? FileManager.default.removeItem(at: out) }
        process.arguments = ["-v", "-o", out.path, source]
        process.currentDirectoryURL = URL(fileURLWithPath: (source as NSString).deletingLastPathComponent)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
