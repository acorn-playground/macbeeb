import BeebCore
import BeebHost
import Foundation

/// Debugging BBC BASIC programs: breakpoints on lines, stepping by
/// statement, stopping on errors, the call stack and variables.
extension AgentTools {
    static func describe(_ b: BasicBreakpoint) -> String {
        var text = "line \(b.line)" + (b.statement.map { " statement \($0)" } ?? "")
        if let condition = b.condition { text += " if \(condition)" }
        if let target = b.hitTarget { text += ", from hit \(target)" }
        if let message = b.logMessage { text += ", logging \"\(message)\"" }
        if !b.enabled { text += " (disabled)" }
        return text + " (hits: \(b.hitCount))"
    }

    static func describe(_ v: BasicVariable) -> String {
        let local = v.isLocal ? " (LOCAL)" : ""
        if let dimensions = v.dimensions {
            return "\(v.name)\(dimensions.map(String.init).joined(separator: ","))) array of \(v.kind.rawValue)\(local)"
        }
        return "\(v.name) = \(v.value.map { "\($0)" } ?? "?")\(local)"
    }

    /// Where BASIC stopped: the line, the error (if any) and the calls.
    static func basicWhere(_ m: BBCMicro) -> String? {
        let basic = m.debugger.basic
        guard let stop = basic.stop else { return nil }
        let listing = basic.listing(cpu: stop.cpu)
        var text = "BASIC stopped at \(stop.location)"
        if let line = listing.first(where: { $0.number == stop.location.line }) {
            text += ":\n  \(line.number)\(line.text)"
        }
        if let error = basic.error {
            text += "\nerror \(error.number): \(error.message)" + (error.trapped ? " (ON ERROR will handle it)" : "")
        }
        let frames = basic.callStack()
        if frames.count > 1 {
            text += "\ncalls (innermost first):\n" + frames.map { frame in
                "  \(frame.name ?? "main program") at \(frame.location.map { "\($0)" } ?? "a command typed in")"
            }.joined(separator: "\n")
        }
        let locals = basic.variables().filter(\.isLocal)
        if !locals.isEmpty {
            text += "\nlocals: " + locals.map(describe).joined(separator: ", ")
        }
        return text
    }

    static func basicCPU(_ args: JSONValue, _ m: BBCMicro) throws -> DebugCPU {
        args["cpu"] == nil ? m.debugger.basic.currentCPU : try cpu(args)
    }

    static let basicCPUProperty = ["type": "string", "enum": ["host", "parasite"],
                                   "description": "Whose BASIC (default: where BASIC stopped, or the host; parasite is BASIC on a 6502 second processor)"] as JSONValue

    static let basicTools: [Tool] = [
        Tool(definition: ToolDefinition(
            name: "basic_set_breakpoint",
            description: "Stop a BASIC program at a line (as it enters the line: not at each statement in it, but each time a loop goes back to it), or one statement in a line. Conditions are BASIC expressions with the program's variables (e.g. \"I%>10 AND name$=\\\"FRED\\\"\"); log_message logs instead of stopping, with {expression}s. Works with BASIC 2 and 4, on the host or a 6502 second processor. Then run the program (type RUN) or continue; stops return where it is, with the call stack.",
            inputSchema: schema(["line": prop("integer", "Line number"),
                                 "statement": prop("integer", "Only this statement in the line (1 is the first; each : starts another)"),
                                 "condition": prop("string", "Only when this BASIC expression is true"),
                                 "hit_count": prop("integer", "Only stop on this hit (and later ones)"),
                                 "log_message": prop("string", "Log this instead of stopping, e.g. \"I%={I%} total={total}\"")],
                                required: ["line"])
        )) { context, args in
            guard let line = args["line"]?.intValue, (0...32767).contains(line) else { throw ToolFailure("line must be 0-32767") }
            let breakpoint = BasicBreakpoint(line: line, statement: args["statement"]?.intValue, condition: args["condition"]?.stringValue,
                                             hitTarget: args["hit_count"]?.intValue, logMessage: args["log_message"]?.stringValue)
            return .text(try context.perform { session in
                let basic = session.machine.debugger.basic
                do {
                    let added = try basic.add(breakpoint)
                    var text = "BASIC breakpoint \(added.id): \(describe(added))"
                    if basic.interpreters.isEmpty {
                        text += "\n(no BASIC ROM found yet: it'll stop once BASIC is running)"
                    } else if !basic.listing().isEmpty, !basic.listing().contains(where: { $0.number == line }) {
                        text += "\n(the program in memory has no line \(line))"
                    }
                    return text
                } catch {
                    throw ToolFailure("condition: \(error)")
                }
            })
        },

        Tool(definition: ToolDefinition(
            name: "basic_list_breakpoints",
            description: "The BASIC breakpoints, with hit counts, and whether errors stop the program.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let basic = session.machine.debugger.basic
                let list = basic.breakpoints.isEmpty ? "no BASIC breakpoints" : basic.breakpoints.map { "\($0.id): \(describe($0))" }.joined(separator: "\n")
                return list + "\nstop on errors: \(basic.errorStop.rawValue)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "basic_delete_breakpoint",
            description: "Delete a BASIC breakpoint by ID, or all of them.",
            inputSchema: schema(["id": prop("integer", "Breakpoint ID"), "all": prop("boolean", "Delete them all")])
        )) { context, args in
            let id = args["id"]?.intValue
            let all = args["all"]?.boolValue ?? false
            guard id != nil || all else { throw ToolFailure("give id, or all: true") }
            return .text(try context.perform { session in
                let basic = session.machine.debugger.basic
                if all {
                    basic.removeAllBreakpoints()
                    return "deleted all BASIC breakpoints"
                }
                guard basic.breakpoints.contains(where: { $0.id == id }) else { throw ToolFailure("no BASIC breakpoint \(id!)") }
                basic.remove(id: id!)
                return "deleted BASIC breakpoint \(id!)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "basic_stop_on_errors",
            description: "Whether a BASIC error stops the program in the debugger, where it happened (with the call stack and variables as they were): off, untrapped (errors no ON ERROR handles, including Escape and STOP), or all (before ON ERROR sees them). Errors in commands typed in don't stop.",
            inputSchema: schema(["mode": ["type": "string", "enum": ["off", "untrapped", "all"], "description": "Default untrapped"] as JSONValue])
        )) { context, args in
            guard let mode = BasicDebugger.ErrorStop(rawValue: args["mode"]?.stringValue ?? "untrapped") else {
                throw ToolFailure("mode must be off, untrapped or all")
            }
            return .text(try context.perform { session in
                session.machine.debugger.basic.errorStop = mode
                return "stop on errors: \(mode.rawValue)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "basic_step",
            description: "Step a BASIC program from where it stopped: into (to the next statement, into PROCs, FNs and GOSUBs), over (the next statement in this PROC/FN/subroutine, or its caller once it returns), or out (until this PROC/FN/subroutine returns). Repeats count times. If BASIC isn't stopped, runs to the next statement. Returns where it stopped.",
            inputSchema: schema(["kind": ["type": "string", "enum": ["into", "over", "out"], "description": "Default over"] as JSONValue,
                                 "count": prop("integer", "How many (default 1, max 1000)"),
                                 "max_seconds": prop("number", "Longest per step (default 10)")])
        )) { context, args in
            guard let kind = BasicStep(rawValue: args["kind"]?.stringValue ?? "over") else { throw ToolFailure("kind must be into, over or out") }
            let count = min(max(args["count"]?.intValue ?? 1, 1), 1000)
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 10
            return .text(try context.perform { session in
                let m = session.machine
                var reason: StopReason?
                for _ in 0..<count {
                    reason = m.debugger.run(basic: kind, maxCycles: Int(maxSeconds * 2_000_000)) { session.advance(cycles: $0) }
                    guard case .basicStepped = reason else { break }
                }
                return debugSummary(session, cpu: .host, reason: reason)
            })
        },

        Tool(definition: ToolDefinition(
            name: "basic_where",
            description: "Where the BASIC program is stopped: the line, the error it stopped on (if any), the PROC/FN calls (innermost first) and the current PROC/FN's LOCALs. Also which BASIC ROMs were found.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine
                let basic = m.debugger.basic
                let found = basic.findInterpreters()
                let roms = found.isEmpty ? "no BASIC ROM found"
                    : "BASIC: " + found.map { "\($0.name) (\($0.cpu == .host ? "host, bank \($0.bank ?? 0)" : "parasite"))" }.joined(separator: ", ")
                guard let text = basicWhere(m) else {
                    return roms + "\nnot stopped in BASIC" + (m.debugger.stopReason.map { " (stopped: \($0))" } ?? "")
                }
                return text + "\n" + roms
            })
        },

        Tool(definition: ToolDefinition(
            name: "basic_list",
            description: "The BASIC program in memory, as LIST shows it, marking where it's stopped (>) and breakpoints (*).",
            inputSchema: schema(["from": prop("integer", "First line number (default the start)"),
                                 "to": prop("integer", "Last line number (default the end)"),
                                 "cpu": basicCPUProperty])
        )) { context, args in
            .text(try context.perform { session in
                let m = session.machine
                let basic = m.debugger.basic
                let cpu = try basicCPU(args, m)
                let from = args["from"]?.intValue ?? 0, to = args["to"]?.intValue ?? 65535
                let lines = basic.listing(cpu: cpu).filter { (from...max(from, to)).contains($0.number) }
                guard !lines.isEmpty else { return basic.listing(cpu: cpu).isEmpty ? "no program in memory" : "no lines there" }
                let here = basic.stop?.cpu == cpu ? basic.stop?.location.line : nil
                let breakpoints = Set(basic.breakpoints.filter(\.enabled).map(\.line))
                let width = String(lines.last!.number).count
                return lines.map { line in
                    let mark = (line.number == here ? ">" : " ") + (breakpoints.contains(line.number) ? "*" : " ")
                    let number = String(line.number)
                    return mark + String(repeating: " ", count: width - number.count) + number + line.text
                }.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "basic_variables",
            description: "The BASIC program's variables and their values: @% to Z% (the non-zero ones, unless all), then the rest; arrays with their sizes (elements: show their values too). LOCALs of the PROC/FN it's stopped in are marked. Reading them doesn't disturb the program.",
            inputSchema: schema(["filter": prop("string", "Only names starting with this"),
                                 "all": prop("boolean", "Include @% to Z% when they're 0"),
                                 "elements": prop("integer", "Show up to this many of each array's elements (default 0)"),
                                 "cpu": basicCPUProperty])
        )) { context, args in
            let filter = args["filter"]?.stringValue ?? ""
            let all = args["all"]?.boolValue ?? false
            let elements = min(max(args["elements"]?.intValue ?? 0, 0), 1000)
            return .text(try context.perform { session in
                let m = session.machine
                let basic = m.debugger.basic
                let cpu = try basicCPU(args, m)
                let variables = basic.variables(cpu: cpu).enumerated().filter { index, v in
                    v.name.hasPrefix(filter) && (all || index >= 27 || v.value != .integer(0))
                }.map(\.element)
                guard !variables.isEmpty else { return "no variables" + (filter.isEmpty ? "" : " starting \(filter)") }
                return variables.map { v in
                    var text = describe(v)
                    if elements > 0, v.dimensions != nil {
                        text += "\n" + basic.elements(of: v, count: elements, cpu: cpu).map { indices, value in
                            "  \(v.name)\(indices.map(String.init).joined(separator: ","))) = \(value)"
                        }.joined(separator: "\n")
                    }
                    return text
                }.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "basic_evaluate",
            description: "Evaluate a BASIC expression with the program's variables: numbers, strings, variables, array elements, ? ! $ indirection, PAGE TOP LOMEM HIMEM ERR ERL, and BASIC's operators (+ - * / ^ DIV MOD = <> < > <= >= AND OR EOR NOT). No function calls: nothing in the program runs.",
            inputSchema: schema(["expression": prop("string", "e.g. \"total/count%\" or \"grid%(X%,Y%)\""), "cpu": basicCPUProperty],
                                required: ["expression"])
        )) { context, args in
            guard let source = args["expression"]?.stringValue else { throw ToolFailure("expression is required") }
            return .text(try context.perform { session in
                let m = session.machine
                do {
                    return "\(try m.debugger.basic.evaluate(source, cpu: try basicCPU(args, m)))"
                } catch {
                    throw ToolFailure("\(error)")
                }
            })
        },

        Tool(definition: ToolDefinition(
            name: "basic_set_variable",
            description: "Set a BASIC variable (one that exists) or array element to an expression's value. A string can't be made longer than the space BASIC gave it.",
            inputSchema: schema(["name": prop("string", "e.g. \"count%\", \"total\", \"name$\", or an array as \"grid%(\""),
                                 "indices": ["type": "array", "items": ["type": "integer"], "description": "An array element's indices"],
                                 "value": prop("string", "A BASIC expression, e.g. \"42\", \"\\\"text\\\"\", \"total*2\""),
                                 "cpu": basicCPUProperty],
                                required: ["name", "value"])
        )) { context, args in
            guard let name = args["name"]?.stringValue, let value = args["value"]?.stringValue else { throw ToolFailure("name and value are required") }
            let indices = args["indices"]?.arrayValue?.compactMap(\.intValue)
            return .text(try context.perform { session in
                let m = session.machine
                let basic = m.debugger.basic
                let cpu = try basicCPU(args, m)
                do {
                    try basic.set(name, indices: indices, to: value, cpu: cpu)
                } catch {
                    throw ToolFailure("\(error)")
                }
                let element = indices.map { "\(name)\($0.map(String.init).joined(separator: ",")))" }
                return "\(element ?? name) = \(try basic.evaluate(element ?? name, cpu: cpu))"
            })
        },
    ]
}
