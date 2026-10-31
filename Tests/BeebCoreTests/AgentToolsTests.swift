import BeebAgentKit
import BeebCore
import BeebHost
import BeebROMs
import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
import Testing

struct AgentToolsTests {
    func makeTools() -> AgentTools {
        let os = BeebROMs.data(.os12), basic = BeebROMs.data(.basic2), dfs = BeebROMs.data(.dfs12)
        let session = HeadlessSession { BBCMicro(os: os, sidewaysROMs: [15: basic, 14: dfs]) }
        session.machine.runUntilIdle()
        return AgentTools(context: session)
    }

    func text(_ result: ToolResult) -> String {
        result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    @Test func runCommandReturnsOutput() {
        let tools = makeTools()
        let result = tools.call("run_command", arguments: ["text": "PRINT 6*7"])
        #expect(!result.isError)
        #expect(text(result).contains("42"))
    }

    @Test func powerCycleKeepsTheMaster512ToTheMaster() {
        let session = HeadlessSession {
            BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true, coprocessor: .master512,
                                                           systemDisc: false))
        }
        let tools = AgentTools(context: session)
        // Asked for on a B: refused.
        let refused = tools.call("power_cycle", arguments: ["model": "model_b", "coprocessor": "master512"])
        #expect(refused.isError && text(refused).contains("master_128"), "\(text(refused))")
        // Kept from the Master: the B gets a 6502 instead.
        #expect(!tools.call("power_cycle", arguments: ["model": "model_b"]).isError)
        #expect(session.machine.model == .modelB && session.machine.master512 == nil && session.machine.secondProcessor != nil)
    }

    @Test func peekAndPoke() {
        let tools = makeTools()
        #expect(!tools.call("poke", arguments: ["address": "&3000", "bytes": [0x12, 0xAB]]).isError)
        #expect(text(tools.call("peek", arguments: ["address": "&3000", "length": 2])).contains("12 AB"))
        // ROM can be patched; I/O can't be poked.
        #expect(!tools.call("poke", arguments: ["address": "&C000", "bytes": [1]]).isError)
        #expect(text(tools.call("peek", arguments: ["address": "&C000", "length": 1])).contains("C000  01"))
        #expect(tools.call("poke", arguments: ["address": "&FE40", "bytes": [1]]).isError)
    }

    @Test func runUntilAddressStopsThere() {
        let tools = makeTools()
        _ = tools.call("run_command", arguments: ["text": "P%=&3000:[OPT0:.L INX:JMP L:]"])
        _ = tools.call("type_text", arguments: ["text": "CALL &3000\n", "settle_seconds": 0])
        let result = tools.call("run_until_address", arguments: ["address": "&3001"])
        #expect(text(result).contains("reached &3001"))
        #expect(text(tools.call("get_status", arguments: [:])).contains("PC=&3001"))
    }

    @Test func pressKeysAndScreenshot() throws {
        let tools = makeTools()
        _ = tools.call("press_keys", arguments: ["keys": ["SHIFT", "A"]])
        #expect(text(tools.call("read_screen_text", arguments: [:])).contains(">A"))
        let shot = tools.call("screenshot", arguments: [:])
        guard case .png(let data) = try #require(shot.content.first) else {
            Issue.record("no image")
            return
        }
        #expect(data.count > 1000)
    }

    @Test func loadDiscBoots() throws {
        let tools = makeTools()
        let path = testResources.appendingPathComponent("discs/beeb_6502_timing_tests.ssd").path
        let result = tools.call("load_disc", arguments: ["path": .string(path), "max_seconds": 60])
        #expect(!result.isError)
        #expect(text(result).contains("TIMINGS"))
        #expect(text(result).contains("Total: 81"))
    }

    @Test func loadTapeChainsTheProgram() throws {
        let tools = makeTools()
        let path = testResources.appendingPathComponent("tapes/pugwash.uef").path
        let result = tools.call("load_tape", arguments: ["path": .string(path), "max_seconds": 40])
        #expect(!result.isError)
        #expect(text(result).contains("Pugwash Tune"), "\(text(result))")
        #expect(text(tools.call("rewind_tape", arguments: [:])) == "rewound")
    }

    @Test func recording() throws {
        let tools = makeTools()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-agent-test.mp4")
        #expect(!tools.call("start_recording", arguments: ["path": .string(url.path)]).isError)
        _ = tools.call("run_command", arguments: ["text": "PRINT \"RECORDED\""])
        _ = tools.call("run", arguments: ["seconds": 1])
        #expect(text(tools.call("stop_recording", arguments: [:])) == "recording finished")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 10_000)
    }

    @Test func mcpProtocol() {
        let server = MCPServer(tools: makeTools(), instructions: "test")
        let initialize = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                        "params": ["protocolVersion": "2025-06-18"]])
        #expect(initialize?["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let list = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        #expect((list?["result"]?["tools"]?.arrayValue?.count ?? 0) > 15)
        let unknown = server.handle(["jsonrpc": "2.0", "id": 3, "method": "nope"])
        #expect(unknown?["error"]?["code"]?.intValue == -32601)
    }
}

struct AgentSnapshotTests {
    @Test func snapshotAndRestore() {
        let tools = AgentToolsTests().makeTools()
        _ = tools.call("run_command", arguments: ["text": "A%=1"])
        _ = tools.call("save_snapshot", arguments: ["name": "before"])
        _ = tools.call("run_command", arguments: ["text": "A%=2"])
        let restored = tools.call("restore_snapshot", arguments: ["name": "before"])
        #expect(!restored.isError)
        let output = AgentToolsTests().text(tools.call("run_command", arguments: ["text": "PRINT A%"]))
        #expect(output.contains("         1"))
    }

    /// The TV is new after a restore; the screenshot still shows the screen,
    /// and taking it doesn't move the machine.
    @Test func screenshotAfterRestoreIsntBlank() throws {
        let os = BeebROMs.data(.os12), basic = BeebROMs.data(.basic2), dfs = BeebROMs.data(.dfs12)
        let session = HeadlessSession { BBCMicro(os: os, sidewaysROMs: [15: basic, 14: dfs]) }
        session.machine.runUntilIdle()
        let tools = AgentTools(context: session)
        _ = tools.call("save_snapshot", arguments: [:])
        #expect(!tools.call("restore_snapshot", arguments: [:]).isError)
        let cycles = session.machine.cycles
        let shot = tools.call("screenshot", arguments: [:])
        guard case .png(let data) = try #require(shot.content.first) else {
            Issue.record("no image")
            return
        }
        #expect(session.machine.cycles == cycles)
        #if canImport(ImageIO)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = try #require(image.dataProvider?.data as Data?)
        #else
        let image = try #require(PNGDecoding.decode(data))
        let pixels = image.pixels.withUnsafeBytes { Data($0) }
        #endif
        // Opaque black is one 0xFF (alpha) in four bytes; the text adds more.
        #expect(pixels.count { $0 != 0 } > pixels.count / 4, "the screenshot is all black")
    }
}

/// Additions from using the tools for real: memory screenshots, files,
/// timing and scripted keys.
struct AgentToolAdditionsTests {
    let support = AgentToolsTests()

    func png(_ result: ToolResult) throws -> Data {
        guard case .png(let data) = try #require(result.content.first) else {
            Issue.record("no image: \(support.text(result))")
            return Data()
        }
        return data
    }

    func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AgentToolAdditionsTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    /// A memory screenshot shows a poke straight away, while the TV doesn't
    /// change until the machine runs; neither moves the machine.
    @Test func screenshotFromMemory() throws {
        let tools = support.makeTools()
        let tv = try png(tools.call("screenshot", arguments: [:]))
        let before = try png(tools.call("screenshot", arguments: ["source": "memory"]))
        let cycles = support.text(tools.call("registers", arguments: [:]))
        #expect(!tools.call("poke", arguments: ["address": "&7C00", "bytes": .array(Array(repeating: 0x41, count: 40))]).isError)
        let after = try png(tools.call("screenshot", arguments: ["source": "memory"]))
        #expect(before != after)
        #expect(try png(tools.call("screenshot", arguments: [:])) == tv)
        #expect(!(try png(tools.call("screenshot", arguments: ["source": "beam"]))).isEmpty)
        #expect(support.text(tools.call("registers", arguments: [:])) == cycles)
    }

    @Test func clearingSymbolsKeepsTheOtherCPUs() throws {
        let tools = support.makeTools()
        let file = scratch("labels.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "HOSTLABEL = $1234\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!tools.call("load_symbols", arguments: ["path": .string(file.path)]).isError)
        try "PARALABEL = $5678\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!tools.call("load_symbols", arguments: ["path": .string(file.path), "cpu": "parasite", "clear": true]).isError)
        #expect(support.text(tools.call("lookup_symbol", arguments: ["name": "HOSTLABEL"])).contains("&1234"))
        #expect(support.text(tools.call("lookup_symbol", arguments: ["name": "PARALABEL", "cpu": "parasite"])).contains("&5678"))
    }

    @Test func peekToAFile() throws {
        let tools = support.makeTools()
        _ = tools.call("poke", arguments: ["address": "&3000", "bytes": [1, 2, 3]])
        let file = scratch("dumps/screen.bin")
        let result = tools.call("peek", arguments: ["address": "&3000", "length": 8192, "path": .string(file.path)])
        #expect(!result.isError, "\(support.text(result))")
        let bytes = [UInt8](try Data(contentsOf: file))
        #expect(bytes.count == 8192 && Array(bytes.prefix(3)) == [1, 2, 3])
    }

    /// LDX #5, DEX/BNE five times, JMP back: 2 + (5*2 + 4*3 + 2) + 3 = 29
    /// cycles a trip, more if an interrupt comes in the middle.
    @Test func measureCyclesRoundALoop() {
        let tools = support.makeTools()
        _ = tools.call("run_command", arguments: ["text": "P%=&3000:[OPT0:.L LDX #5:.M DEX:BNE M:JMP L:]"])
        _ = tools.call("type_text", arguments: ["text": "CALL &3000\n", "settle_seconds": 0])
        let result = support.text(tools.call("measure_cycles", arguments: ["from": "&3000", "to": "&3000", "repeat": 20]))
        #expect(result.contains("min 29 cycles"), "\(result)")
        // LDX to the JMP: 2 + 24.
        let part = support.text(tools.call("measure_cycles", arguments: ["from": "&3000", "to": "&3005", "repeat": 20]))
        #expect(part.contains("min 26 cycles"), "\(part)")
    }

    @Test func keySequenceTypesInOrder() {
        let tools = support.makeTools()
        let result = tools.call("key_sequence", arguments: ["events": [
            ["at_frame": 0, "down": ["SHIFT"]],
            ["at_frame": 2, "down": ["A"]],
            ["at_frame": 6, "up": ["A"]],
            ["at_frame": 8, "up": ["SHIFT"]],
            ["at_frame": 12, "down": ["B"]],
            ["at_frame": 16, "up": ["B"]],
        ]])
        #expect(!result.isError)
        // Caps Lock is on, so SHIFT+A is still A.
        #expect(support.text(result).hasSuffix(">AB"), "\(support.text(result))")
    }

    @Test func recordingMakesItsFolder() {
        let tools = support.makeTools()
        let file = scratch("new/folder/clip.mp4")
        let started = tools.call("start_recording", arguments: ["path": .string(file.path)])
        #expect(!started.isError, "\(support.text(started))")
        _ = tools.call("run", arguments: ["frames": 10])
        #expect(!tools.call("stop_recording", arguments: [:]).isError)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}


/// The hardware tools: discovering, fitting and loading sideways RAM.
struct AgentHardwareToolsTests {
    let support = AgentToolsTests()

    func modelBTools() -> (AgentTools, HeadlessSession) {
        let session = HeadlessSession { BBCMicro(configuration: BeebROMs.configuration(for: .modelB)) }
        session.machine.runUntilIdle()
        return (AgentTools(context: session), session)
    }

    @Test func stockModelBHasNoBoard() {
        let (tools, _) = modelBTools()
        let text = support.text(tools.call("get_hardware", arguments: [:]))
        #expect(text.contains("memory board: none (None (stock Model B))"), "\(text)")
        #expect(text.contains("15  ROM, Motherboard socket: BASIC"), "\(text)")
        #expect(text.contains("12  empty socket, Motherboard socket"), "\(text)")
    }

    /// Fit a 32K board, load a ROM into it from a file, Break, and run it;
    /// read it back physically and logically.
    @Test func fitLoadBreakAndRun() throws {
        let (tools, session) = modelBTools()
        let fitted = tools.call("power_cycle", arguments: ["memory_board": "sideways_ram_32", "second_bank_below": 8])
        #expect(!fitted.isError, "\(support.text(fitted))")
        let hardware = support.text(tools.call("get_hardware", arguments: [:]))
        #expect(hardware.contains("sideways RAM module: 32k (Sideways RAM 32K) in socket 13, second bank 8 below; banks 13 and 5"), "\(hardware)")
        #expect(hardware.contains("13  RAM, 32K sideways RAM module, writable when selected: no ROM image"), "\(hardware)")

        let rom = testResources.appendingPathComponent("expansions/hello.rom").path
        let loaded = support.text(tools.call("load_sideways_bank", arguments: ["bank": 5, "path": .string(rom)]))
        #expect(loaded.contains("a ROM image, MacBeeb Hello 1.00"), "\(loaded)")
        // Physical read of bank 5 while BASIC (15) is paged in.
        #expect(support.text(tools.call("peek", arguments: ["address": "&8009", "length": 7, "space": "bank5"])).contains("MacBeeb"))
        // The CPU's view has BASIC paged in.
        #expect(support.text(tools.call("peek", arguments: ["address": "&8009", "length": 7, "space": "host"])).contains("BASIC"))

        #expect(!tools.call("press_break", arguments: ["ctrl": true]).isError)
        let output = support.text(tools.call("run_command", arguments: ["text": "*HELLO"]))
        #expect(output.contains("Hello from sideways RAM bank 5"), "\(output)")

        // Power cycling keeps the board (and clears its RAM, as switching off would).
        _ = tools.call("power_cycle", arguments: [:])
        #expect(session.machine.configuration.expansions.sidewaysRAM == .ram32)
        #expect(session.machine.sidewaysSlots[5].header == nil)
    }

    @Test func plainBreakAlsoFindsANewROM() throws {
        let (tools, _) = modelBTools()
        _ = tools.call("power_cycle", arguments: ["memory_board": "sideways_ram_16"])
        let rom = testResources.appendingPathComponent("expansions/hello.rom").path
        _ = tools.call("load_sideways_bank", arguments: ["bank": 13, "path": .string(rom)])
        _ = tools.call("press_break", arguments: [:])
        let output = support.text(tools.call("run_command", arguments: ["text": "*HELLO"]))
        // OS 1.20 scans the sideways banks on every Break, not just a hard one.
        #expect(output.contains("Hello from sideways RAM bank 13"), "\(output)")
    }

    @Test func watfordBoardOverMCP() {
        let (tools, _) = modelBTools()
        #expect(!tools.call("power_cycle", arguments: ["memory_board": "watford_32k"]).isError)
        let hardware = support.text(tools.call("get_hardware", arguments: [:]))
        #expect(hardware.contains("controller ROM: Shadow RAM OS 2.40 (bundled) in bank 13, SHA-256 a2e7c05f"), "\(hardware)")
        #expect(hardware.contains("watford latch:"), "\(hardware)")
        let himem = support.text(tools.call("run_command", arguments: ["text": "MODE 1:PRINT ~HIMEM"]))
        #expect(himem.contains("8000"), "\(himem)")
        _ = tools.call("run_command", arguments: ["text": "*FX34,1"])
        _ = tools.call("run_command", arguments: ["text": "?&5000=&42"])
        #expect(support.text(tools.call("peek", arguments: ["address": "&5000", "length": 1, "space": "board"])).contains("5000  42"))
        #expect(!support.text(tools.call("peek", arguments: ["address": "&5000", "length": 1, "space": "main"])).contains("5000  42"))
        #expect(support.text(tools.call("memory_regions", arguments: [:])).contains("Watford board RAM"))
    }

    @Test func ariesOverMCP() {
        let (tools, session) = modelBTools()
        #expect(!tools.call("power_cycle", arguments: ["memory_board": "aries_b32_b12"]).isError)
        let hardware = support.text(tools.call("get_hardware", arguments: [:]))
        for text in ["controller ROM: ARIES-B32 1.00 (bundled) in bank 15", "aries: 20K shadow (&3000–&7FFF) + 12K sideways RAM",
                     "13  RAM, Aries B32 RAM (shared with shadow RAM), written while *RWRITE (&FE32) selects it",
                     " 0  RAM, Aries B12 RAM (0L and 0H)", "12  ROM, Aries B12 socket: BASIC (language)"] {
            #expect(hardware.contains(text), "\(text) in \(hardware)")
        }
        let status = support.text(tools.call("run_command", arguments: ["text": "*XSTATUS X"]))
        #expect(status.contains("Current shadow RAM: 20K"), "\(status)")
        // The B32's RAM can be loaded from outside too, and read physically.
        let rom = testResources.appendingPathComponent("expansions/hello.rom").path
        #expect(!tools.call("load_sideways_bank", arguments: ["bank": 14, "path": .string(rom)]).isError)
        #expect(support.text(tools.call("peek", arguments: ["address": "&8009", "length": 7, "space": "bankE"])).contains("MacBeeb"))
        #expect(support.text(tools.call("peek", arguments: ["address": "&4009", "length": 7, "space": "board"])).contains("MacBeeb"))
        _ = tools.call("press_break", arguments: [:])
        #expect(support.text(tools.call("run_command", arguments: ["text": "*HELLO"])).contains("bank 14"))
        // Without the link.
        #expect(!tools.call("power_cycle", arguments: ["aries_start_up_link": false]).isError)
        #expect(session.machine.configuration.expansions.ariesStartUpLink == false)
        #expect(support.text(tools.call("run_command", arguments: ["text": "*XSTATUS X"])).contains("Start-up link: OFF"))
    }

    /// A board and a module together; the B12 refuses one.
    @Test func boardAndModuleOverMCP() {
        let (tools, session) = modelBTools()
        let fitted = tools.call("power_cycle", arguments: ["memory_board": "watford_32k", "sideways_ram": "16k", "sideways_ram_socket": 12])
        #expect(!fitted.isError, "\(support.text(fitted))")
        let hardware = support.text(tools.call("get_hardware", arguments: [:]))
        for text in ["memory board: watford_32k", "sideways RAM module: 16k (Sideways RAM 16K) in socket 12; bank 12",
                     "memory: 32K main RAM + 48K on expansions", "in bank 13"] {
            #expect(hardware.contains(text), "\(text) in \(hardware)")
        }
        let aries = tools.call("power_cycle", arguments: ["memory_board": "aries_b32", "sideways_ram": "32k", "sideways_ram_socket": 13])
        #expect(!aries.isError, "\(support.text(aries))")
        let ariesHardware = support.text(tools.call("get_hardware", arguments: [:]))
        #expect(ariesHardware.contains("banks 9 and 5 (with the Aries B32's renumbering"), "\(ariesHardware)")
        #expect(ariesHardware.contains("writable when selected while *RWRITE EXTERNAL is set"), "\(ariesHardware)")
        let b12 = tools.call("power_cycle", arguments: ["memory_board": "aries_b32_b12"])
        #expect(b12.isError && support.text(b12).contains("all four motherboard ROM sockets"), "\(support.text(b12))")
        #expect(session.machine.configuration.expansions.board == .ariesB32)
        #expect(!tools.call("power_cycle", arguments: ["memory_board": "aries_b32_b12", "sideways_ram": "none"]).isError)
    }

    @Test func errorsExplainThemselves() throws {
        let (tools, _) = modelBTools()
        let rom = testResources.appendingPathComponent("expansions/hello.rom").path
        let noRAM = tools.call("load_sideways_bank", arguments: ["bank": 13, "path": .string(rom)])
        #expect(noRAM.isError && support.text(noRAM).contains("there's no sideways RAM"), "\(support.text(noRAM))")
        _ = tools.call("power_cycle", arguments: ["memory_board": "sideways_ram_16"])
        let rom15 = tools.call("load_sideways_bank", arguments: ["bank": 15, "path": .string(rom)])
        #expect(rom15.isError && support.text(rom15).contains("Bank 15 isn't sideways RAM. Sideways RAM: banks 13"), "\(support.text(rom15))")
        let badSocket = tools.call("power_cycle", arguments: ["sideways_ram_socket": 15])
        #expect(badSocket.isError && support.text(badSocket).contains("the leftmost (12) or the next (13)"))
        let master = tools.call("power_cycle", arguments: ["model": "master_128", "memory_board": "sideways_ram_16"])
        #expect(master.isError && support.text(master).contains("model_b only"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bank-\(UUID().uuidString).rom")
        #expect(!tools.call("save_sideways_bank", arguments: ["bank": 15, "path": .string(file.path)]).isError)
        #expect(try Data(contentsOf: file).count == 16384)
    }
}
