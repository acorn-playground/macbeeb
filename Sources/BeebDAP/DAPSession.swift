// A Debug Adapter Protocol session: lets VS Code (or any DAP client) debug
// the BBC Micro, with source-level breakpoints from ld65 debug info, and
// BBC BASIC programs by their lines (breakpoints in .bas files).
//
// Threads are the CPUs: 1 is the host, 2 the second processor. Stops are
// noticed by polling the host, so they're reported whoever caused them
// (this client, the app's debugger window, an agent).

import BeebAgentKit
import BeebCore
import BeebHost
import BeebROMs
import Foundation

public actor DAPSession {
    let host: EmulatorHost
    private let send: @Sendable (JSONValue) -> Void
    /// Called to change the machine (from a launch configuration), so the
    /// app can keep its own idea of the model in step.
    private let changeMachine: @Sendable (BBCMicro.Model, Bool) -> Void
    private var sequence = 1

    private var launch: JSONValue = .object([:])
    /// The CPU code from the launch configuration runs on.
    private var codeCPU = DebugCPU.host
    /// Breakpoints set through this session, so they can be replaced and
    /// removed: by source file, function names, instructions and data.
    private var sourceBreakpoints: [String: [Int]] = [:]
    private var functionBreakpoints: [Int] = []
    private var instructionBreakpoints: [Int] = []
    private var dataBreakpoints: [Int] = []
    private var lastStop: (reason: StopReason?, count: Int) = (nil, 0)
    private var lastLogCount = 0
    private var poller: Task<Void, Never>?
    private var stepping = false

    /// The BASIC program launched: its text file (a listing, for a
    /// tokenised one), and the program.
    private var basicSource: String?
    private var basicProgram: [UInt8]?
    /// .bas files' lines, by path.
    private var basicFiles: [String: BasicFile] = [:]
    /// BASIC breakpoints set through this session, by file.
    private var basicBreakpoints: [String: [Int]] = [:]
    /// Whether exception breakpoints (BASIC errors) were set.
    private var setErrorStop = false

    /// A BASIC program's text: each line, and the BASIC line numbers'
    /// text lines (from 1) and back.
    struct BasicFile {
        var lines: [String]
        var textLines: [Int: Int]
        var numbers: [(textLine: Int, number: Int)]

        init(text: String) throws {
            lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            numbers = try BBCBasic.lineNumbers(text)
            textLines = Dictionary(numbers.map { ($0.number, $0.textLine) }, uniquingKeysWith: { first, _ in first })
        }

        /// The BASIC line at text line `line`, or the next one after it.
        func number(atOrAfter line: Int) -> (textLine: Int, number: Int)? {
            numbers.first { $0.textLine >= line }
        }

        /// Where statement `statement` starts in BASIC line `number`'s text
        /// (a column from 1), after its line number.
        func column(_ number: Int, statement: Int) -> Int {
            guard let textLine = textLines[number], lines.indices.contains(textLine - 1) else { return 1 }
            let text = Array(lines[textLine - 1].unicodeScalars)
            var i = 0
            while i < text.count, text[i] == " " { i += 1 }
            while i < text.count, ("0"..."9").contains(text[i]) { i += 1 }
            var found = 1
            var quoted = false
            while i < text.count, found < statement {
                if text[i] == "\"" { quoted.toggle() }
                if text[i] == ":" && !quoted { found += 1 }
                i += 1
            }
            while i < text.count, text[i] == " " { i += 1 }
            return i + 1
        }
    }

    static func isBasicFile(_ path: String) -> Bool {
        ["bas", "bbc", "bbcbasic"].contains((path as NSString).pathExtension.lowercased())
    }

    static let hostThread = 1
    static let parasiteThread = 2

    public init(host: EmulatorHost, send: @escaping @Sendable (JSONValue) -> Void,
                changeMachine: @escaping @Sendable (BBCMicro.Model, Bool) -> Void = { _, _ in }) {
        self.host = host
        self.send = send
        self.changeMachine = changeMachine
    }

    // MARK: Messages

    public func handle(_ message: JSONValue) async {
        guard message["type"]?.stringValue == "request", let command = message["command"]?.stringValue,
              let requestSeq = message["seq"]?.intValue else { return }
        let arguments = message["arguments"] ?? .object([:])
        do {
            let body = try await request(command, arguments)
            respond(requestSeq, command, success: true, body: body)
        } catch let error as DAPError {
            respond(requestSeq, command, success: false, message: error.message)
        } catch {
            respond(requestSeq, command, success: false, message: "\(error)")
        }
        if command == "initialize" {
            event("initialized")
        }
    }

    private func respond(_ requestSeq: Int, _ command: String, success: Bool, body: JSONValue? = nil, message: String? = nil) {
        var response: [String: JSONValue] = ["type": "response", "request_seq": .number(Double(requestSeq)),
                                             "success": .bool(success), "command": .string(command)]
        if let body { response["body"] = body }
        if let message { response["message"] = .string(message) }
        emit(response)
    }

    private func event(_ name: String, _ body: JSONValue? = nil) {
        var event: [String: JSONValue] = ["type": "event", "event": .string(name)]
        if let body { event["body"] = body }
        emit(event)
    }

    private func emit(_ message: [String: JSONValue]) {
        var message = message
        message["seq"] = .number(Double(sequence))
        sequence += 1
        send(.object(message))
    }

    struct DAPError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    /// Runs `body` with the machine, on its thread.
    private func machine<T: Sendable>(_ body: @escaping @Sendable (MachineSession) throws -> T) async throws -> T {
        try await host.performAsync(body)
    }

    // MARK: Requests

    private func request(_ command: String, _ args: JSONValue) async throws -> JSONValue? {
        switch command {
        case "initialize":
            startPolling()
            return capabilities
        case "launch":
            try await launchRequest(args, launching: true)
            return nil
        case "attach":
            try await launchRequest(args, launching: false)
            return nil
        case "configurationDone":
            try await start()
            return nil
        case "setBreakpoints": return try await setBreakpoints(args)
        case "setFunctionBreakpoints": return try await setFunctionBreakpoints(args)
        case "setInstructionBreakpoints": return try await setInstructionBreakpoints(args)
        case "setExceptionBreakpoints": return try await setExceptionBreakpoints(args)
        case "exceptionInfo": return try await exceptionInfo()
        case "dataBreakpointInfo": return try await dataBreakpointInfo(args)
        case "setDataBreakpoints": return try await setDataBreakpoints(args)
        case "threads": return try await threads()
        case "stackTrace": return try await stackTrace(args)
        case "scopes": return scopes(args)
        case "variables": return try await variables(args)
        case "setVariable": return try await setVariable(args)
        case "evaluate": return try await evaluate(args)
        case "readMemory": return try await readMemory(args)
        case "writeMemory": return try await writeMemory(args)
        case "disassemble": return try await disassemble(args)
        case "continue":
            try await machine { $0.machine.debugger.resume() }
            return ["allThreadsContinued": true]
        case "next": return try await step(.stepOver, basic: .over, args)
        case "stepIn": return try await step(.stepInstruction, basic: .into, args)
        case "stepOut": return try await step(.stepOut, basic: .out, args)
        case "stepBack":
            let cpu = Self.cpu(args)
            try await machine { s in try s.machine.debugger.stepBack(cpu) }
            return nil
        case "reverseContinue":
            try await machine { s in try s.machine.debugger.reverseContinue() }
            return nil
        case "pause":
            try await pause()
            return nil
        case "disconnect", "terminate":
            try await disconnect()
            if command == "terminate" { event("terminated") }
            return nil
        default:
            throw DAPError("\(command) isn't supported")
        }
    }

    private var capabilities: JSONValue {
        [
            "supportsConfigurationDoneRequest": true,
            "supportsConditionalBreakpoints": true,
            "supportsHitConditionalBreakpoints": true,
            "supportsLogPoints": true,
            "supportsFunctionBreakpoints": true,
            "supportsInstructionBreakpoints": true,
            "supportsDataBreakpoints": true,
            "supportsStepBack": true,
            "supportsSetVariable": true,
            "supportsEvaluateForHovers": true,
            "supportsReadMemoryRequest": true,
            "supportsWriteMemoryRequest": true,
            "supportsDisassembleRequest": true,
            "supportsSteppingGranularity": true,
            "supportsTerminateRequest": true,
            "supportsValueFormattingOptions": false,
            "supportsExceptionInfoRequest": true,
            "exceptionBreakpointFilters": [
                ["filter": "basicUntrapped", "label": "BASIC errors", "default": true,
                 "description": "Stop where a BASIC error happens that no ON ERROR handles (Escape and STOP too)"],
                ["filter": "basicAll", "label": "All BASIC errors", "default": false,
                 "description": "Stop at every BASIC error, before ON ERROR sees it"],
            ],
        ]
    }

    static func cpu(_ args: JSONValue) -> DebugCPU {
        args["threadId"]?.intValue == parasiteThread ? .parasite : .host
    }

    // MARK: Launching

    /// launch: model, secondProcessor, disc, program (+ loadAddress,
    /// execAddress), symbols, stopOnEntry, cpu. attach: symbols, cpu.
    private func launchRequest(_ args: JSONValue, launching: Bool) async throws {
        launch = args
        // A launch is a new program: forget the last one's symbols.
        if launching {
            try await machine { $0.machine.debugger.clearSymbols() }
        }
        let model = args["model"]?.stringValue.flatMap(Self.model)
        let secondProcessor = args["secondProcessor"]?.boolValue
        if launching, model != nil || secondProcessor != nil {
            let current = try await machine { ($0.machine.model, $0.machine.secondProcessor != nil) }
            let wanted = (model ?? current.0, secondProcessor ?? current.1)
            if wanted != current {
                changeMachine(wanted.0, wanted.1)
                // Wait for the new machine.
                for _ in 0..<100 {
                    let now = try await machine { ($0.machine.model, $0.machine.secondProcessor != nil) }
                    if now == wanted { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        let hasSecondProcessor = try await machine { $0.machine.secondProcessor != nil }
        if launching, let path = args["basic"]?.stringValue {
            try loadBasicSource(path)
        }
        if let name = args["cpu"]?.stringValue, let cpu = DebugCPU(rawValue: name) {
            codeCPU = cpu
        } else {
            // BASIC's CALL (or *RUN) runs code in the second processor, if
            // there is one.
            codeCPU = hasSecondProcessor && (args["program"] != nil || args["source"] != nil) ? .parasite : .host
        }

        // A BeebAsm source: assemble it now, run it on configurationDone.
        if launching, let source = args["source"]?.stringValue {
            let build: BeebAsmBuild
            do {
                build = try BeebAsm.assemble(source: source, beebasm: args["beebasm"]?.stringValue)
            } catch {
                throw DAPError("\(error)")
            }
            if !build.messages.isEmpty { output(build.messages + "\n") }
            output("Assembled \((source as NSString).lastPathComponent): \(build.savedFiles.joined(separator: ", ")); \(build.symbols.symbolCount) symbols, \(build.symbols.lineCount) source lines\n")
            let cpu = codeCPU
            let disc = build.disc
            let symbols = build.symbols
            try await machine { s in
                s.machine.insertDisc(try Disc.fromSSD(disc))
                s.machine.debugger.addSymbols(symbols, cpu: cpu)
            }
            let name = args["file"]?.stringValue ?? build.savedFiles[0]
            beebAsmRun = name
            beebAsmEntry = (try? DFSDisc(side: disc))?.file(named: name).map { UInt16(truncatingIfNeeded: $0.executionAddress) }
        }

        var symbolsPath = args["symbols"]?.stringValue
        if symbolsPath == nil, let program = args["program"]?.stringValue {
            let dbg = (program as NSString).deletingPathExtension + ".dbg"
            if FileManager.default.fileExists(atPath: dbg) { symbolsPath = dbg }
        }
        if let path = symbolsPath {
            let table = try SymbolTable.load(path: path)
            let cpu = codeCPU
            try await machine { $0.machine.debugger.addSymbols(table, cpu: cpu) }
            output("Loaded \(table.symbolCount) symbols and \(table.lineCount) source lines from \((path as NSString).lastPathComponent)\n")
        }

        if launching {
            // Get to the BASIC prompt, then wait for configurationDone.
            try await machine { s in
                let m = s.machine
                m.debugger.resume()
                if let disc = args["disc"]?.stringValue {
                    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: disc)))
                    let image = try Disc.fromImage(bytes, named: disc)
                    m.insertDisc(image)
                }
                m.watchForIdle(true)
                _ = s.advance(until: { m.reachedIdle }, maxSeconds: 10)
                m.watchForIdle(false)
            }
            if let program = basicProgram {
                let found = try await machine { s -> Bool in
                    let basic = s.machine.debugger.basic
                    guard basic.interpreter(basic.currentCPU) != nil else { return false }
                    basic.load(program)
                    return true
                }
                guard found else { throw DAPError("BASIC isn't running on the BBC Micro (no BASIC ROM found)") }
                output("Loaded \((basicSource! as NSString).lastPathComponent) (\(program.count) bytes) at PAGE\n")
            }
        }
    }

    /// Reads a BASIC program to run: text (lines with or without numbers),
    /// or tokenised (as SAVE writes it), which is listed to a file to show.
    private func loadBasicSource(_ path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else { throw DAPError("can't read \(path)") }
        let bytes = [UInt8](data)
        if BBCBasic.isProgram(bytes) {
            let listing = FileManager.default.temporaryDirectory.appendingPathComponent("MacBeeb BASIC", isDirectory: true)
            try? FileManager.default.createDirectory(at: listing, withIntermediateDirectories: true)
            let file = listing.appendingPathComponent((path as NSString).lastPathComponent + ".bas")
            let text = BBCBasic.list(bytes)
            try Data(text.utf8).write(to: file)
            basicSource = file.path
            basicFiles[file.path] = try BasicFile(text: text)
            basicProgram = bytes
        } else {
            let text = String(decoding: bytes, as: UTF8.self)
            do {
                basicProgram = try BBCBasic.tokenise(text)
                basicFiles[path] = try BasicFile(text: text)
            } catch {
                throw DAPError("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
            basicSource = path
        }
    }

    /// A .bas file's lines, read when first needed.
    private func basicFile(_ path: String) -> BasicFile? {
        if let file = basicFiles[path] { return file }
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? BasicFile(text: String(decoding: data, as: UTF8.self)) else { return nil }
        basicFiles[path] = file
        return file
    }

    /// After the breakpoints are set: run the program.
    private func start() async throws {
        let args = launch
        let stopOnEntry = args["stopOnEntry"]?.boolValue ?? false
        if basicProgram != nil {
            try await machine { s in
                // Stopping on entry: at the first statement.
                if stopOnEntry { s.machine.debugger.begin(basic: .into) }
                s.machine.paste("RUN\n")
            }
        } else if let program = args["program"]?.stringValue {
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: program)))
            let load = args["loadAddress"]?.intValue ?? 0x2000
            let exec = args["execAddress"]?.intValue ?? load
            let cpu = codeCPU
            if stopOnEntry {
                // A one-shot breakpoint: removed when it hits (see reportStop).
                entryBreakpoint = UInt16(exec)
            }
            try await machine { s in
                let m = s.machine
                for (offset, byte) in bytes.enumerated() {
                    m.debugWrite(cpu == .parasite ? .parasiteRAM : .mainRAM, load + offset, byte)
                }
                if stopOnEntry {
                    try m.debugger.add(Breakpoint(cpu: cpu, start: UInt16(exec), hitTarget: 1, logMessage: nil))
                }
                m.paste("CALL &\(String(exec, radix: 16, uppercase: true))\n")
            }
        } else if let name = beebAsmRun {
            let entry = stopOnEntry ? beebAsmEntry : nil
            entryBreakpoint = entry
            let cpu = codeCPU
            try await machine { s in
                if let entry {
                    try s.machine.debugger.add(Breakpoint(cpu: cpu, start: entry))
                }
                s.machine.paste("*RUN \(name)\n")
            }
        } else if args["disc"] != nil {
            try await machine { $0.machine.shiftBreak() }
        } else if stopOnEntry {
            try await machine { $0.machine.debugger.requestStop() }
        }
    }

    private var entryBreakpoint: UInt16?
    /// The BeebAsm build's file to *RUN, and where it starts.
    private var beebAsmRun: String?
    private var beebAsmEntry: UInt16?

    static func model(_ name: String) -> BBCMicro.Model? {
        switch name.lowercased().replacingOccurrences(of: " ", with: "") {
        case "modelb", "b", "model_b": .modelB
        case "bplus", "b+", "b_plus": .bPlus
        case "master", "master128", "master_128": .master128
        case "compact", "mastercompact", "master_compact": .masterCompact
        default: BBCMicro.Model(rawValue: name)
        }
    }

    private func disconnect() async throws {
        poller?.cancel()
        let ids = sourceBreakpoints.values.flatMap { $0 } + functionBreakpoints + instructionBreakpoints + dataBreakpoints
        let basicIDs = basicBreakpoints.values.flatMap { $0 }
        let errorStop = setErrorStop
        try await machine { s in
            for id in ids { s.machine.debugger.remove(id: id) }
            for id in basicIDs { s.machine.debugger.basic.remove(id: id) }
            if errorStop { s.machine.debugger.basic.errorStop = .off }
            s.machine.debugger.resume()
        }
        basicBreakpoints = [:]
        setErrorStop = false
        sourceBreakpoints = [:]
        functionBreakpoints = []
        instructionBreakpoints = []
        dataBreakpoints = []
    }

    private func output(_ text: String, category: String = "console") {
        event("output", ["category": .string(category), "output": .string(text)])
    }

    // MARK: Stops

    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func poll() async {
        let stop = host.debugStopState
        if stop.count != lastStop.count, let reason = stop.reason {
            lastStop = stop
            await reportStop(reason)
        } else if stop.reason == nil && lastStop.reason != nil {
            lastStop = stop
            event("continued", ["threadId": .number(Double(Self.hostThread)), "allThreadsContinued": true])
        }
        // Log points' output.
        if let (count, entries) = try? await machine({ s -> (Int, [String]) in
            let log = s.machine.debuggerIfCreated?.log ?? []
            return (log.count, log.suffix(50).map(\.text))
        }), count != lastLogCount {
            let new = count > lastLogCount ? entries.suffix(min(entries.count, count - lastLogCount)) : entries.suffix(0)
            for line in new { output(line + "\n") }
            lastLogCount = count
        }
    }

    private func reportStop(_ stop: StopReason) async {
        var body: [String: JSONValue] = ["allThreadsStopped": true]
        var thread = Self.hostThread
        var reason = "pause"
        switch stop {
        case .breakpoint(let id, let cpu, let address, let kind):
            thread = cpu == .parasite ? Self.parasiteThread : Self.hostThread
            if address == entryBreakpoint && kind == .execute {
                reason = "entry"
                entryBreakpoint = nil
                _ = try? await machine { $0.machine.debugger.remove(id: id) }
            } else {
                reason = kind == .execute ? "breakpoint" : "data breakpoint"
                body["hitBreakpointIds"] = [.number(Double(id))]
            }
        case .stepped(let cpu):
            thread = cpu == .parasite ? Self.parasiteThread : Self.hostThread
            reason = "step"
        case .interrupt(let cpu):
            thread = cpu == .parasite ? Self.parasiteThread : Self.hostThread
            reason = "step"
        case .frame, .scanline:
            reason = "step"
        case .requested:
            reason = "pause"
        case .historyStart:
            reason = "step"
            body["description"] = "Reached the start of the rewind history"
        case .basicBreakpoint(let id, let cpu, _):
            thread = cpu == .parasite ? Self.parasiteThread : Self.hostThread
            reason = "breakpoint"
            body["hitBreakpointIds"] = [.number(Double(id))]
        case .basicStepped(let cpu):
            thread = cpu == .parasite ? Self.parasiteThread : Self.hostThread
            reason = "step"
        case .basicError(let cpu, _):
            thread = cpu == .parasite ? Self.parasiteThread : Self.hostThread
            reason = "exception"
            if let error = try? await machine({ $0.machine.debugger.basic.error }) {
                body["description"] = .string("\(error.message) (error \(error.number)) at \(error.location)")
            }
        }
        body["reason"] = .string(reason)
        body["threadId"] = .number(Double(thread))
        body["text"] = .string("\(stop)")
        event("stopped", .object(body))
    }

    /// Steps by BASIC statement when stopped in BASIC (or debugging a
    /// BASIC program), unless asked for instructions.
    private func step(_ command: RunCommand, basic: BasicStep, _ args: JSONValue) async throws -> JSONValue? {
        let cpu = Self.cpu(args)
        let byInstruction = args["granularity"]?.stringValue == "instruction"
        let launchedBasic = basicSource != nil
        try await machine { s in
            let debugger = s.machine.debugger
            if !byInstruction && (debugger.stopReason?.isBasic == true || launchedBasic && debugger.basic.stop != nil) {
                debugger.begin(basic: basic)
                return
            }
            guard s.machine.hasDebugCPU(cpu) else { throw DAPError("there's no second processor") }
            debugger.begin(command, cpu: cpu)
        }
        return nil
    }

    /// Debugging BASIC, a pause stops at the next statement, if one comes
    /// soon (it may be waiting for a key, or not running).
    private func pause() async throws {
        guard basicSource != nil || !basicBreakpoints.isEmpty else {
            try await machine { $0.machine.debugger.requestStop() }
            return
        }
        try await machine { $0.machine.debugger.begin(basic: .into) }
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(20))
            if host.debugStop != nil { return }
        }
        try await machine { s in
            if s.machine.debugger.stopReason == nil { s.machine.debugger.requestStop() }
        }
    }

    // MARK: Breakpoints

    /// Breakpoint request fields that are the same for every kind.
    private static func options(_ b: JSONValue) -> (condition: String?, hitTarget: Int?, log: String?) {
        let condition = b["condition"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let hit = b["hitCondition"]?.stringValue.flatMap { Int($0.filter(\.isNumber)) }
        let log = b["logMessage"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return (condition, hit, log)
    }

    private func setBreakpoints(_ args: JSONValue) async throws -> JSONValue {
        guard let path = args["source"]?["path"]?.stringValue else { throw DAPError("source.path is required") }
        let requested = args["breakpoints"]?.arrayValue ?? []
        if Self.isBasicFile(path) || path == basicSource {
            return try await setBasicBreakpoints(path, requested)
        }
        let old = sourceBreakpoints[path] ?? []
        let cpu = codeCPU
        let results = try await machine { s -> ([Int], [JSONValue]) in
            let debugger = s.machine.debugger
            for id in old { debugger.remove(id: id) }
            var ids: [Int] = []
            var results: [JSONValue] = []
            for b in requested {
                guard let line = b["line"]?.intValue else { continue }
                let (condition, hit, log) = Self.options(b)
                guard let found = debugger.symbols(cpu).addresses(file: path, line: line), let address = found.addresses.min() else {
                    results.append(["verified": false, "line": .number(Double(line)),
                                    "message": "No code at this line (is the debug info loaded?)"])
                    continue
                }
                do {
                    let added = try debugger.add(Breakpoint(cpu: cpu, start: address, condition: condition, hitTarget: hit, logMessage: log))
                    ids.append(added.id)
                    results.append(["id": .number(Double(added.id)), "verified": true, "line": .number(Double(found.line)),
                                    "instructionReference": .string(Self.reference(address))])
                } catch {
                    results.append(["verified": false, "line": .number(Double(line)), "message": .string("Condition: \(error)")])
                }
            }
            return (ids, results)
        }
        sourceBreakpoints[path] = results.0
        return ["breakpoints": .array(results.1)]
    }

    /// Breakpoints in a BASIC program's text: on its BASIC lines.
    private func setBasicBreakpoints(_ path: String, _ requested: [JSONValue]) async throws -> JSONValue {
        let old = basicBreakpoints[path] ?? []
        let file = basicFile(path)
        let results = try await machine { s -> ([Int], [JSONValue]) in
            let basic = s.machine.debugger.basic
            for id in old { basic.remove(id: id) }
            var ids: [Int] = []
            var results: [JSONValue] = []
            for b in requested {
                guard let line = b["line"]?.intValue else { continue }
                guard let target = file?.number(atOrAfter: line) else {
                    results.append(["verified": false, "line": .number(Double(line)), "message": "No BASIC line here"])
                    continue
                }
                let (condition, hit, log) = Self.options(b)
                do {
                    let added = try basic.add(BasicBreakpoint(line: target.number, condition: condition, hitTarget: hit, logMessage: log))
                    ids.append(added.id)
                    results.append(["id": .number(Double(added.id)), "verified": true, "line": .number(Double(target.textLine))])
                } catch {
                    results.append(["verified": false, "line": .number(Double(line)), "message": .string("Condition: \(error)")])
                }
            }
            return (ids, results)
        }
        basicBreakpoints[path] = results.0
        return ["breakpoints": .array(results.1)]
    }

    private func setExceptionBreakpoints(_ args: JSONValue) async throws -> JSONValue {
        let filters = (args["filters"]?.arrayValue ?? []).compactMap(\.stringValue)
        let mode: BasicDebugger.ErrorStop = filters.contains("basicAll") ? .all : filters.contains("basicUntrapped") ? .untrapped : .off
        // Leave errors alone unless asked, or this session asked before.
        if mode != .off || setErrorStop {
            try await machine { $0.machine.debugger.basic.errorStop = mode }
            setErrorStop = mode != .off
        }
        return ["breakpoints": .array(filters.map { _ in ["verified": true] })]
    }

    private func exceptionInfo() async throws -> JSONValue {
        let info = try await machine { s -> (BasicError, BasicDebugger.ErrorStop)? in
            let basic = s.machine.debugger.basic
            return basic.error.map { ($0, basic.errorStop) }
        }
        guard let (error, mode) = info else { throw DAPError("not stopped at an error") }
        return ["exceptionId": .string("BASIC error \(error.number)"), "description": .string(error.message),
                "breakMode": .string(mode == .all && error.trapped ? "always" : "unhandled"),
                "details": ["message": .string("\(error.message) at \(error.location)"),
                            "typeName": .string(error.trapped ? "Error (ON ERROR will handle it)" : "Error")]]
    }

    private func setFunctionBreakpoints(_ args: JSONValue) async throws -> JSONValue {
        let requested = args["breakpoints"]?.arrayValue ?? []
        let old = functionBreakpoints
        let cpu = codeCPU
        let results = try await machine { s -> ([Int], [JSONValue]) in
            let debugger = s.machine.debugger
            for id in old { debugger.remove(id: id) }
            var ids: [Int] = []
            var results: [JSONValue] = []
            for b in requested {
                let name = b["name"]?.stringValue ?? ""
                let (condition, hit, log) = Self.options(b)
                guard let address = (try? DebugExpression(name).evaluate(debugger.expressionContext(cpu))), (0...0xFFFF).contains(address),
                      let added = try? debugger.add(Breakpoint(cpu: cpu, start: UInt16(address), condition: condition, hitTarget: hit, logMessage: log)) else {
                    results.append(["verified": false, "message": .string("Unknown symbol \(name)")])
                    continue
                }
                ids.append(added.id)
                results.append(["id": .number(Double(added.id)), "verified": true])
            }
            return (ids, results)
        }
        functionBreakpoints = results.0
        return ["breakpoints": .array(results.1)]
    }

    private func setInstructionBreakpoints(_ args: JSONValue) async throws -> JSONValue {
        let requested = args["breakpoints"]?.arrayValue ?? []
        let old = instructionBreakpoints
        let results = try await machine { s -> ([Int], [JSONValue]) in
            let debugger = s.machine.debugger
            for id in old { debugger.remove(id: id) }
            var ids: [Int] = []
            var results: [JSONValue] = []
            for b in requested {
                guard let (cpu, base) = Self.parseReference(b["instructionReference"]?.stringValue ?? "") else {
                    results.append(["verified": false])
                    continue
                }
                let address = UInt16(truncatingIfNeeded: base + (b["offset"]?.intValue ?? 0))
                let (condition, hit, log) = Self.options(b)
                guard let added = try? debugger.add(Breakpoint(cpu: cpu, start: address, condition: condition, hitTarget: hit, logMessage: log)) else {
                    results.append(["verified": false])
                    continue
                }
                ids.append(added.id)
                results.append(["id": .number(Double(added.id)), "verified": true])
            }
            return (ids, results)
        }
        instructionBreakpoints = results.0
        return ["breakpoints": .array(results.1)]
    }

    private func dataBreakpointInfo(_ args: JSONValue) async throws -> JSONValue {
        let name = args["name"]?.stringValue ?? ""
        let cpu = codeCPU
        // A variable is a memory location: a symbol, or an address.
        let address = try await machine { s -> Int? in
            if let reference = Self.parseReference(name) { return reference.1 }
            return try? DebugExpression(name).evaluate(s.machine.debugger.expressionContext(cpu))
        }
        guard let address, (0...0xFFFF).contains(address) else {
            return ["dataId": .null, "description": .string("\(name) isn't a memory location")]
        }
        return ["dataId": .string(Self.reference(UInt16(address), cpu: cpu)),
                "description": .string("\(name) (&\(String(address, radix: 16, uppercase: true)))"),
                "accessTypes": ["read", "write", "readWrite"], "canPersist": false]
    }

    private func setDataBreakpoints(_ args: JSONValue) async throws -> JSONValue {
        let requested = args["breakpoints"]?.arrayValue ?? []
        let old = dataBreakpoints
        let results = try await machine { s -> ([Int], [JSONValue]) in
            let debugger = s.machine.debugger
            for id in old { debugger.remove(id: id) }
            var ids: [Int] = []
            var results: [JSONValue] = []
            for b in requested {
                guard let (cpu, address) = Self.parseReference(b["dataId"]?.stringValue ?? "") else {
                    results.append(["verified": false])
                    continue
                }
                let kind: Breakpoint.Kind = switch b["accessType"]?.stringValue {
                case "read": .read
                case "readWrite": .access
                default: .write
                }
                let (condition, hit, _) = Self.options(b)
                guard let added = try? debugger.add(Breakpoint(cpu: cpu, kind: kind, start: UInt16(truncatingIfNeeded: address),
                                                               condition: condition, hitTarget: hit)) else {
                    results.append(["verified": false])
                    continue
                }
                ids.append(added.id)
                results.append(["id": .number(Double(added.id)), "verified": true])
            }
            return (ids, results)
        }
        dataBreakpoints = results.0
        return ["breakpoints": .array(results.1)]
    }

    /// "0x2000" for the host, "parasite:0x2000" for the second processor.
    static func reference(_ address: UInt16, cpu: DebugCPU = .host) -> String {
        (cpu == .parasite ? "parasite:" : "") + String(format: "0x%04X", address)
    }

    static func parseReference(_ text: String) -> (DebugCPU, Int)? {
        var t = Substring(text)
        var cpu = DebugCPU.host
        if t.hasPrefix("parasite:") {
            cpu = .parasite
            t = t.dropFirst("parasite:".count)
        } else if t.hasPrefix("host:") {
            t = t.dropFirst("host:".count)
        }
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return Int(t.dropFirst(2), radix: 16).map { (cpu, $0) } }
        if t.hasPrefix("&") || t.hasPrefix("$") { return Int(t.dropFirst(), radix: 16).map { (cpu, $0) } }
        return Int(t).map { (cpu, $0) }
    }

    // MARK: State

    private func threads() async throws -> JSONValue {
        let parasite = try await machine { $0.machine.debugCPUKind(.parasite) }
        var threads: [JSONValue] = [["id": .number(Double(Self.hostThread)), "name": "Host CPU"]]
        if let parasite {
            threads.append(["id": .number(Double(Self.parasiteThread)),
                            "name": .string(parasite == .z80 ? "Z80 second processor" : "Second processor")])
        }
        return ["threads": .array(threads)]
    }

    /// The current instruction, then likely callers: return addresses on
    /// the stack that follow a JSR.
    private func stackTrace(_ args: JSONValue) async throws -> JSONValue {
        let cpu = Self.cpu(args)
        if let basic = try await basicStackTrace(cpu) {
            return basic
        }
        let frames = try await machine { s -> [JSONValue] in
            let m = s.machine
            let symbols = m.debugger.symbols(cpu)
            let addresses = m.callStack(cpu)
            return addresses.enumerated().map { index, address in
                var frame: [String: JSONValue] = [
                    "id": .number(Double(index + (cpu == .parasite ? 1000 : 0))),
                    "name": .string(Self.frameName(address, symbols)),
                    "instructionPointerReference": .string(Self.reference(address, cpu: cpu)),
                    "line": 0, "column": 0,
                ]
                if let location = symbols.location(at: address) {
                    frame["source"] = ["name": .string((location.file as NSString).lastPathComponent), "path": .string(location.file)]
                    frame["line"] = .number(Double(location.line))
                    frame["column"] = 1
                }
                return .object(frame)
            }
        }
        return ["stackFrames": .array(frames), "totalFrames": .number(Double(frames.count))]
    }

    // MARK: BASIC

    /// BASIC frames' IDs: this, plus the index (0 innermost).
    static let basicFrames = 5000
    /// Variable references: BASIC's locals, other variables, arrays and
    /// @%-Z%; an array's elements are `basicArrays` + its index.
    static let basicLocals = 100, basicVariables = 101, basicArrayList = 102, basicResident = 103
    static let basicArrays = 20000

    /// The PROC/FN calls, if stopped in BASIC on `cpu`, as frames in the
    /// program's source (or, if it's not the program in memory, a listing).
    private func basicStackTrace(_ cpu: DebugCPU) async throws -> JSONValue? {
        let found = try await machine { s -> ([BasicFrame], [(number: Int, text: String)])? in
            let basic = s.machine.debugger.basic
            guard let stop = basic.stop, stop.cpu == cpu else { return nil }
            return (basic.callStack(), basic.listing())
        }
        guard let (frames, listing) = found else { return nil }
        var path = basicSource ?? (basicBreakpoints.count == 1 ? basicBreakpoints.keys.first : nil)
        let known = Set(listing.map(\.number))
        if let p = path, let file = basicFile(p),
           !frames.compactMap({ $0.location?.line }).allSatisfy({ file.textLines[$0] != nil }) || !known.isSubset(of: Set(file.textLines.keys)) {
            path = nil
        }
        if path == nil {
            path = writeListing(listing)
        }
        let file = path.flatMap(basicFile)
        let stackFrames: [JSONValue] = frames.enumerated().map { index, frame in
            var json: [String: JSONValue] = ["id": .number(Double(Self.basicFrames + index)),
                                             "name": .string(frame.name ?? "main program"), "line": 0, "column": 0]
            if let location = frame.location, let path, let file, let line = file.textLines[location.line] {
                json["source"] = ["name": .string((path as NSString).lastPathComponent), "path": .string(path)]
                json["line"] = .number(Double(line))
                json["column"] = .number(Double(file.column(location.line, statement: location.statement)))
            } else if frame.location == nil {
                json["name"] = .string((frame.name ?? "main program") + " (a command typed in)")
            }
            return .object(json)
        }
        return ["stackFrames": .array(stackFrames), "totalFrames": .number(Double(stackFrames.count))]
    }

    /// The program in memory, listed to a file to show.
    private func writeListing(_ listing: [(number: Int, text: String)]) -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacBeeb BASIC", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Program in memory.bas")
        let text = listing.map { "\($0.number)\($0.text)" }.joined(separator: "\n") + "\n"
        guard (try? Data(text.utf8).write(to: url)) != nil, let file = try? BasicFile(text: text) else { return nil }
        basicFiles[url.path] = file
        return url.path
    }

    private func basicScopes(_ frame: Int) -> JSONValue {
        var scopes: [JSONValue] = []
        if frame == 0 {
            scopes.append(["name": "Locals", "presentationHint": "locals", "variablesReference": .number(Double(Self.basicLocals)), "expensive": false])
        }
        scopes += [
            ["name": "Variables", "variablesReference": .number(Double(Self.basicVariables)), "expensive": false],
            ["name": "Arrays", "variablesReference": .number(Double(Self.basicArrayList)), "expensive": false],
            ["name": "@% to Z%", "variablesReference": .number(Double(Self.basicResident)), "expensive": false],
        ]
        return ["scopes": .array(scopes)]
    }

    static func isResident(_ v: BasicVariable) -> Bool { v.address >= 0x0400 && v.address < 0x046C }

    private func basicVariables(_ reference: Int) async throws -> [JSONValue] {
        try await machine { s -> [JSONValue] in
            let basic = s.machine.debugger.basic
            let all = basic.variables()
            let arrays = all.filter { $0.dimensions != nil }
            func json(_ name: String, _ value: BasicValue) -> JSONValue {
                let type = switch value {
                case .integer: "integer"
                case .real: "real"
                case .string: "string"
                }
                return ["name": .string(name), "value": .string(value.description), "type": .string(type),
                        "evaluateName": .string(name), "variablesReference": 0]
            }
            switch reference {
            case Self.basicLocals, Self.basicVariables, Self.basicResident:
                return all.filter { v in
                    guard v.dimensions == nil else { return false }
                    switch reference {
                    case Self.basicLocals: return v.isLocal
                    case Self.basicResident: return Self.isResident(v)
                    default: return !v.isLocal && !Self.isResident(v)
                    }
                }.compactMap { v in v.value.map { json(v.name, $0) } }
            case Self.basicArrayList:
                return arrays.enumerated().map { index, v in
                    let size = v.dimensions!.map(String.init).joined(separator: ",")
                    let count = v.dimensions!.reduce(1) { $0 * ($1 + 1) }
                    return ["name": .string(v.name + size + ")"), "value": .string("\(v.kind.rawValue) array, \(count) elements"),
                            "variablesReference": .number(Double(Self.basicArrays + index)),
                            "indexedVariables": .number(Double(count))]
                }
            default:
                let index = reference - Self.basicArrays
                guard arrays.indices.contains(index) else { return [] }
                let array = arrays[index]
                return basic.elements(of: array, count: 1000).map { indices, value in
                    json(array.name + indices.map(String.init).joined(separator: ",") + ")", value)
                }
            }
        }
    }

    private func setBasicVariable(_ name: String, _ text: String) async throws -> JSONValue {
        let value = try await machine { s -> BasicValue in
            let basic = s.machine.debugger.basic
            do {
                // An element: name(1,2).
                if let open = name.firstIndex(of: "("), name.hasSuffix(")"), name.index(after: open) < name.index(before: name.endIndex) {
                    let indices = name[name.index(after: open)..<name.index(before: name.endIndex)].split(separator: ",").compactMap { Int($0) }
                    try basic.set(String(name[...open]), indices: indices, to: text)
                } else {
                    try basic.set(name, to: text)
                }
                return try basic.evaluate(name)
            } catch {
                throw DAPError("\(error)")
            }
        }
        return ["value": .string(value.description)]
    }

    private func evaluateBasic(_ expression: String) async throws -> JSONValue {
        let value = try await machine { s -> BasicValue in
            do {
                return try s.machine.debugger.basic.evaluate(expression)
            } catch {
                throw DAPError("\(error)")
            }
        }
        return ["result": .string(value.description), "variablesReference": 0]
    }

    static func frameName(_ address: UInt16, _ symbols: SymbolTable) -> String {
        if let near = symbols.nearest(below: address) {
            return near.offset == 0 ? near.name : "\(near.name)+\(near.offset)"
        }
        return "&" + String(format: "%04X", address)
    }

    // Variable references: 1/2 registers, 3/4 flags (host/parasite),
    // 10+ a hardware section.
    private func scopes(_ args: JSONValue) -> JSONValue {
        if let frame = args["frameId"]?.intValue, frame >= Self.basicFrames {
            return basicScopes(frame - Self.basicFrames)
        }
        let parasite = (args["frameId"]?.intValue ?? 0) >= 1000
        return ["scopes": [
            ["name": "Registers", "variablesReference": .number(parasite ? 2 : 1), "expensive": false],
            ["name": "Flags", "variablesReference": .number(parasite ? 4 : 3), "expensive": false],
            ["name": "Hardware", "variablesReference": 10, "expensive": true],
        ]]
    }

    private func variables(_ args: JSONValue) async throws -> JSONValue {
        let reference = args["variablesReference"]?.intValue ?? 0
        if (Self.basicLocals...Self.basicResident).contains(reference) || reference >= Self.basicArrays {
            return ["variables": .array(try await basicVariables(reference))]
        }
        let variables = try await machine { s -> [JSONValue] in
            let m = s.machine
            switch reference {
            case 1, 2:
                let cpu: DebugCPU = reference == 2 ? .parasite : .host
                return m.registers(cpu).map { r in
                    ["name": .string(r.name), "value": .string("&" + String(format: "%0\(r.digits)X", r.value) + " (\(r.value))"),
                     "variablesReference": 0, "memoryReference": .string(Self.reference(UInt16(truncatingIfNeeded: r.value), cpu: cpu))]
                }
            case 3, 4:
                let cpu: DebugCPU = reference == 4 ? .parasite : .host
                return m.flags(cpu).compactMap { flag in
                    flag.register.map { ["name": .string($0), "value": .string(flag.set ? "1" : "0"), "variablesReference": 0] }
                }
            case 10:
                return m.hardwareState.enumerated().map { index, section in
                    ["name": .string(section.name), "value": "", "variablesReference": .number(Double(11 + index))]
                }
            default:
                let sections = m.hardwareState
                let index = reference - 11
                guard sections.indices.contains(index) else { return [] }
                return sections[index].rows.map { ["name": .string($0.label), "value": .string($0.value), "variablesReference": 0] }
            }
        }
        return ["variables": .array(variables)]
    }

    private func setVariable(_ args: JSONValue) async throws -> JSONValue {
        let reference = args["variablesReference"]?.intValue ?? 0
        if (Self.basicLocals...Self.basicResident).contains(reference) || reference >= Self.basicArrays,
           let name = args["name"]?.stringValue, let text = args["value"]?.stringValue {
            return try await setBasicVariable(name, text)
        }
        guard (1...4).contains(reference), let name = args["name"]?.stringValue, let text = args["value"]?.stringValue else {
            throw DAPError("only registers and flags can be set")
        }
        let cpu: DebugCPU = reference % 2 == 0 ? .parasite : .host
        let (value, digits) = try await machine { s -> (Int, Int) in
            let m = s.machine
            let v = try DebugExpression(text.components(separatedBy: " ").first ?? text).evaluate(m.debugger.expressionContext(cpu))
            try m.setRegister(name, cpu: cpu, to: v)
            return (m.register(name, cpu: cpu) ?? v, m.registers(cpu).first { $0.name == name }?.digits ?? 2)
        }
        return ["value": .string(reference <= 2 ? "&" + String(format: "%0\(digits)X", value) + " (\(value))" : "\(value)")]
    }

    private func evaluate(_ args: JSONValue) async throws -> JSONValue {
        guard let expression = args["expression"]?.stringValue else { throw DAPError("expression is required") }
        // In a BASIC frame (or a BASIC program's session), BASIC.
        if let frame = args["frameId"]?.intValue, frame >= Self.basicFrames {
            return try await evaluateBasic(expression)
        }
        if args["frameId"] == nil && basicSource != nil {
            return try await evaluateBasic(expression)
        }
        let cpu = args["frameId"].map { ($0.intValue ?? 0) >= 1000 ? DebugCPU.parasite : .host } ?? codeCPU
        let context = args["context"]?.stringValue ?? "repl"
        let result = try await machine { s -> (String, Int?) in
            let m = s.machine
            let value: Int
            do {
                value = try DebugExpression(expression).evaluate(m.debugger.expressionContext(cpu))
            } catch {
                throw DAPError("\(error)")
            }
            var text = "&" + String(value & 0xFFFF, radix: 16, uppercase: true) + " (\(value))"
            // A name or address: show the memory there too.
            if context == "hover" || m.debugger.symbols(cpu).address(of: expression) != nil {
                let bytes = (0..<8).map { m.debugRead(.cpu(cpu), (value + $0) & 0xFFFF) ?? 0 }
                text += "  [" + bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "]"
            }
            return (text, (0...0xFFFF).contains(value) ? value : nil)
        }
        var body: [String: JSONValue] = ["result": .string(result.0), "variablesReference": 0]
        if let address = result.1 {
            body["memoryReference"] = .string(Self.reference(UInt16(address), cpu: cpu))
        }
        return .object(body)
    }

    private func readMemory(_ args: JSONValue) async throws -> JSONValue {
        guard let (cpu, base) = Self.parseReference(args["memoryReference"]?.stringValue ?? "") else {
            throw DAPError("bad memoryReference")
        }
        let start = base + (args["offset"]?.intValue ?? 0)
        let count = min(max(args["count"]?.intValue ?? 0, 0), 0x10000)
        let bytes = try await machine { s -> [UInt8] in
            var bytes: [UInt8] = []
            for i in 0..<count {
                let a = start + i
                guard (0...0xFFFF).contains(a), let byte = s.machine.debugRead(.cpu(cpu), a) else { break }
                bytes.append(byte)
            }
            return bytes
        }
        return ["address": .string(Self.reference(UInt16(truncatingIfNeeded: start), cpu: cpu)),
                "data": .string(Data(bytes).base64EncodedString()),
                "unreadableBytes": .number(Double(count - bytes.count))]
    }

    private func writeMemory(_ args: JSONValue) async throws -> JSONValue {
        guard let (cpu, base) = Self.parseReference(args["memoryReference"]?.stringValue ?? ""),
              let data = args["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
            throw DAPError("bad memoryReference or data")
        }
        let start = base + (args["offset"]?.intValue ?? 0)
        let bytes = [UInt8](data)
        let written = try await machine { s -> Int in
            var written = 0
            for (i, byte) in bytes.enumerated() where s.machine.debugWrite(.cpu(cpu), start + i, byte) {
                written += 1
            }
            return written
        }
        return ["bytesWritten": .number(Double(written))]
    }

    private func disassemble(_ args: JSONValue) async throws -> JSONValue {
        guard let (cpu, base) = Self.parseReference(args["memoryReference"]?.stringValue ?? "") else {
            throw DAPError("bad memoryReference")
        }
        let start = base + (args["offset"]?.intValue ?? 0)
        let instructionOffset = args["instructionOffset"]?.intValue ?? 0
        let count = min(max(args["instructionCount"]?.intValue ?? 0, 0), 4096)
        let instructions = try await machine { s -> [JSONValue] in
            let m = s.machine
            let disassembler = m.disassembler(cpu)
            let symbols = m.debugger.symbols(cpu)
            let read = { (a: UInt16) in m.codeRead(cpu, Int(a)) ?? 0xFF }
            func length(at a: UInt16) -> Int { disassembler.disassemble(at: a, read: read).length }
            // Before the reference: walk forward from a little way back and
            // keep the instructions that land on it.
            var address = UInt16(truncatingIfNeeded: start)
            if instructionOffset < 0 {
                var from = UInt16(truncatingIfNeeded: start - (-instructionOffset) * 3)
                var starts: [UInt16] = []
                while from < UInt16(truncatingIfNeeded: start) && starts.count < 3 * -instructionOffset {
                    starts.append(from)
                    from &+= UInt16(length(at: from))
                }
                let back = starts.suffix(-instructionOffset)
                address = back.first ?? address
                // Not enough real instructions: pad with the earliest.
                for _ in 0..<(-instructionOffset - back.count) { address &-= 1 }
            } else {
                for _ in 0..<instructionOffset { address &+= UInt16(length(at: address)) }
            }
            var result: [JSONValue] = []
            for _ in 0..<count {
                let (text, n) = disassembler.disassemble(at: address, read: read)
                var instruction: [String: JSONValue] = [
                    "address": .string(Self.reference(address, cpu: cpu)),
                    "instructionBytes": .string((0..<n).map { String(format: "%02X", read(address &+ UInt16($0))) }.joined(separator: " ")),
                    "instruction": .string(symbols.annotate(text)),
                ]
                if let name = symbols.names(at: address).first { instruction["symbol"] = .string(name) }
                if let location = symbols.location(at: address) {
                    instruction["location"] = ["name": .string((location.file as NSString).lastPathComponent), "path": .string(location.file)]
                    instruction["line"] = .number(Double(location.line))
                }
                result.append(.object(instruction))
                address &+= UInt16(n)
            }
            return result
        }
        return ["instructions": .array(instructions)]
    }
}

extension DAPSession.DAPError: CustomStringConvertible {
    var description: String { message }
}
