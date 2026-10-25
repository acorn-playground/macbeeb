import BeebCore
import BeebHost
import Foundation

/// Debugging tools: memory in any address space, breakpoints, stepping,
/// registers and tracing, for the host CPU and the second processor.
extension AgentTools {
    static let cpuProperty = ["type": "string", "enum": ["host", "parasite"],
                              "description": "Which CPU (default host; parasite is the second processor: a 6502 or a Z80)"] as JSONValue
    static let spaceProperty = prop("string", "Address space (default: the host CPU's current view). host, parasite (the CPU views), main, shadow, andy, hazel, os, bank0-bankF, parasite_ram; memory_regions lists them")

    static func cpu(_ args: JSONValue) throws -> DebugCPU {
        guard let name = args["cpu"]?.stringValue else { return .host }
        guard let cpu = DebugCPU(rawValue: name) else { throw ToolFailure("cpu must be host or parasite") }
        return cpu
    }

    static func space(_ args: JSONValue, cpu: DebugCPU) throws -> MemorySpace {
        guard let name = args["space"]?.stringValue else { return .cpu(cpu) }
        guard let space = MemorySpace(name: name) else { throw ToolFailure("unknown space \(name); see memory_regions") }
        return space
    }

    /// An address argument: a number or an expression (registers, memory,
    /// symbols), e.g. "&1900", "PC+3", "{&FFFE}".
    static func address(_ args: JSONValue, _ key: String, in machine: BBCMicro, cpu: DebugCPU) throws -> Int? {
        guard let value = args[key] else { return nil }
        if let n = value.intValue {
            return n
        }
        guard let text = value.stringValue else { throw ToolFailure("\(key) must be a number or expression") }
        // file.s:12, a source line from loaded debug info.
        if let colon = text.lastIndex(of: ":"), let line = Int(text[text.index(after: colon)...]),
           text[..<colon].contains(".") {
            let file = String(text[..<colon])
            guard let found = machine.debugger.symbols(cpu).addresses(file: file, line: line), let first = found.addresses.min() else {
                throw ToolFailure("no code at \(text) (load_symbols first?)")
            }
            return Int(first)
        }
        do {
            return try DebugExpression(text).evaluate(machine.debugger.expressionContext(cpu))
        } catch {
            throw ToolFailure("\(key): \(error)")
        }
    }

    static func flags(_ p: UInt8) -> String {
        zip("NV-BDIZC", (0..<8).reversed()).map { ch, bit in p & 1 << bit != 0 ? ch : Character(ch.lowercased()) }
            .map(String.init).joined()
    }

    static func registerLine(_ m: BBCMicro, _ cpu: DebugCPU) -> String? {
        guard let kind = m.debugCPUKind(cpu) else { return nil }
        let state = m.isAtInstruction(cpu) ? "" : " (mid-instruction)"
        let registers = m.registers(cpu).map { r in
            r.name == "P" ? "P=\(flags(UInt8(r.value)))" : "\(r.name)=&\(hex(UInt16(r.value), r.digits))"
        }
        var line = "\(cpu.rawValue)\(kind == .z80 ? " (Z80)" : ""): \(registers.joined(separator: " "))"
        if kind == .z80 {
            line += " flags=" + m.flags(cpu).map { $0.set ? $0.label : $0.label.lowercased() }.joined(separator: " ")
        }
        return line + state
    }

    /// Disassembly from `start`, marking `pc`.
    static func disassembly(_ m: BBCMicro, _ cpu: DebugCPU, from start: UInt16, count: Int, mark pc: UInt16?) -> String {
        let disassembler = m.disassembler(cpu)
        let read = { (a: UInt16) in m.codeRead(cpu, Int(a)) ?? 0xFF }
        var address = start
        var lines: [String] = []
        for _ in 0..<count {
            let (raw, length) = disassembler.disassemble(at: address, read: read)
            let symbols = m.debugger.symbols(cpu)
            let text = symbols.annotate(raw)
            let bytes = (0..<length).map { hex(read(address &+ UInt16($0))) }.joined(separator: " ")
            let marker = address == pc ? "> " : "  "
            if let label = symbols.names(at: address).first, address < 0xFC00 || address >= 0xFF00 {
                lines.append("\(label):")
            }
            var line = "\(marker)\(hex(address, 4))  \(bytes.padding(toLength: 9, withPad: " ", startingAt: 0))  \(text)"
            var notes: [String] = []
            if let source = symbols.location(at: address) {
                notes.append("\(source)")
            }
            let breakpoints = m.debugger.breakpoints.filter { $0.cpu == cpu && $0.kind.contains(.execute) && $0.start == address }
            if !breakpoints.isEmpty {
                notes.append("breakpoint " + breakpoints.map { "\($0.id)" }.joined(separator: ","))
            }
            if !notes.isEmpty {
                line += String(repeating: " ", count: max(1, 34 - line.count)) + "; " + notes.joined(separator: ", ")
            }
            lines.append(line)
            address &+= UInt16(length)
        }
        return lines.joined(separator: "\n")
    }

    /// Where the debugger stopped, the registers and the code there.
    static func debugSummary(_ session: MachineSession, cpu: DebugCPU, reason: StopReason?) -> String {
        let m = session.machine
        var text = reason.map { "stopped: \($0)" } ?? "still running (time limit reached)"
        switch reason {
        case .basicBreakpoint, .basicStepped, .basicError:
            // The interpreter's registers and code don't help.
            let time = String(format: "%.6f", Double(m.cycles) / 2_000_000)
            return text + (basicWhere(m).map { "\n" + $0 } ?? "") + "\n[t=\(time)s, cycle \(m.cycles)]"
        default:
            break
        }
        let stoppedCPU: DebugCPU = switch reason {
        case .breakpoint(_, let c, _, _), .stepped(let c), .interrupt(let c): c
        default: cpu
        }
        for c in DebugCPU.allCases {
            if let line = registerLine(m, c) { text += "\n" + line }
        }
        let pc = m.instructionAddress(stoppedCPU)
        text += "\n" + disassembly(m, stoppedCPU, from: pc, count: 6, mark: pc)
        let log = m.debugger.log.suffix(10)
        if !log.isEmpty {
            text += "\nlog:\n" + log.map { "  [\($0.cpu.rawValue) \($0.cycle)] \($0.text)" }.joined(separator: "\n")
        }
        let time = String(format: "%.6f", Double(m.cycles) / 2_000_000)
        return text + "\n[t=\(time)s, cycle \(m.cycles)]"
    }

    static let debugTools: [Tool] = [
        Tool(definition: ToolDefinition(
            name: "peek",
            description: "Read memory without side effects (I/O registers are peeked, not read). Returns a hex dump, or with path, writes the bytes to a file instead (raw binary, up to 64K: e.g. screen memory to compare against a reference). Addresses can be numbers or expressions (e.g. \"PC\", \"{&FFFE}\").",
            inputSchema: schema(["address": prop("string", "Start address: &1900, $1900, 0x1900, decimal or an expression"),
                                 "length": prop("integer", "Bytes (default 64; max 4096, or 65536 with path)"),
                                 "path": prop("string", "Write the bytes to this file instead of returning them"),
                                 "space": spaceProperty, "cpu": cpuProperty],
                                required: ["address"])
        )) { context, args in
            let cpu = try cpu(args)
            let space = try space(args, cpu: cpu)
            let path = args["path"]?.stringValue.map { ($0 as NSString).expandingTildeInPath }
            let length = min(max(args["length"]?.intValue ?? 64, 1), path == nil ? 4096 : 65536)
            return .text(try context.perform { session in
                let m = session.machine
                guard let address = try address(args, "address", in: m, cpu: cpu) else { throw ToolFailure("address is required") }
                var bytes: [UInt8] = []
                for offset in 0..<length {
                    guard let byte = m.debugRead(space, address + offset) else { break }
                    bytes.append(byte)
                }
                guard !bytes.isEmpty else { throw ToolFailure("nothing at &\(String(address, radix: 16, uppercase: true)) in \(space)") }
                guard let path else { return hexDump(bytes, address: address) }
                let url = URL(fileURLWithPath: path)
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(bytes).write(to: url)
                } catch {
                    throw ToolFailure("can't write \(path): \(error.localizedDescription)")
                }
                return "wrote \(bytes.count) bytes from &\(String(address, radix: 16, uppercase: true)) in \(space) to \(path)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "poke",
            description: "Write bytes to memory, including ROM (to patch it) but not I/O. Defaults to the host CPU's current view; use space to write elsewhere (e.g. shadow, bank4, parasite_ram).",
            inputSchema: schema(["address": prop("string", "Start address or expression"),
                                 "bytes": ["type": "array", "items": ["type": "integer"], "description": "Values 0-255"],
                                 "space": spaceProperty, "cpu": cpuProperty],
                                required: ["address", "bytes"])
        )) { context, args in
            let cpu = try cpu(args)
            let space = try space(args, cpu: cpu)
            guard let bytes = args["bytes"]?.arrayValue?.compactMap(\.intValue), bytes.allSatisfy({ (0...255).contains($0) }) else {
                throw ToolFailure("bytes must be an array of 0-255")
            }
            return .text(try context.perform { session in
                let m = session.machine
                guard let address = try address(args, "address", in: m, cpu: cpu) else { throw ToolFailure("address is required") }
                for (offset, byte) in bytes.enumerated() {
                    guard m.debugWrite(space, address + offset, UInt8(byte)) else {
                        throw ToolFailure("can't write &\(String(address + offset, radix: 16, uppercase: true)) in \(space) (I/O, or nothing there); wrote \(offset) bytes")
                    }
                }
                return "wrote \(bytes.count) bytes at &\(String(address, radix: 16, uppercase: true)) in \(space)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "disassemble",
            description: "Disassemble code (for the CPU's instruction set: NMOS 6502, 65C12, 65C02 or Z80) as the CPU sees memory now. Default: from the current instruction. Marks the PC and breakpoints.",
            inputSchema: schema(["address": prop("string", "Start address or expression (default PC)"),
                                 "count": prop("integer", "Instructions (default 16)"),
                                 "cpu": cpuProperty])
        )) { context, args in
            let cpu = try cpu(args)
            let count = min(max(args["count"]?.intValue ?? 16, 1), 256)
            return .text(try context.perform { session in
                let m = session.machine
                guard m.hasDebugCPU(cpu) else { throw ToolFailure("there's no second processor") }
                let pc = m.instructionAddress(cpu)
                let start = try address(args, "address", in: m, cpu: cpu).map { UInt16(truncatingIfNeeded: $0) } ?? pc
                return disassembly(m, cpu, from: start, count: count, mark: pc)
            })
        },

        Tool(definition: ToolDefinition(
            name: "memory_regions",
            description: "The machine's memory regions (for peek/poke's space), and the current paging: which sideways bank is in, shadow RAM, etc.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine
                var lines = m.memoryRegions.map { r in
                    "\(String(describing: r.space).padding(toLength: 13, withPad: " ", startingAt: 0)) \(r.name): &\(hex(UInt16(r.base), 4))-&\(hex(UInt16(r.base + r.size - 1), 4))\(r.isROM ? " (ROM)" : "")"
                }
                lines.append("paging: ROMSEL=&\(hex(m.romsel)) (bank \(String(m.romsel & 0x0F, radix: 16, uppercase: true)) at &8000)"
                             + (m.model == .modelB ? "" : " ACCCON=&\(hex(m.acccon))"))
                return lines.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "registers",
            description: "CPU registers (both CPUs if there's a second processor), flags (upper case = set), and whether the debugger has stopped the machine.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine
                var lines = DebugCPU.allCases.compactMap { registerLine(m, $0) }
                lines.append("cycle \(m.cycles)")
                if let reason = m.debuggerIfCreated?.stopReason {
                    lines.append("stopped: \(reason)")
                }
                return lines.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "set_register",
            description: "Set a register (A X Y S P PC) or flag (C Z I D V N). On a Z80 second processor: A F B C D E H L, AF BC DE HL IX IY SP PC, AF' etc., I R IM, flags SF ZF HF PF NF CF, IFF1 IFF2. PC can only be set between instructions, e.g. at a breakpoint or after a step.",
            inputSchema: schema(["name": prop("string", "Register or flag"),
                                 "value": prop("string", "Value or expression"),
                                 "cpu": cpuProperty],
                                required: ["name", "value"])
        )) { context, args in
            let cpu = try cpu(args)
            guard let name = args["name"]?.stringValue else { throw ToolFailure("name is required") }
            return .text(try context.perform { session in
                let m = session.machine
                guard let value = try address(args, "value", in: m, cpu: cpu) else { throw ToolFailure("value is required") }
                do {
                    try m.setRegister(name, cpu: cpu, to: value)
                } catch {
                    throw ToolFailure("\(error)")
                }
                return registerLine(m, cpu) ?? ""
            })
        },

        Tool(definition: ToolDefinition(
            name: "set_breakpoint",
            description: "Stop when the CPU executes an address (default), or reads or writes it (a watchpoint). Then use continue. Ranges, conditions (e.g. \"A == &41 && [&70] > 3\"), hit counts, and log points (log_message, with {expression}s, instead of stopping) are supported. Expressions can use CYCLES, the 2MHz cycle count, e.g. log_message \"frame at {CYCLES}\"; measure_cycles times code more directly. Returns the breakpoint's ID.",
            inputSchema: schema(["address": prop("string", "Address, expression, symbol, or source line (hello.s:12, with debug info loaded)"),
                                 "end": prop("string", "Last address of a range (default: just address)"),
                                 "type": ["type": "string", "enum": ["execute", "read", "write", "access"],
                                          "description": "What to stop on (default execute; access is read or write)"] as JSONValue,
                                 "condition": prop("string", "Only when this is true"),
                                 "hit_count": prop("integer", "Only stop on this hit (and later ones)"),
                                 "log_message": prop("string", "Log this instead of stopping, e.g. \"A={A} at {PC}, cycle {CYCLES}\""),
                                 "rom_bank": prop("integer", "Host only: only while this sideways bank (0-15) is paged in"),
                                 "cpu": cpuProperty],
                                required: ["address"])
        )) { context, args in
            let cpu = try cpu(args)
            let kind: Breakpoint.Kind = switch args["type"]?.stringValue ?? "execute" {
            case "execute": .execute
            case "read": .read
            case "write": .write
            case "access": .access
            default: throw ToolFailure("type must be execute, read, write or access")
            }
            return .text(try context.perform { session in
                let m = session.machine
                guard let start = try address(args, "address", in: m, cpu: cpu), (0...0xFFFF).contains(start) else {
                    throw ToolFailure("address must be 0-&FFFF")
                }
                let end = try address(args, "end", in: m, cpu: cpu) ?? start
                guard (0...0xFFFF).contains(end) else { throw ToolFailure("end must be 0-&FFFF") }
                let breakpoint = Breakpoint(cpu: cpu, kind: kind, start: UInt16(start), end: UInt16(end),
                                            romBank: args["rom_bank"]?.intValue, condition: args["condition"]?.stringValue,
                                            hitTarget: args["hit_count"]?.intValue, logMessage: args["log_message"]?.stringValue)
                do {
                    let added = try m.debugger.add(breakpoint)
                    return "breakpoint \(added.id): \(describe(added))"
                } catch {
                    throw ToolFailure("condition: \(error)")
                }
            })
        },

        Tool(definition: ToolDefinition(
            name: "list_breakpoints",
            description: "The breakpoints, with hit counts.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let breakpoints = session.machine.debugger.breakpoints
                return breakpoints.isEmpty ? "no breakpoints" : breakpoints.map { "\($0.id): \(describe($0))" }.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "delete_breakpoint",
            description: "Delete a breakpoint by ID, or all of them.",
            inputSchema: schema(["id": prop("integer", "Breakpoint ID"), "all": prop("boolean", "Delete them all")])
        )) { context, args in
            let id = args["id"]?.intValue
            let all = args["all"]?.boolValue ?? false
            guard id != nil || all else { throw ToolFailure("give id, or all: true") }
            return .text(try context.perform { session in
                let debugger = session.machine.debugger
                if all {
                    debugger.removeAllBreakpoints()
                    return "deleted all breakpoints"
                }
                guard debugger.breakpoints.contains(where: { $0.id == id }) else { throw ToolFailure("no breakpoint \(id!)") }
                debugger.remove(id: id!)
                return "deleted breakpoint \(id!)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "continue",
            description: "Run until a breakpoint or watchpoint hits (or max_seconds of emulated time). Also resumes after a stop. Returns where it stopped, the registers and the code there.",
            inputSchema: schema(["max_seconds": prop("number", "Longest to run (default 30)")])
        )) { context, args in
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            return .text(try context.perform { session in
                let reason = session.machine.debugger.run(.continue, maxCycles: Int(maxSeconds * 2_000_000)) {
                    session.advance(cycles: $0)
                }
                return debugSummary(session, cpu: .host, reason: reason)
            })
        },

        Tool(definition: ToolDefinition(
            name: "step",
            description: "Step one CPU: instruction (into subroutines), over (a JSR runs to the next instruction), out (until the subroutine or interrupt handler returns), cycle (one 2MHz cycle), scanline, frame, interrupt (until one starts), to (an address, given in address), or back (to the previous instruction, using the rewind history). Repeats count times. Returns the registers and code.",
            inputSchema: schema(["kind": ["type": "string", "enum": ["instruction", "over", "out", "cycle", "scanline", "frame", "interrupt", "to", "back"],
                                          "description": "What to step (default instruction)"] as JSONValue,
                                 "count": prop("integer", "How many (default 1, max 10000)"),
                                 "address": prop("string", "For kind to: where to run to"),
                                 "max_seconds": prop("number", "Longest per step (default 10)"),
                                 "cpu": cpuProperty])
        )) { context, args in
            let cpu = try cpu(args)
            let count = min(max(args["count"]?.intValue ?? 1, 1), 10_000)
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 10
            return .text(try context.perform { session in
                let m = session.machine
                guard m.hasDebugCPU(cpu) else { throw ToolFailure("there's no second processor") }
                if args["kind"]?.stringValue == "back" {
                    for _ in 0..<count {
                        do {
                            try m.debugger.stepBack(cpu)
                        } catch {
                            throw ToolFailure("\(error)")
                        }
                        if m.debugger.stopReason == .historyStart { break }
                    }
                    return debugSummary(session, cpu: cpu, reason: m.debugger.stopReason)
                }
                let command: RunCommand
                switch args["kind"]?.stringValue ?? "instruction" {
                case "instruction": command = .stepInstruction
                case "over": command = .stepOver
                case "out": command = .stepOut
                case "cycle": command = .stepCycle
                case "scanline": command = .nextScanline
                case "frame": command = .nextFrame
                case "interrupt": command = .nextInterrupt
                case "to":
                    guard let target = try address(args, "address", in: m, cpu: cpu) else { throw ToolFailure("to needs an address") }
                    command = .runToAddress(UInt16(truncatingIfNeeded: target))
                default: throw ToolFailure("unknown kind")
                }
                var reason: StopReason?
                for _ in 0..<count {
                    reason = m.debugger.run(command, cpu: cpu, maxCycles: Int(maxSeconds * 2_000_000)) { session.advance(cycles: $0) }
                    // A breakpoint, or the time limit, ends the run early.
                    if case .breakpoint = reason { break }
                    if reason == nil { break }
                }
                return debugSummary(session, cpu: cpu, reason: reason)
            })
        },

        Tool(definition: ToolDefinition(
            name: "reverse_continue",
            description: "Run backwards to the last time a breakpoint or watchpoint hit (e.g. \"who wrote &70?\": set a write breakpoint on &70, then reverse_continue), using the rewind history (about the last 60 seconds). Stops there, as if it had just hit.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine
                do {
                    try m.debugger.reverseContinue()
                } catch {
                    throw ToolFailure("\(error)")
                }
                return debugSummary(session, cpu: .host, reason: m.debugger.stopReason)
            })
        },

        Tool(definition: ToolDefinition(
            name: "rewind",
            description: "Go back in time: by seconds (of emulated time), or to an exact cycle. History covers about the last 60 seconds. Running on afterwards replaces what came after.",
            inputSchema: schema(["seconds": prop("number", "How far back"),
                                 "cycle": prop("integer", "Or: the cycle to go to")])
        )) { context, args in
            let seconds = args["seconds"]?.doubleValue
            let cycle = args["cycle"]?.intValue
            guard seconds != nil || cycle != nil else { throw ToolFailure("give seconds or cycle") }
            return .text(try context.perform { session in
                let m = session.machine
                guard let rewinder = m.rewinder, let earliest = rewinder.earliestCycle else { throw ToolFailure("no rewind history") }
                let target = cycle.map { UInt64(max(0, $0)) } ?? UInt64(max(Int(earliest), Int(m.cycles) - Int(seconds! * 2_000_000)))
                do {
                    try rewinder.seek(to: max(target, earliest))
                } catch {
                    throw ToolFailure("\(error)")
                }
                return summary(session, extra: "now at cycle \(m.cycles) (history from cycle \(earliest))")
            })
        },

        Tool(definition: ToolDefinition(
            name: "trace",
            description: "Instruction trace: with enable, start recording each CPU's last N instructions (0 stops); otherwise show the last count recorded, with registers before each.",
            inputSchema: schema(["enable": prop("integer", "Start recording this many instructions (0 to stop)"),
                                 "count": prop("integer", "Show the last this many (default 32)"),
                                 "cpu": cpuProperty])
        )) { context, args in
            let cpu = try cpu(args)
            let enable = args["enable"]?.intValue
            let count = min(max(args["count"]?.intValue ?? 32, 1), 10_000)
            return .text(try context.perform { session in
                let m = session.machine
                if let enable {
                    m.debugger.setTracing(capacity: max(0, min(enable, 10_000_000)))
                    return enable > 0 ? "tracing the last \(enable) instructions" : "tracing off"
                }
                guard m.debugger.tracing else { return "tracing is off; call trace with enable first" }
                let disassembler = m.disassembler(cpu)
                let lines = m.debugger.trace(cpu).last(count).map { e -> String in
                    if e.interrupt {
                        return "\(e.cycle)  \(hex(e.pc, 4))  -- interrupt --"
                    }
                    let (text, _) = disassembler.disassemble(at: e.pc) { e.byte(at: $0) }
                    return "\(e.cycle)  \(hex(e.pc, 4))  \(text.padding(toLength: 16, withPad: " ", startingAt: 0)) \(e.registerText)"
                }
                return lines.isEmpty ? "nothing traced yet" : lines.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "assemble",
            description: "Assemble a BeebAsm source file (.asm/.6502; BeebAsm comes with MacBeeb) to a disc, put it in drive 0, load its symbols and source lines into the debugger (so breakpoints can be \"game.asm:42\"), and *RUN the first file it SAVEs (or file). Returns BeebAsm's messages and errors, then the screen. The source must SAVE what it builds, e.g. SAVE \"GAME\", start, end.",
            inputSchema: schema(["source": prop("string", "The BeebAsm source file"),
                                 "run": prop("boolean", "*RUN it (default true)"),
                                 "file": prop("string", "Which SAVEd file to run (default the first)"),
                                 "max_seconds": prop("number", "Longest to run before returning (default 10)"),
                                 "beebasm": prop("string", "Path to beebasm (default: MacBeeb's, then the PATH)")],
                                required: ["source"])
        )) { context, args in
            guard let source = args["source"]?.stringValue else { throw ToolFailure("source is required") }
            let build: BeebAsmBuild
            do {
                build = try BeebAsm.assemble(source: (source as NSString).expandingTildeInPath, beebasm: args["beebasm"]?.stringValue)
            } catch {
                throw ToolFailure("\(error)")
            }
            let run = args["run"]?.boolValue ?? true
            let file = args["file"]?.stringValue ?? build.savedFiles[0]
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 10
            let report = "assembled: saved \(build.savedFiles.joined(separator: ", ")); \(build.symbols.symbolCount) symbols, \(build.symbols.lineCount) source lines"
                + (build.messages.isEmpty ? "" : "\n" + build.messages)
            return .text(try context.perform { session in
                let m = session.machine
                m.insertDisc(try Disc.fromSSD(build.disc))
                // A program SAVEd at &xxxx (not &FFFFxxxx) loads into the
                // second processor if there is one.
                m.debugger.addSymbols(build.symbols, cpu: m.secondProcessor != nil ? .parasite : .host)
                guard run else { return report }
                m.paste("*RUN \(file)\n")
                session.advance(seconds: 0.5)
                _ = runUntilIdle(session, maxSeconds: maxSeconds)
                return summary(session, extra: report)
            })
        },

        Tool(definition: ToolDefinition(
            name: "assemble_baron",
            description: "Assemble Baron sources (.6502; Baron, the successor to BeebAsm, comes with MacBeeb) to a disc, put it in drive 0, load their symbols and source lines into the debugger (so breakpoints can be \"game.6502:42\"), and *RUN the first file saved (or file), or boot the disc if it has a boot option (--opt). Each source assembles on its own and every section with a filename is saved. Returns Baron's messages and errors, then the screen.",
            inputSchema: schema(["sources": ["type": "array", "items": ["type": "string"], "description": "The Baron source files, as you'd give them to baron (a single string is fine too)"],
                                 "arguments": ["type": "array", "items": ["type": "string"], "description": "Extra switches, e.g. [\"-D\", \"DEBUG=1\", \"--opt\", \"3\"] (output switches are MacBeeb's)"],
                                 "run": prop("boolean", "Run it (default true)"),
                                 "file": prop("string", "Which saved file to *RUN (default the first that isn't !BOOT, or boot the disc if it has a boot option)"),
                                 "max_seconds": prop("number", "Longest to run before returning (default 10)"),
                                 "baron": prop("string", "Path to baron (default: MacBeeb's, then the PATH)")],
                                required: ["sources"])
        )) { context, args in
            let sources = args["sources"]?.arrayValue?.compactMap(\.stringValue) ?? args["sources"]?.stringValue.map { [$0] } ?? []
            guard !sources.isEmpty else { throw ToolFailure("sources is required") }
            let build: BaronBuild
            do {
                build = try Baron.assemble(sources: sources.map { ($0 as NSString).expandingTildeInPath },
                                           arguments: args["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                           baron: args["baron"]?.stringValue)
            } catch {
                throw ToolFailure("\(error)")
            }
            let run = args["run"]?.boolValue ?? true
            let file = args["file"]?.stringValue ?? (build.bootOption != 0 ? nil : Baron.runnable(build))
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 10
            let report = "assembled: saved \(build.savedFiles.joined(separator: ", ")); \(build.symbols.symbolCount) symbols, \(build.symbols.lineCount) source lines"
                + (build.messages.isEmpty ? "" : "\n" + build.messages)
            return .text(try context.perform { session in
                let m = session.machine
                m.insertDisc(try Disc.fromSSD(build.disc))
                m.debugger.addSymbols(build.symbols, cpu: m.secondProcessor != nil ? .parasite : .host)
                guard run else { return report }
                if let file {
                    m.paste("*RUN \(file)\n")
                } else {
                    m.shiftBreak()
                }
                session.advance(seconds: 0.5)
                _ = runUntilIdle(session, maxSeconds: maxSeconds)
                return summary(session, extra: report)
            })
        },

        Tool(definition: ToolDefinition(
            name: "load_symbols",
            description: "Load symbols for the debugger: ld65 debug info (ld65 --dbgfile, which also maps code to source lines, so breakpoints can be \"hello.s:12\"), or a label file (ld65 -Ln, VICE, \"name = $1234\" lists). Then addresses and expressions can use the names, and disassembly shows them. The OS entry points (OSWRCH...) and hardware registers are always known.",
            inputSchema: schema(["path": prop("string", "The .dbg or label file"),
                                 "clear": prop("boolean", "Forget this CPU's previously loaded symbols first (the other CPU's are kept)"),
                                 "cpu": cpuProperty],
                                required: ["path"])
        )) { context, args in
            let cpu = try cpu(args)
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let table: SymbolTable
            do {
                table = try SymbolTable.load(path: (path as NSString).expandingTildeInPath)
            } catch {
                throw ToolFailure("\(error)")
            }
            let clear = args["clear"]?.boolValue ?? false
            return .text(try context.perform { session in
                let debugger = session.machine.debugger
                if clear { debugger.clearSymbols(cpu) }
                debugger.addSymbols(table, cpu: cpu)
                return "loaded \(table.symbolCount) symbols and \(table.lineCount) source lines"
            })
        },

        Tool(definition: ToolDefinition(
            name: "lookup_symbol",
            description: "A symbol's address, or the symbols and source line at an address.",
            inputSchema: schema(["name": prop("string", "Symbol name"),
                                 "address": prop("string", "Or an address"),
                                 "cpu": cpuProperty])
        )) { context, args in
            let cpu = try cpu(args)
            return .text(try context.perform { session in
                let m = session.machine
                let symbols = m.debugger.symbols(cpu)
                if let name = args["name"]?.stringValue {
                    guard let value = symbols.address(of: name) else { throw ToolFailure("no symbol \(name)") }
                    return "\(name) = &\(String(value, radix: 16, uppercase: true))"
                }
                guard let address = try address(args, "address", in: m, cpu: cpu) else { throw ToolFailure("give name or address") }
                let a = UInt16(truncatingIfNeeded: address)
                var parts = symbols.names(at: a)
                if parts.isEmpty, let near = symbols.nearest(below: a) { parts.append("\(near.name)+\(near.offset)") }
                if let source = symbols.location(at: a) { parts.append("at \(source)") }
                return parts.isEmpty ? "nothing known at &\(hex(a, 4))" : "&\(hex(a, 4)): " + parts.joined(separator: ", ")
            })
        },

        Tool(definition: ToolDefinition(
            name: "profile",
            description: "Profile: run for some seconds (of emulated time) counting the cycles spent at every address, then report the busiest routines (by symbol) and instructions, time in interrupt handlers, and cycles per frame (a frame is 40,000 cycles, 1/50s).",
            inputSchema: schema(["seconds": prop("number", "How long to run (default 1)"),
                                 "top": prop("integer", "How many instructions to list (default 15)"),
                                 "cpu": cpuProperty, "resume": resumeProperty])
        )) { context, args in
            let cpu = try cpu(args)
            let seconds = min(max(args["seconds"]?.doubleValue ?? 1, 0.01), 120)
            let top = min(max(args["top"]?.intValue ?? 15, 1), 200)
            let resume = args["resume"]?.boolValue ?? true
            return .text(try context.perform { session in
                let m = session.machine
                guard m.hasDebugCPU(cpu) else { throw ToolFailure("there's no second processor") }
                resumeIfStopped(session, resume)
                m.debugger.startProfiling()
                session.advance(seconds: seconds)
                m.debugger.stopProfiling()
                guard let report = m.debugger.profileReport(cpu, top: top) else { return "nothing profiled" }
                return profileText(report, m)
            })
        },

        Tool(definition: ToolDefinition(
            name: "debug_log",
            description: "Output from log-point breakpoints (log_message), oldest first.",
            inputSchema: schema(["count": prop("integer", "Show the last this many (default 50)")])
        )) { context, args in
            let count = max(args["count"]?.intValue ?? 50, 1)
            return .text(try context.perform { session in
                let log = session.machine.debugger.log.suffix(count)
                return log.isEmpty ? "no log output" : log.map { "[\($0.cpu.rawValue) \($0.cycle)] \($0.text)" }.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "measure_cycles",
            description: "A stopwatch: run to from, then to to, and report the cycles between (from the start of the instruction at from to the start of the one at to). With repeat, does it that many times and gives min, average and max. from and to can be the same address, to time one trip round a loop. Leaves the machine stopped at to. Cycles are 2MHz host cycles; for the parasite, its own cycles too (to within a host cycle).",
            inputSchema: schema(["from": prop("string", "Start address, expression or symbol"),
                                 "to": prop("string", "End address, expression or symbol"),
                                 "repeat": prop("integer", "How many times (default 1, max 1000)"),
                                 "max_seconds": prop("number", "Longest to wait for each address (default 10)"),
                                 "cpu": cpuProperty],
                                required: ["from", "to"])
        )) { context, args in
            let cpu = try cpu(args)
            let repeats = min(max(args["repeat"]?.intValue ?? 1, 1), 1000)
            let maxCycles = Int((args["max_seconds"]?.doubleValue ?? 10) * 2_000_000)
            return .text(try context.perform { session in
                let m = session.machine
                guard m.hasDebugCPU(cpu) else { throw ToolFailure("there's no second processor") }
                guard let from = try address(args, "from", in: m, cpu: cpu), let to = try address(args, "to", in: m, cpu: cpu),
                      (0...0xFFFF).contains(from), (0...0xFFFF).contains(to) else {
                    throw ToolFailure("from and to must be 0-&FFFF")
                }
                func run(to target: Int) throws {
                    let reason = m.debugger.run(.runToAddress(UInt16(target)), cpu: cpu, maxCycles: maxCycles) { session.advance(cycles: $0) }
                    guard reason == .stepped(cpu) else {
                        throw ToolFailure("didn't reach &\(hex(UInt16(target), 4))" + (reason.map { ": \($0)" } ?? " in time")
                                          + "\n" + debugSummary(session, cpu: cpu, reason: reason))
                    }
                }
                var times: [Int] = []
                for _ in 0..<repeats {
                    try run(to: from)
                    let start = m.cycles
                    try run(to: to)
                    times.append(Int(m.cycles - start))
                }
                // A 6502 parasite runs at parasiteMHz; a Z80 counts T-states at 6MHz.
                let parasiteScale = cpu == .host ? nil : (m.debugCPUKind(cpu) == .z80 ? 6.0 : Double(m.parasiteMHz)) / 2
                func describe(_ cycles: Double) -> String {
                    var text = String(format: cycles == cycles.rounded() ? "%.0f" : "%.1f", cycles) + " cycles"
                    if let parasiteScale { text += String(format: " (%.0f parasite cycles)", cycles * parasiteScale) }
                    return text + String(format: ", %.1fus", cycles / 2)
                }
                let span = "&\(hex(UInt16(from), 4)) to &\(hex(UInt16(to), 4)) on the \(cpu.rawValue)"
                if times.count == 1 {
                    return "\(span): \(describe(Double(times[0])))"
                }
                let average = Double(times.reduce(0, +)) / Double(times.count)
                var lines = ["\(span), \(times.count) times:",
                             "  min \(describe(Double(times.min()!)))",
                             "  avg \(describe(average))",
                             "  max \(describe(Double(times.max()!)))"]
                if times.count <= 50 { lines.append("  each: " + times.map(String.init).joined(separator: " ")) }
                return lines.joined(separator: "\n")
            })
        },
    ]

    static func profileText(_ r: ProfileReport, _ m: BBCMicro) -> String {
        func percent(_ n: Int) -> String {
            String(format: "%5.1f%%", r.totalCycles > 0 ? Double(n) * 100 / Double(r.totalCycles) : 0)
        }
        // A Z80 counts T-states.
        let hz = r.cpu == .host ? 2_000_000.0 : m.debugCPUKind(r.cpu) == .z80 ? 6_000_000.0 : Double(m.parasiteMHz) * 1_000_000
        var lines = [String(format: "profiled %.2fs on the %@: %d cycles, %d frames (%.0f cycles a frame)",
                            Double(r.totalCycles) / hz, r.cpu.rawValue, r.totalCycles, r.frames, r.cyclesPerFrame),
                     "in interrupt handlers: \(percent(r.interruptCycles))", "routines:"]
        lines += r.routines.prefix(15).map { "  \(percent($0.cycles))  \($0.name)" }
        lines.append("busiest instructions:")
        let disassembler = m.disassembler(r.cpu)
        let symbols = m.debugger.symbols(r.cpu)
        for e in r.hottest {
            let text = symbols.annotate(disassembler.disassemble(at: e.address) { m.codeRead(r.cpu, Int($0)) ?? 0xFF }.text)
            lines.append("  \(percent(e.cycles))  &\(hex(e.address, 4))  \(text.padding(toLength: 16, withPad: " ", startingAt: 0)) \(e.executions) runs")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ b: Breakpoint) -> String {
        let kind = b.kind == .execute ? "execute" : b.kind == .read ? "read" : b.kind == .write ? "write" : "access"
        var text = "\(kind) &\(hex(b.start, 4))" + (b.end != b.start ? "-&\(hex(b.end, 4))" : "")
        if b.cpu == .parasite { text += " on the parasite" }
        if let bank = b.romBank { text += " in bank \(String(bank, radix: 16, uppercase: true))" }
        if let condition = b.condition { text += " if \(condition)" }
        if let target = b.hitTarget { text += " from hit \(target)" }
        if let message = b.logMessage { text += " log \"\(message)\"" }
        if !b.enabled { text += " (disabled)" }
        return text + ", hit \(b.hitCount) times"
    }
}
