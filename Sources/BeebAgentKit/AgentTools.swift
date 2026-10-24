import BeebCapture
import BeebCore
import BeebHost
import BeebROMs
import Foundation
import Synchronization

/// A tool's result, in MCP's content model.
public struct ToolResult: Sendable {
    public enum Content: Sendable {
        case text(String)
        case png(Data)
    }

    public var content: [Content]
    public var isError: Bool

    public static func text(_ text: String) -> ToolResult { ToolResult(content: [.text(text)], isError: false) }
    public static func error(_ text: String) -> ToolResult { ToolResult(content: [.text(text)], isError: true) }
}

public struct ToolDefinition: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
}

struct ToolFailure: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// The tools an agent uses to drive a BBC Micro. All time is emulated time,
/// so waits are exact and run as fast as the host can manage.
public final class AgentTools: Sendable {
    /// The machine a call without `machine` drives, found when it's made.
    let defaultContext: @Sendable () -> MachineContext?
    /// The app's other machines (Network Studio stations), if any.
    let directory: MachineDirectory?
    /// Named in-memory snapshots, for quick experiments.
    static let slots = Mutex<[String: SaveStateFile]>([:])

    public init(context: MachineContext) {
        defaultContext = { context }
        directory = nil
    }

    public init(defaultContext: @escaping @Sendable () -> MachineContext?, directory: MachineDirectory?) {
        self.defaultContext = defaultContext
        self.directory = directory
    }

    public func call(_ name: String, arguments: JSONValue) -> ToolResult {
        if Self.networkToolNames.contains(name) {
            guard let directory else {
                return .error("not_available: \(name) works with MacBeeb's Network Studio; connect to the app (macbeeb-mcp --attach)")
            }
            return directory.networkTool(name, arguments: arguments)
        }
        guard let tool = Self.tools.first(where: { $0.definition.name == name }) else {
            return .error("unknown tool \(name)")
        }
        let context: MachineContext
        if let machine = arguments["machine"]?.stringValue {
            guard let directory else {
                return .error("not_found: there's only the one machine here; leave `machine` out")
            }
            switch directory.context(for: machine) {
            case .success(let found): context = found
            case .failure(let error): return .error(error.message)
            }
        } else if let standalone = defaultContext() {
            context = standalone
        } else {
            return .error("no_machine: there's no standalone machine window; name a station with `machine` (list_machines)")
        }
        do {
            return try tool.run(context, arguments)
        } catch let failure as ToolFailure {
            return .error(failure.message)
        } catch {
            return .error("\(error)")
        }
    }

    /// Every tool: each machine tool takes `machine` too.
    public static var definitions: [ToolDefinition] {
        tools.map { tool in
            var definition = tool.definition
            if case .object(var schema) = definition.inputSchema, case .object(var properties)? = schema["properties"] {
                properties["machine"] = machineProperty
                schema["properties"] = .object(properties)
                definition.inputSchema = .object(schema)
            }
            return definition
        } + networkToolDefinitions
    }

    struct Tool: Sendable {
        var definition: ToolDefinition
        var run: @Sendable (MachineContext, JSONValue) throws -> ToolResult
    }

    static func schema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    static let agentModels: [String: BBCMicro.Model] = ["model_a": .modelA, "model_b": .modelB, "b_plus": .bPlus, "master_128": .master128,
                                                        "master_compact": .masterCompact]

    static func modelDescription(_ model: BBCMicro.Model) -> String {
        switch model {
        case .modelA: "BBC Micro Model A (16K, OS 1.20, BASIC 2; no disc interface, user VIA or ADC)"
        case .modelB: "BBC Micro Model B (OS 1.20, BASIC 2, DFS 1.20)"
        case .bPlus: "BBC Micro Model B+ 128K (MOS 2.00, BASIC 2, DFS 2.26; 1770, shadow RAM)"
        case .master128: "BBC Master 128 (MOS 3.20, BASIC 4, DFS 2.24, ADFS 2.03)"
        case .masterCompact: "BBC Master Compact (MOS 5.10, BASIC 4, ADFS; 1772 and 3.5\" drives, digital joystick, no Tube)"
        }
    }

    static func prop(_ type: String, _ description: String) -> JSONValue {
        ["type": .string(type), "description": .string(description)]
    }

    static let resumeProperty = prop("boolean", "If the debugger has stopped the machine, carry on from the stop first (default true; breakpoints can stop it again). false leaves it stopped, so time doesn't pass")

    /// Clears a debugger stop, unless the tool's `resume` argument is false.
    static func resumeIfStopped(_ session: MachineSession, _ resume: Bool) {
        if resume {
            session.machine.debuggerIfCreated?.resume()
        }
    }

    static let keepDebuggerProperty = prop("boolean", "Keep the breakpoints, symbols, trace setting and log (default true)")

    /// Swaps in a restored machine, with the old one's debugger set-up if
    /// `keepDebugger`.
    static func replace(_ session: MachineSession, with machine: BBCMicro, keepDebugger: Bool) {
        if keepDebugger, let debugger = session.machine.debuggerIfCreated {
            machine.debugger.adopt(debugger)
        }
        session.replace(with: machine)
    }

    /// A TV that's just been attached (after restore_snapshot, load_state or
    /// a power cycle) has no picture until the machine draws one. This runs
    /// a copy of the machine to get it, leaving the real one where it was.
    /// `holdingCPU` halts the copy's CPU first, so the frame shows screen
    /// memory as it is now.
    static func nextFrame(of machine: BBCMicro, holdingCPU: Bool = false) throws -> TVOutput {
        let copy = try SaveStateFile(machine).makeMachine()
        if holdingCPU {
            copy.cpu.halt()
        }
        let tv = TVOutput()
        copy.tv = tv
        // A new TV's first frame is blank (it starts in vertical retrace)
        // and its second starts wherever the beam was: the third is whole.
        var cycles = 0
        while tv.frameCount < 3 && cycles < 2_000_000 {
            copy.run(cycles: 10_000)
            cycles += 10_000
        }
        return tv
    }

    /// Screen text plus the state an agent needs to know what happened.
    static func summary(_ session: MachineSession, extra: String = "") -> String {
        let text = session.machine.screenText()
        var lines = text
        while lines.last?.isEmpty == true { lines.removeLast() }
        let time = String(format: "%.2f", Double(session.machine.cycles) / 2_000_000)
        var notes = extra
        if let reason = session.machine.debuggerIfCreated?.stopReason {
            notes += (notes.isEmpty ? "" : "\n") + "(stopped in the debugger: \(reason); continue or step to go on)"
        }
        return (notes.isEmpty ? "" : notes + "\n") + "[t=\(time)s] screen:\n" + lines.joined(separator: "\n")
    }

    static let tools: [Tool] = coreTools + debugTools + basicTools + hardwareTools + nulaTools + econetTools

    static let coreTools: [Tool] = [
        Tool(definition: ToolDefinition(
            name: "get_status",
            description: "Machine state: emulated time, CPU registers, screen mode, discs in the drives, whether it's waiting for input.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine, cpu = m.cpu
                // At an instruction boundary the PC has already moved past
                // the opcode being fetched.
                let pc = cpu.isAboutToExecute ? cpu.abus : cpu.pc
                let discs = (0..<2).map { drive -> String in
                    guard let disc = m.drives[drive].disc else { return "drive \(drive): empty" }
                    if disc === m.startupDisc, let name = m.configuration.startupDisc?.name {
                        return "drive \(drive): the bundled system disc (\(name))"
                    }
                    let title = (try? DFSDisc(side: disc.toSSDOrDSD(force: true)).title) ?? "?"
                    return "drive \(drive): \"\(title)\""
                }
                return """
                model: \(modelDescription(m.model))\(m.secondProcessor != nil ? (m.configuration.coprocessor == .masterTurbo ? " with the Master Turbo's 65C102 Co-Processor (4MHz)" : " with a 6502 Second Processor") : m.z80Processor != nil ? " with a Z80 Second Processor (CP/M)" : m.master512 != nil ? " with a Master 512 (80186, DOS Plus)" : m.armProcessor != nil ? " with an ARM Evaluation System" : "")
                emulated time: \(String(format: "%.3f", Double(m.cycles) / 2_000_000))s
                PC=&\(hex(pc, 4)) A=&\(hex(cpu.a)) X=&\(hex(cpu.x)) Y=&\(hex(cpu.y)) S=&\(hex(cpu.s)) P=&\(hex(cpu.p))
                screen mode: \(m.peek(0x355))
                \(discs.joined(separator: "\n"))
                recording: \(session.isRecording)
                between tool calls: \(session.heldBetweenCalls ? "held still" : "runs in real time")
                """
            })
        },

        Tool(definition: ToolDefinition(
            name: "set_real_time",
            description: "Whether the machine runs in real time between tool calls (in the app, it does to begin with, so people can watch and play). Turn it off to make experiments exact: the machine then moves only during tool calls, so e.g. restore_snapshot then press_keys replays cycle for cycle. The app's window shows the machine is held; it's let go when you disconnect. A headless machine only ever runs during tool calls.",
            inputSchema: schema(["on": prop("boolean", "true: run in real time between calls; false: hold still")], required: ["on"])
        )) { context, args in
            guard let on = args["on"]?.boolValue else { throw ToolFailure("on is required") }
            return .text(try context.perform { session in
                guard session.runsBetweenCalls else {
                    return "this machine is headless: it only runs during tool calls anyway"
                }
                session.heldBetweenCalls = !on
                return on ? "running in real time between tool calls" : "held still between tool calls"
            })
        },

        Tool(definition: ToolDefinition(
            name: "power_cycle",
            description: "Switch the BBC off and on again. Discs stay in the drives (a bundled system disc changes with the co-processor). Runs until the BASIC prompt. With model, switches to that machine (breakpoints and symbols are kept): model_b (OS 1.20, BASIC 2, DFS 1.20), b_plus (B+ 128K: MOS 2.00, BASIC 2, DFS 2.26, shadow RAM) master_128 (MOS 3.20, BASIC 4, DFS 2.24, ADFS, View, ViewSheet, Edit; 1770 disc controller, shadow RAM, sideways RAM in banks 4-7), or master_compact (MOS 5.10, ADFS only, so it needs .adf/.adl discs; no Tube). With second_processor, fits or removes a 6502 Second Processor (3MHz 65C02, 64K, on the Tube): BASIC is copied across and runs in the second processor (PAGE &800, HIMEM &8000), and the host just does the I/O.",
            inputSchema: schema(["model": ["type": "string", "enum": ["model_a", "model_b", "b_plus", "master_128", "master_compact"],
                                           "description": "Machine to switch to (default: keep the current one)"] as JSONValue,
                                 "second_processor": prop("boolean", "Fit a second processor (default: keep as is)"),
                                 "coprocessor": ["type": "string", "enum": ["mos6502", "z80", "master512", "arm", "masterTurbo"],
                                                 "description": "Which second processor: mos6502 (default), z80 (CP/M; it starts with the bundled CP/M system disc in drive 0 and boots to A>), master512 (an 80186 for DOS Plus, on a master_128; it starts with the bundled DOS Plus boot disc in drive 0 and boots to A>, which takes about 40 emulated seconds) arm (the ARM Evaluation System: 8MHz ARM1, 4MB, an A* supervisor prompt) or masterTurbo (the Master Turbo, on a master_128: a 4MHz 65C102 on the internal Tube, otherwise like mos6502)"] as JSONValue,
                                 "disc_interface": ["type": "string", "enum": ["intel8271", "acorn1770", "watfordDDB2", "watfordDDB3", "opus"],
                                                    "description": "Model B only: the disc interface and its filing system (default: keep as is)"] as JSONValue,
                                 "memory_board": ["type": "string", "enum": .array(agentBoards.keys.sorted().map { .string($0) }),
                                                  "description": "Model B only: the board in the 6502's socket (default: keep as is). none: no board; watford_32k is Watford Electronics' 32K shadow RAM board with its ROM (Shadow RAM OS 2.40) in bank 13; aries_b32 is the Aries B32 (32K shared between shadow RAM and sideways RAM banks 13 and 14, its ROM in bank 15, BASIC in 11 and DFS in 10; *XON, *XOFF, *XSTATUS, *RLOAD, *RWRITE, *XTEST) and aries_b32_b12 adds the B12 (sockets 1-12, 16K RAM in bank 0; BASIC in 12, DFS in 11). (sideways_ram_16 and sideways_ram_32 still work: no board and that module.) get_hardware shows what's fitted"] as JSONValue,
                                 "sideways_ram": ["type": "string", "enum": ["none", "16k", "32k"],
                                                  "description": "Model B only: a sideways RAM module in a motherboard ROM socket, with or without a board (default: keep as is). Not with aries_b32_b12, whose cable uses all four sockets. With aries_b32 it's written while *RWRITE EXTERNAL is set"] as JSONValue,
                                 "sideways_ram_socket": prop("integer", "The module's socket by its stock bank number: 12 (leftmost) or 13 (default). With aries_b32 they answer as banks 12 and 9; with watford_32k the board's ROM takes the other"),
                                 "second_bank_below": prop("integer", "sideways_ram_32: the second bank is 4 (default) or 8 below the first, as the module's lead is wired"),
                                 "aries_start_up_link": prop("boolean", "Aries B32: the start-up link is fitted (default true: shadow RAM on at power on and Ctrl-Break)"),
                                 "video_nula": prop("boolean", "Fit VideoNuLA in place of the Video ULA (16 programmable 12-bit colours; any model), or take it out (default: keep as is). video_nula shows its state")])
        )) { context, args in
            var expansionChange: (@Sendable (BBCMicro.Expansions) throws -> BBCMicro.Expansions)?
            if args["memory_board"] != nil || args["sideways_ram"] != nil || args["sideways_ram_socket"] != nil
                || args["second_bank_below"] != nil || args["aries_start_up_link"] != nil {
                var board: BBCMicro.MemoryBoard?
                var module: BBCMicro.SidewaysModule?
                if let name = args["memory_board"]?.stringValue {
                    if let alias = agentModuleAliases[name] {
                        board = BBCMicro.MemoryBoard.none
                        module = alias
                    } else if let named = agentBoards[name] {
                        board = named
                    } else {
                        throw ToolFailure("memory_board must be one of \(agentBoards.keys.sorted().joined(separator: ", "))")
                    }
                }
                if let name = args["sideways_ram"]?.stringValue {
                    guard let named = agentModules[name] else { throw ToolFailure("sideways_ram must be none, 16k or 32k") }
                    module = named
                }
                let newModule = module
                let socket = args["sideways_ram_socket"]?.intValue
                let below = args["second_bank_below"]?.intValue
                let link = args["aries_start_up_link"]?.boolValue
                let newBoard = board
                expansionChange = { current in
                    var e = current
                    if let newBoard { e.board = newBoard }
                    if let newModule { e.sidewaysRAM = newModule }
                    if let socket { e.sidewaysRAMSocket = socket }
                    if let below { e.secondBankBelow = below }
                    if let link { e.ariesStartUpLink = link }
                    if let problem = e.problem { throw ToolFailure(problem) }
                    return e
                }
            }
            let changeExpansions = expansionChange
            let nula = args["video_nula"]?.boolValue
            var requestedModel: BBCMicro.Model?
            if let name = args["model"]?.stringValue {
                guard let named = agentModels[name] else { throw ToolFailure("model must be model_a, model_b, b_plus, master_128 or master_compact") }
                requestedModel = named
            }
            let model = requestedModel
            let secondProcessor = args["second_processor"]?.boolValue
            var discInterface: BBCMicro.DiscInterface?
            if let name = args["disc_interface"]?.stringValue {
                guard let named = BBCMicro.DiscInterface(rawValue: name) else { throw ToolFailure("unknown disc_interface \(name)") }
                discInterface = named
            }
            let interface = discInterface
            var requestedCoprocessor: BBCMicro.Coprocessor?
            if let name = args["coprocessor"]?.stringValue {
                guard let named = BBCMicro.Coprocessor(rawValue: name) else { throw ToolFailure("coprocessor must be mos6502, z80, master512, arm or masterTurbo") }
                requestedCoprocessor = named
            }
            let coprocessor = requestedCoprocessor
            return .text(try context.perform { session in
                var configuration: BBCMicro.Configuration?
                if model != nil || secondProcessor != nil || interface != nil || coprocessor != nil || changeExpansions != nil || nula != nil {
                    let current = session.machine
                    let fitted = current.secondProcessor != nil || current.z80Processor != nil || current.master512 != nil || current.armProcessor != nil
                    let newModel = model ?? current.model
                    // One kept from before that doesn't fit the new model
                    // (the Master 512 on a B) gives way to the 6502.
                    var newCoprocessor = coprocessor ?? current.configuration.coprocessor
                    if !newCoprocessor.fits(newModel) {
                        guard coprocessor == nil else {
                            throw ToolFailure("the \(newCoprocessor.displayName) can't be fitted to the \(newModel.displayName)\(newCoprocessor == .master512 || newCoprocessor == .masterTurbo ? " (only to the master_128)" : "")")
                        }
                        newCoprocessor = .mos6502
                    }
                    // The board (and anything put in its RAM at power on)
                    // stays fitted unless changed.
                    var expansions = current.configuration.expansions
                    if let changeExpansions {
                        guard newModel == .modelB else {
                            throw ToolFailure("memory boards fit the model_b only (this would be a \(newModel.displayName))")
                        }
                        expansions = try changeExpansions(expansions)
                    }
                    let images = current.configuration.sidewaysROMs.filter { current.sidewaysRAMBanks.contains($0.key) }
                    configuration = BeebROMs.configuration(for: newModel,
                                                           secondProcessor: secondProcessor ?? (coprocessor != nil || fitted),
                                                           coprocessor: newCoprocessor,
                                                           discInterface: interface ?? current.configuration.discInterface,
                                                           expansions: expansions, sidewaysImages: images)
                    configuration?.videoNuLA = nula ?? current.configuration.videoNuLA
                }
                session.powerCycle(configuration: configuration)
                // Booting a system disc (DOS Plus especially) takes longer.
                runUntilIdle(session, maxSeconds: session.machine.startupDisc != nil ? 60 : 10)
                return summary(session)
            })
        },

        Tool(definition: ToolDefinition(
            name: "press_break",
            description: "Press Break (soft reset; BASIC programs survive with OLD). With shift=true, Shift-Break boots the disc in drive 0. With ctrl=true, Ctrl-Break: a hard reset that keeps RAM (sideways RAM included) but resets the OS and scans the sideways ROMs afresh, e.g. after load_sideways_bank. Then runs until the machine waits for input (up to max_seconds).",
            inputSchema: schema(["shift": prop("boolean", "Hold Shift to boot the disc"),
                                 "ctrl": prop("boolean", "Hold Ctrl: a hard reset"),
                                 "max_seconds": prop("number", "Longest to wait for input (default 30)"),
                                 "resume": resumeProperty])
        )) { context, args in
            let shift = args["shift"]?.boolValue ?? false
            let ctrl = args["ctrl"]?.boolValue ?? false
            guard !(shift && ctrl) else { throw ToolFailure("shift or ctrl, not both") }
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            let resume = args["resume"]?.boolValue ?? true
            return .text(try context.perform { session in
                resumeIfStopped(session, resume)
                if shift { session.machine.shiftBreak() } else if ctrl { session.machine.ctrlBreak() } else { session.machine.pressBreak() }
                session.advance(seconds: 0.5)
                let idle = runUntilIdle(session, maxSeconds: maxSeconds)
                return summary(session, extra: idle ? "" : "(still running after \(maxSeconds)s)")
            })
        },

        Tool(definition: ToolDefinition(
            name: "load_disc",
            description: "Put a disc image file, or a bundled disc, in a drive: DFS .ssd/.dsd, ADFS .adf/.adl, or the Master 512's 800K DOS .img and 720K .dos (the last four for the 1770 machines: B+, Master, Compact). With boot=true (default, drive 0 only), Shift-Break to boot it and run until it waits for input. Returns the disc's catalogue.",
            inputSchema: schema(["path": prop("string", "Path to the disc image"),
                                 "bundled": ["type": "string", "enum": .array(BeebROMs.BundledDisc.allCases.map { .string($0.shortName) }),
                                             "description": "Instead of path, a bundled disc: cpm-utilities (the Z80's CP/M 2.2), dosplus-boot (the Master 512's DOS Plus 1.2), gem-applications, gem-data or master512-miscellaneous (the Master 512's other discs; GEM is on gem-applications, started with B:GEM from DOS Plus)"] as JSONValue,
                                 "drive": prop("integer", "0 or 1 (default 0)"),
                                 "boot": prop("boolean", "Shift-Break to boot it (default true for drive 0)"),
                                 "max_seconds": prop("number", "Longest to wait after booting (default 30)")],
                                required: [])
        )) { context, args in
            let bytes: [UInt8]
            let format: Disc.ImageFormat
            if let name = args["bundled"]?.stringValue {
                guard let disc = BeebROMs.BundledDisc.allCases.first(where: { $0.shortName == name }) else {
                    throw ToolFailure("unknown bundled disc \(name)")
                }
                bytes = disc.data
                format = disc.format
            } else if let path = args["path"]?.stringValue {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                bytes = [UInt8](try Data(contentsOf: url))
                format = Disc.ImageFormat(path: url.path) ?? .ssd
            } else {
                throw ToolFailure("path or bundled is required")
            }
            let drive = args["drive"]?.intValue ?? 0
            guard drive == 0 || drive == 1 else { throw ToolFailure("drive must be 0 or 1") }
            let boot = args["boot"]?.boolValue ?? (drive == 0)
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            let catalogue = switch format {
            case .ssd, .dsd: catalogueText(bytes, doubleSided: format == .dsd)
            case .adf, .adl: "ADFS disc"
            case .img, .dos: "DOS disc"
            }
            return .text(try context.perform { session in
                let disc = try Disc.fromImage(bytes, format: format)
                session.machine.insertDisc(disc, drive: drive)
                guard boot else { return catalogue }
                session.machine.shiftBreak()
                session.advance(seconds: 0.5)
                let idle = runUntilIdle(session, maxSeconds: maxSeconds)
                return summary(session, extra: catalogue + (idle ? "" : "\n(still running after \(maxSeconds)s)"))
            })
        },

        Tool(definition: ToolDefinition(
            name: "load_tape",
            description: "Put a .uef or .csw tape image in the cassette recorder. With load=true (default), types *TAPE and CHAIN \"\" and runs until the program waits for input (tapes load at real speed: a few KB takes about a minute of emulated time, which runs much faster). Use command for tapes that load another way, e.g. \"*RUN\".",
            inputSchema: schema(["path": prop("string", "Path to the .uef or .csw file"),
                                 "load": prop("boolean", "Load the first program (default true)"),
                                 "command": prop("string", "Command to load with (default CHAIN \"\")"),
                                 "max_seconds": prop("number", "Longest to wait (default 300)")],
                                required: ["path"])
        )) { context, args in
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let bytes = [UInt8](try Data(contentsOf: url))
            let load = args["load"]?.boolValue ?? true
            let command = args["command"]?.stringValue ?? "CHAIN \"\""
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 300
            let tape = try Tape(image: bytes)
            let length = String(format: "%.0f", tape.duration)
            return .text(try context.perform { session in
                session.machine.insertTape(try Tape(image: bytes))
                let loaded = "tape: \(url.lastPathComponent) (\(length)s long)"
                guard load else { return loaded }
                session.machine.paste("*TAPE\n\(command)\n")
                session.advance(seconds: 1)
                let idle = runUntilIdle(session, maxSeconds: maxSeconds)
                return summary(session, extra: loaded + (idle ? "" : "\n(still running after \(maxSeconds)s)"))
            })
        },

        Tool(definition: ToolDefinition(
            name: "rewind_tape",
            description: "Rewind the tape to the start.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                guard session.machine.tape != nil else { return "no tape" }
                session.machine.rewindTape()
                return "rewound"
            })
        },

        Tool(definition: ToolDefinition(
            name: "eject_disc",
            description: "Remove the disc from a drive.",
            inputSchema: schema(["drive": prop("integer", "0 or 1 (default 0)")])
        )) { context, args in
            let drive = args["drive"]?.intValue ?? 0
            guard drive == 0 || drive == 1 else { throw ToolFailure("drive must be 0 or 1") }
            return .text(try context.perform { session in
                session.machine.insertDisc(nil, drive: drive)
                return "drive \(drive) empty"
            })
        },

        Tool(definition: ToolDefinition(
            name: "run_command",
            description: "Enter a line (BASIC or a * command) as if typed, fast, then run until the machine waits for input again. Returns the text the OS printed, and the screen. Use \\n in text for several lines; a final Return is added.",
            inputSchema: schema(["text": prop("string", "e.g. PRINT 6*7, CHAIN \"GAME\", *CAT"),
                                 "max_seconds": prop("number", "Longest to wait (default 30)"),
                                 "resume": resumeProperty],
                                required: ["text"])
        )) { context, args in
            guard let text = args["text"]?.stringValue else { throw ToolFailure("text is required") }
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            let resume = args["resume"]?.boolValue ?? true
            return .text(try context.perform { session in
                resumeIfStopped(session, resume)
                let m = session.machine
                m.capturedOutput = []
                m.captureOutput = true
                defer { m.captureOutput = false }
                m.paste(text.hasSuffix("\n") ? text : text + "\n")
                let idle = runUntilIdle(session, maxSeconds: maxSeconds)
                let output = printable(m.capturedOutput)
                return summary(session, extra: "output:\n" + output + (idle ? "" : "\n(still running after \(maxSeconds)s)"))
            })
        },

        Tool(definition: ToolDefinition(
            name: "type_text",
            description: "Type text through the keyboard, key by key at a realistic speed (40ms per key, Shift as needed). Use for programs that read the keyboard directly; for commands, run_command is faster. \\n is Return. Then runs for settle_seconds.",
            inputSchema: schema(["text": prop("string", "Text to type"),
                                 "settle_seconds": prop("number", "Time to run after typing (default 0.5)"),
                                 "resume": resumeProperty],
                                required: ["text"])
        )) { context, args in
            guard let text = args["text"]?.stringValue else { throw ToolFailure("text is required") }
            let settle = args["settle_seconds"]?.doubleValue ?? 0.5
            let resume = args["resume"]?.boolValue ?? true
            return .text(try context.perform { session in
                resumeIfStopped(session, resume)
                session.machine.type(text)
                _ = session.advance(until: { !session.machine.isTyping }, maxSeconds: 600)
                session.advance(seconds: settle)
                return summary(session)
            })
        },

        Tool(definition: ToolDefinition(
            name: "mouse",
            description: "Use the AMX mouse on the user port (GEM on the Master 512, AMX software on the BBC): move it by dx, dy counts (right and down positive), at a hand's pace; then set the buttons held, or click one. Under GEM a count moves the pointer about 4 of its 640 pixels across and 2 of its 256 down (moves go at a count every 20ms, slow enough that GEM doesn't accelerate them). Then runs for settle_seconds. Use screenshot to see where the pointer is.",
            inputSchema: schema(["dx": prop("integer", "Counts right (negative: left)"),
                                 "dy": prop("integer", "Counts down (negative: up)"),
                                 "buttons": ["type": "array", "items": ["type": "string", "enum": ["left", "middle", "right"]],
                                             "description": "Buttons to hold down after moving (default: as they were)"] as JSONValue,
                                 "click": ["type": "string", "enum": ["left", "middle", "right"],
                                           "description": "Click a button after moving (or double_click)"] as JSONValue,
                                 "double_click": prop("boolean", "With click, click it twice"),
                                 "settle_seconds": prop("number", "Time to run afterwards (default 0.3)"),
                                 "resume": resumeProperty])
        )) { context, args in
            let resume = args["resume"]?.boolValue ?? true
            let dx = args["dx"]?.intValue ?? 0, dy = args["dy"]?.intValue ?? 0
            func button(_ name: String) throws -> AMXMouse.Buttons {
                switch name {
                case "left": .left
                case "middle": .middle
                case "right": .right
                default: throw ToolFailure("buttons are left, middle and right")
                }
            }
            let held = try args["buttons"]?.arrayValue.map { try $0.compactMap(\.stringValue).reduce(into: AMXMouse.Buttons()) { $0.insert(try button($1)) } }
            let click = try args["click"]?.stringValue.map(button)
            let clicks = args["double_click"]?.boolValue == true ? 2 : 1
            let settle = args["settle_seconds"]?.doubleValue ?? 0.3
            return .text(try context.perform { session in
                resumeIfStopped(session, resume)
                let m = session.machine
                // A count each 20ms (on each axis), so software that
                // accelerates (GEM) doesn't take it for a flick.
                var x = dx, y = dy
                while x != 0 || y != 0 {
                    let sx = x.signum(), sy = y.signum()
                    m.moveMouse(dx: sx, dy: sy)
                    x -= sx
                    y -= sy
                    session.advance(seconds: 0.02)
                }
                if dx != 0 || dy != 0 {
                    session.advance(seconds: 0.1)
                }
                if let held {
                    m.setMouseButtons(held)
                }
                if let click {
                    // Quick enough for GEM's double click.
                    for _ in 0..<clicks {
                        m.setMouseButtons(m.mouse.buttons.union(click))
                        session.advance(seconds: 0.04)
                        m.setMouseButtons(m.mouse.buttons.subtracting(click))
                        session.advance(seconds: 0.04)
                    }
                }
                session.advance(seconds: settle)
                return summary(session, extra: m.mouseInUse ? "" : "(nothing is reading the mouse: its interrupts are off)")
            })
        },

        Tool(definition: ToolDefinition(
            name: "press_keys",
            description: "Hold keys down together, then release: e.g. [\"SHIFT\",\"F1\"], [\"CTRL\",\"G\"], [\"ESCAPE\"]. Names: RETURN SPACE SHIFT CTRL ESCAPE TAB DELETE COPY CAPSLOCK SHIFTLOCK UP DOWN LEFT RIGHT F0-F9 BREAK, or a single character.",
            inputSchema: schema(["keys": ["type": "array", "items": ["type": "string"], "description": "Key names"],
                                 "hold_seconds": prop("number", "How long to hold them (default 0.1)"),
                                 "settle_seconds": prop("number", "Time to run after release (default 0.2)"),
                                 "resume": resumeProperty],
                                required: ["keys"])
        )) { context, args in
            guard let names = args["keys"]?.arrayValue?.compactMap(\.stringValue), !names.isEmpty else {
                throw ToolFailure("keys is required")
            }
            let keys = try names.map { name -> BeebKey in
                guard let key = BeebKey.named(name) else { throw ToolFailure("unknown key \(name)") }
                return key
            }
            let hold = args["hold_seconds"]?.doubleValue ?? 0.1
            let settle = args["settle_seconds"]?.doubleValue ?? 0.2
            let resume = args["resume"]?.boolValue ?? true
            return .text(try context.perform { session in
                resumeIfStopped(session, resume)
                for key in keys { session.machine.setKey(key, down: true) }
                session.advance(seconds: hold)
                for key in keys.reversed() { session.machine.setKey(key, down: false) }
                session.advance(seconds: settle)
                return summary(session)
            })
        },

        Tool(definition: ToolDefinition(
            name: "key_sequence",
            description: "Press and release keys on a timeline, in one call, exactly repeatably (e.g. a scripted flight: hold thrust while tapping turn). Each event is at a time from the start (at_frame, 50 a second, or at_seconds), and puts keys down and/or up. Keys can overlap. Any still down at the end are released then, unless keep_held. Key names as for press_keys. Stops early if the debugger stops the machine.",
            inputSchema: schema(["events": ["type": "array",
                                            "items": ["type": "object",
                                                      "properties": ["at_frame": prop("number", "When, in frames (1/50s) from the start"),
                                                                     "at_seconds": prop("number", "Or: when, in seconds from the start"),
                                                                     "down": ["type": "array", "items": ["type": "string"], "description": "Keys to press"],
                                                                     "up": ["type": "array", "items": ["type": "string"], "description": "Keys to release"]]],
                                            "description": "The events, e.g. [{\"at_frame\":0,\"down\":[\"A\"]},{\"at_frame\":5,\"down\":[\"Z\"]},{\"at_frame\":20,\"up\":[\"A\",\"Z\"]}]"] as JSONValue,
                                 "settle_seconds": prop("number", "Time to run after the last event (default 0.2)"),
                                 "keep_held": prop("boolean", "Leave keys that are still down held (default false)"),
                                 "resume": resumeProperty],
                                required: ["events"])
        )) { context, args in
            guard let events = args["events"]?.arrayValue, !events.isEmpty else { throw ToolFailure("events is required") }
            func keys(_ value: JSONValue?) throws -> [BeebKey] {
                try (value?.arrayValue ?? []).map { item in
                    guard let name = item.stringValue, let key = BeebKey.named(name) else {
                        throw ToolFailure("unknown key \(item.stringValue ?? "\(item)")")
                    }
                    return key
                }
            }
            let timeline = try events.enumerated().map { index, event -> (cycles: Int, down: [BeebKey], up: [BeebKey]) in
                guard let seconds = event["at_seconds"]?.doubleValue ?? event["at_frame"]?.doubleValue.map({ $0 / 50 }),
                      seconds >= 0 && seconds <= 3600 else {
                    throw ToolFailure("event \(index) needs at_frame or at_seconds (0-3600s)")
                }
                return (Int(seconds * 2_000_000), try keys(event["down"]), try keys(event["up"]))
            }.enumerated().sorted { ($0.element.cycles, $0.offset) < ($1.element.cycles, $1.offset) }.map(\.element)
            let settle = args["settle_seconds"]?.doubleValue ?? 0.2
            let keepHeld = args["keep_held"]?.boolValue ?? false
            let resume = args["resume"]?.boolValue ?? true
            return .text(try context.perform { session in
                resumeIfStopped(session, resume)
                let m = session.machine
                let start = m.cycles
                var held: [BeebKey] = []
                var stopped = false
                for event in timeline {
                    let target = start + UInt64(event.cycles)
                    while m.cycles < target && !m.isStoppedByDebugger {
                        session.advance(cycles: Int(target - m.cycles))
                    }
                    if m.isStoppedByDebugger {
                        stopped = true
                        break
                    }
                    for key in event.up {
                        m.setKey(key, down: false)
                        held.removeAll { $0 == key }
                    }
                    for key in event.down where !held.contains(key) {
                        m.setKey(key, down: true)
                        held.append(key)
                    }
                }
                if !keepHeld {
                    for key in held.reversed() { m.setKey(key, down: false) }
                }
                if !stopped { session.advance(seconds: settle) }
                var notes: [String] = []
                if stopped { notes.append("stopped before the last events") }
                if keepHeld && !held.isEmpty { notes.append("still held: " + held.map(\.name).joined(separator: " ")) }
                return summary(session, extra: notes.joined(separator: "\n"))
            })
        },

        Tool(definition: ToolDefinition(
            name: "run",
            description: "Run the machine for some emulated time (seconds, or frames at 50 per second). Runs faster than real time.",
            inputSchema: schema(["seconds": prop("number", "Emulated seconds"),
                                 "frames": prop("integer", "Frames (1/50s each)"),
                                 "resume": resumeProperty])
        )) { context, args in
            let seconds = args["seconds"]?.doubleValue ?? (args["frames"]?.doubleValue).map { $0 / 50 } ?? 1
            guard seconds >= 0 && seconds <= 3600 else { throw ToolFailure("seconds must be 0-3600") }
            let resume = args["resume"]?.boolValue ?? true
            return .text(try context.perform { session in
                resumeIfStopped(session, resume)
                session.advance(seconds: seconds)
                return summary(session)
            })
        },

        Tool(definition: ToolDefinition(
            name: "run_until_idle",
            description: "Run until the machine is waiting for input (at the BASIC prompt or an INPUT, a co-processor's prompt, or a program polling the keyboard with the screen still for half a second), or max_seconds pass.",
            inputSchema: schema(["max_seconds": prop("number", "Longest to run (default 30)"), "resume": resumeProperty])
        )) { context, args in
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            let resume = args["resume"]?.boolValue ?? true
            return .text(try context.perform { session in
                resumeIfStopped(session, resume)
                let idle = runUntilIdle(session, maxSeconds: maxSeconds)
                return summary(session, extra: idle ? "waiting for input" : "still running after \(maxSeconds)s")
            })
        },

        Tool(definition: ToolDefinition(
            name: "run_until_address",
            description: "Run until the CPU is about to execute the instruction at an address (e.g. \"&0E00\"), or max_seconds pass.",
            inputSchema: schema(["address": prop("string", "Address: &1900, $1900, 0x1900 or decimal"),
                                 "max_seconds": prop("number", "Longest to run (default 30)"),
                                 "resume": resumeProperty],
                                required: ["address"])
        )) { context, args in
            guard let address = args["address"]?.intValue, (0...0xFFFF).contains(address) else {
                throw ToolFailure("address must be 0-&FFFF")
            }
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            let resume = args["resume"]?.boolValue ?? true
            return .text(try context.perform { session in
                resumeIfStopped(session, resume)
                let m = session.machine
                m.watch(address: UInt16(address))
                defer { m.watch(address: nil) }
                let reached = session.advance(until: { m.reachedWatchAddress }, maxSeconds: maxSeconds)
                return summary(session, extra: reached ? "reached &\(hex(UInt16(address), 4))" : "didn't reach &\(hex(UInt16(address), 4)) in \(maxSeconds)s")
            })
        },

        Tool(definition: ToolDefinition(
            name: "screenshot",
            description: "The screen as a PNG image (736x576; the BBC's pixels are a little narrower than square). source tv (default) is the last complete field: it doesn't change while the debugger has the machine stopped. beam is the field being drawn, as far as the beam has got (the rest is the field before): frame-exact at a breakpoint. memory draws screen memory as it is now, as a whole frame, with the CPU held still (the machine itself doesn't move; palette or CRTC changes made part way down the screen aren't reproduced). Straight after restore_snapshot, load_state or power_cycle, before the machine has drawn a frame, tv is the frame the machine is about to draw.",
            inputSchema: schema(["source": ["type": "string", "enum": ["tv", "beam", "memory"],
                                            "description": "What to show (default tv)"] as JSONValue])
        )) { context, args in
            let source = args["source"]?.stringValue ?? "tv"
            guard ["tv", "beam", "memory"].contains(source) else { throw ToolFailure("source must be tv, beam or memory") }
            let png = try context.perform { session -> Data? in
                switch source {
                case "beam":
                    return Screenshot.png(pixels: session.tv.currentFrame, width: TVOutput.width, height: TVOutput.height)
                case "memory":
                    return Screenshot.png(try nextFrame(of: session.machine, holdingCPU: true))
                default:
                    return Screenshot.png(session.tv.frameCount > 0 ? session.tv : try nextFrame(of: session.machine))
                }
            }
            guard let png else { throw ToolFailure("no frame yet") }
            return ToolResult(content: [.png(png)], isError: false)
        },

        Tool(definition: ToolDefinition(
            name: "read_screen_text",
            description: "The text on the screen, in any mode (bitmap modes are matched against the OS font; ? marks cells that aren't characters).",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                var lines = session.machine.screenText()
                while lines.last?.isEmpty == true { lines.removeLast() }
                return lines.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "load_program",
            description: "Load a file from a disc image straight into memory, without the disc system: BASIC at PAGE (then use run_command RUN), machine code at its load address (then CALL it).",
            inputSchema: schema(["path": prop("string", "Path to the .ssd file"),
                                 "file": prop("string", "File name on the disc, e.g. GAME or $.GAME")],
                                required: ["path", "file"])
        )) { context, args in
            guard let path = args["path"]?.stringValue, let file = args["file"]?.stringValue else {
                throw ToolFailure("path and file are required")
            }
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
            return .text(try context.perform { session in
                switch session.machine.loadProgram(disc: bytes, file: file) {
                case .success(let f):
                    return "loaded \(f.fullName): \(f.length) bytes, load &\(String(f.loadAddress & 0xFFFF, radix: 16, uppercase: true)), exec &\(String(f.executionAddress & 0xFFFF, radix: 16, uppercase: true))"
                case .failure(let error):
                    throw ToolFailure("\(error)")
                }
            })
        },

        Tool(definition: ToolDefinition(
            name: "save_snapshot",
            description: "Remember the machine's exact state under a name (in memory), to come back to with restore_snapshot. Restoring continues exactly, cycle for cycle: good for trying things.",
            inputSchema: schema(["name": prop("string", "Snapshot name (default \"default\")")])
        )) { context, args in
            let name = args["name"]?.stringValue ?? "default"
            let file = try context.perform { session in SaveStateFile(session.machine) }
            slots.withLock { $0[name] = file }
            return .text("saved snapshot \"\(name)\" at t=\(String(format: "%.2f", Double(file.snapshot.cycles) / 2_000_000))s")
        },

        Tool(definition: ToolDefinition(
            name: "restore_snapshot",
            description: "Go back to a snapshot taken with save_snapshot (machine, memory and discs). The debugger's breakpoints and symbols stay as they are. In the app, the machine runs on in real time between tool calls unless set_real_time has turned that off: do so for an exact replay.",
            inputSchema: schema(["name": prop("string", "Snapshot name (default \"default\")"),
                                 "keep_debugger": keepDebuggerProperty])
        )) { context, args in
            let name = args["name"]?.stringValue ?? "default"
            guard let file = slots.withLock({ $0[name] }) else { throw ToolFailure("no snapshot named \(name)") }
            let keep = args["keep_debugger"]?.boolValue ?? true
            return .text(try context.perform { session in
                replace(session, with: try file.makeMachine(), keepDebugger: keep)
                session.advance(cycles: 0)
                return summary(session, extra: "restored \"\(name)\"")
            })
        },

        Tool(definition: ToolDefinition(
            name: "save_state",
            description: "Save the machine's exact state (including ROMs and discs) to a .beebstate file.",
            inputSchema: schema(["path": prop("string", "Output path")], required: ["path"])
        )) { context, args in
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let data = try context.perform { session in try SaveStateFile(session.machine).data() }
            try data.write(to: url, options: .atomic)
            return .text("saved \(data.count) bytes to \(url.path)")
        },

        Tool(definition: ToolDefinition(
            name: "load_state",
            description: "Load a .beebstate file, replacing the machine. The debugger's breakpoints and symbols stay as they are.",
            inputSchema: schema(["path": prop("string", "Path to the .beebstate file"),
                                 "keep_debugger": keepDebuggerProperty], required: ["path"])
        )) { context, args in
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let file = try SaveStateFile(data: Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
            let keep = args["keep_debugger"]?.boolValue ?? true
            return .text(try context.perform { session in
                replace(session, with: try file.makeMachine(), keepDebugger: keep)
                session.advance(cycles: 0)
                return summary(session, extra: "loaded state from \(file.created)")
            })
        },

        Tool(definition: ToolDefinition(
            name: "start_recording",
            description: "Start recording video and sound to a movie file (.mp4 is H.264; .mov is ProRes). Time is emulated time, so recordings play at the right speed even though emulation runs faster.",
            inputSchema: schema(["path": prop("string", "Output file path")], required: ["path"])
        )) { context, args in
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let codec: VideoRecorder.Codec = url.pathExtension.lowercased() == "mov" ? .proRes : .h264
            return .text(try context.perform { session in
                try session.startRecording(to: url, codec: codec)
                return "recording to \(url.path)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "stop_recording",
            description: "Stop recording and finish the movie file.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                guard session.isRecording else { return "not recording" }
                try session.stopRecording()
                return "recording finished"
            })
        },
    ]

    // MARK: Helpers

    /// Runs through the session (so recording and the display keep up)
    /// until the machine waits for input.
    @discardableResult
    static func runUntilIdle(_ session: MachineSession, maxSeconds: Double) -> Bool {
        let m = session.machine
        m.watchForIdle(true)
        let idle = session.advance(until: { m.reachedIdle }, maxSeconds: maxSeconds)
        m.watchForIdle(false)
        if idle {
            session.advance(seconds: 0.01)
        }
        return idle
    }

    static func printable(_ bytes: [UInt8]) -> String {
        var text = ""
        for byte in bytes {
            switch byte {
            case 13: text.append("\n")
            case 10: break
            case 32..<127: text.append(Character(UnicodeScalar(byte)))
            default: break
            }
        }
        return text
    }

    static func catalogueText(_ bytes: [UInt8], doubleSided: Bool) -> String {
        guard let sides = try? DFSDisc.sides(ofImage: bytes, doubleSided: doubleSided) else {
            return "(not a DFS disc)"
        }
        return sides.enumerated().map { index, side in
            let options = ["off", "*LOAD", "*RUN", "*EXEC"][side.bootOption]
            let files = side.files.map { file in
                "  \(file.fullName.padding(toLength: 10, withPad: " ", startingAt: 0)) load &\(String(file.loadAddress & 0xFFFF, radix: 16, uppercase: true)) exec &\(String(file.executionAddress & 0xFFFF, radix: 16, uppercase: true)) \(file.length) bytes"
            }
            return "side \(index): \"\(side.title)\", boot \(options)\n" + files.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    static func hexDump(_ bytes: [UInt8], address: Int) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hexBytes = row.map { hex($0) }.joined(separator: " ")
            let ascii = String(row.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            return "\(hex(UInt16(truncatingIfNeeded: address + offset), 4))  \(hexBytes.padding(toLength: 47, withPad: " ", startingAt: 0))  \(ascii)"
        }.joined(separator: "\n")
    }
}

func hex(_ value: UInt8) -> String { hex(UInt16(value), 2) }

func hex(_ value: UInt16, _ width: Int) -> String {
    let digits = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}
