import Foundation

/// Something that runs agent tools: `AgentTools` in-process, or a
/// connection to the app.
public protocol ToolProvider: Sendable {
    func call(_ name: String, arguments: JSONValue) -> ToolResult
}

extension AgentTools: ToolProvider {}

/// A Model Context Protocol server over stdio: newline-delimited JSON-RPC
/// 2.0, serving the agent tools.
public final class MCPServer {
    let tools: ToolProvider
    let instructions: String
    let output: FileHandle

    public init(tools: ToolProvider, instructions: String, output: FileHandle = .standardOutput) {
        self.tools = tools
        self.instructions = instructions
        self.output = output
    }

    /// Serves requests from stdin until it closes.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                send(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "parse error"]])
                continue
            }
            if let response = handle(message) {
                send(response)
            }
        }
    }

    /// Handles one message; returns the response, or nil for notifications.
    public func handle(_ message: JSONValue) -> JSONValue? {
        let id = message["id"]
        let method = message["method"]?.stringValue ?? ""
        let params = message["params"] ?? [:]

        func result(_ value: JSONValue) -> JSONValue? {
            guard let id else { return nil }
            return ["jsonrpc": "2.0", "id": id, "result": value]
        }

        switch method {
        case "initialize":
            let version = params["protocolVersion"]?.stringValue ?? "2025-06-18"
            return result([
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "macbeeb", "version": "0.1"],
                "instructions": .string(instructions),
            ])
        case "ping":
            return result([:])
        case "tools/list":
            let list = AgentTools.definitions.map { tool -> JSONValue in
                ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
            }
            return result(["tools": .array(list)])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return error(id, -32602, "missing tool name")
            }
            let outcome = tools.call(name, arguments: params["arguments"] ?? [:])
            return result(outcome.json)
        default:
            if method.hasPrefix("notifications/") {
                return nil
            }
            return error(id, -32601, "method not found: \(method)")
        }
    }

    private func error(_ id: JSONValue?, _ code: Int, _ text: String) -> JSONValue? {
        guard let id else { return nil }
        return ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(text)]]
    }

    private func send(_ message: JSONValue) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(message) else { return }
        data.append(0x0A)
        output.write(data)
    }
}

extension ToolResult {
    /// MCP's CallToolResult form.
    public var json: JSONValue {
        let items = content.map { item -> JSONValue in
            switch item {
            case .text(let text):
                return ["type": "text", "text": .string(text)]
            case .png(let data):
                return ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": "image/png"]
            }
        }
        return ["content": .array(items), "isError": .bool(isError)]
    }

    public init(json: JSONValue) {
        let items = json["content"]?.arrayValue ?? []
        content = items.compactMap { item in
            switch item["type"]?.stringValue {
            case "text": return item["text"]?.stringValue.map { .text($0) }
            case "image": return item["data"]?.stringValue.flatMap { Data(base64Encoded: $0) }.map { .png($0) }
            default: return nil
            }
        }
        isError = json["isError"]?.boolValue ?? false
    }
}

/// What agents are told about the machine when they connect.
public let mcpInstructions = """
This server drives an emulated BBC Micro: a Model B (6502 at 2MHz, OS 1.20, BBC BASIC 2, Acorn DFS 1.20), \
a B+ 128K, a Master 128 (65C12, MOS 3.20, BASIC 4, DFS 2.24, ADFS, 128K with shadow RAM), or a Master Compact \
(MOS 5.10, ADFS only), each with two disc drives \
and optionally a 6502, Z80 (CP/M) or ARM (the ARM Evaluation System) Second Processor. get_status says which; power_cycle with model/second_processor switches. \
Time is emulated time: waits are exact and run much faster than real time.

Typical use: run_command for BASIC lines and * commands (fast, returns the OS's output and the screen); \
load_disc with a .ssd/.dsd path to boot software (load_tape for .uef/.csw tapes); type_text or press_keys for programs that read the keyboard directly; \
read_screen_text to see what's on screen (works in all modes); screenshot for graphics; run / run_until_idle to let time pass; \
peek, poke and disassemble for memory and code; start_recording/stop_recording to make a movie.

Debugging: set_breakpoint (execute, or read/write watchpoints, with conditions and log points), then continue; \
step (instruction, over, out, cycle, scanline, frame, interrupt); registers and set_register; trace for the last N instructions; \
peek/poke take a space (main, shadow, bank0-F, os, parasite_ram...; see memory_regions) and addresses can be expressions \
such as "{&FFFE}" or "PC+3". When the debugger stops the machine it stays stopped (other tools say so) until continue or step, \
or a tool that runs the machine (press_keys, run, profile...) carries on from the stop; pass resume: false to leave it stopped. \
Breakpoints and symbols survive restore_snapshot, load_state and power_cycle. \
In the app, the machine runs in real time between tool calls; set_real_time on: false holds it still, so replays are exact. \
Each tool takes cpu: parasite for the second processor. \
Writing BBC code: assemble builds a BeebAsm source (SAVE what it makes), puts the disc in drive 0 and *RUNs it, with \
symbols and source lines for breakpoints like "game.asm:42"; assemble_baron does the same for Baron sources (.6502, sections with a filename). \
History: rewind goes back up to about 60 seconds; step kind back and reverse_continue debug backwards ("who wrote this?").

The machine starts at the BASIC prompt. In BASIC, lines with numbers are stored (then RUN); lines without run immediately. \
Mode 7 is the default screen mode (40x25 teletext text).
"""
