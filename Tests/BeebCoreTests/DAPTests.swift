import Foundation
import Synchronization
import Testing
import BeebAgentKit
import BeebCore
@testable import BeebDAP
import BeebHost
import BeebROMs

final class MessageBox: Sendable {
    let list = Mutex<[JSONValue]>([])
}

/// A scripted DAP client talking to a session.
final class DAPClient: Sendable {
    let box = MessageBox()
    let session: DAPSession
    let host: EmulatorHost
    private let nextSeq = Atomic<Int>(1)

    init(model: BBCMicro.Model = .modelB, secondProcessor: Bool = false) {
        let configuration = BeebROMs.configuration(for: model, secondProcessor: secondProcessor)
        host = EmulatorHost { BBCMicro(configuration: configuration) }
        host.start()
        host.send(.setSpeedLimited(false))
        let box = self.box
        session = DAPSession(host: host, send: { message in box.list.withLock { $0.append(message) } })
    }

    deinit {
        host.stop()
    }

    /// Sends a request and waits for its response.
    func request(_ command: String, _ arguments: JSONValue = .object([:])) async throws -> JSONValue {
        let seq = nextSeq.add(1, ordering: .relaxed).oldValue
        await session.handle(["type": "request", "seq": .number(Double(seq)), "command": .string(command), "arguments": arguments])
        let response = box.list.withLock { list in list.first { $0["type"] == "response" && $0["request_seq"]?.intValue == seq } }
        return try #require(response, "no response to \(command)")
    }

    /// Waits for (and removes) the next event called `name`.
    func event(_ name: String, timeout: Double = 20) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = box.list.withLock { list -> JSONValue? in
                guard let index = list.firstIndex(where: { $0["type"] == "event" && $0["event"]?.stringValue == name }) else { return nil }
                return list.remove(at: index)
            }
            if let found { return found }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("no \(name) event")
        throw CancellationError()
    }
}

struct DAPTests {
    var resources: String { Bundle.module.resourceURL!.appendingPathComponent("Resources/symbols").path }

    @Test func framing() throws {
        var buffer = try DAPServer.frame(["a": 1]) + DAPServer.frame(["b": "two"])
        let partial = try DAPServer.frame(["c": true])
        buffer += partial.prefix(10)
        let messages = DAPServer.messages(from: &buffer)
        #expect(messages == [["a": 1], ["b": "two"]])
        buffer += partial.dropFirst(10)
        #expect(DAPServer.messages(from: &buffer) == [["c": true]])
        #expect(buffer.isEmpty)
    }

    @Test func debuggingASourceProgram() async throws {
        let client = DAPClient()
        let initialize = try await client.request("initialize", ["adapterID": "macbeeb"])
        #expect(initialize["body"]?["supportsStepBack"] == true)
        _ = try await client.event("initialized")

        let launch = try await client.request("launch", ["program": .string(resources + "/hello.bin")])
        #expect(launch["success"] == true, "\(launch)")
        let output = try await client.event("output")
        #expect(output["body"]?["output"]?.stringValue?.contains("source lines") == true)

        // A breakpoint on a blank line moves to the next with code.
        let set = try await client.request("setBreakpoints", ["source": ["path": .string(resources + "/hello.s")],
                                                              "breakpoints": [["line": 17]]])
        let breakpoint = try #require(set["body"]?["breakpoints"]?.arrayValue?.first)
        #expect(breakpoint["verified"] == true && breakpoint["line"] == 19, "\(set)")
        _ = try await client.request("configurationDone")

        let stopped = try await client.event("stopped")
        #expect(stopped["body"]?["reason"] == "breakpoint" && stopped["body"]?["threadId"] == 1, "\(stopped)")

        let threads = try await client.request("threads")
        #expect(threads["body"]?["threads"]?.arrayValue?.count == 1)

        let trace = try await client.request("stackTrace", ["threadId": 1])
        let frames = try #require(trace["body"]?["stackFrames"]?.arrayValue)
        #expect(frames[0]["name"] == "print" && frames[0]["line"] == 19, "\(frames)")
        #expect(frames[0]["source"]?["path"]?.stringValue == resources + "/hello.s")
        // Called from loop's JSR at hello.s:12.
        #expect(frames.count >= 2 && frames[1]["line"] == 12 && frames[1]["name"] == "loop+5", "\(frames)")

        let registers = try await client.request("variables", ["variablesReference": 1])
        let a = registers["body"]?["variables"]?.arrayValue?.first { $0["name"] == "A" }
        #expect(a?["value"] == "&48 (72)", "\(registers)") // "H"

        let evaluated = try await client.request("evaluate", ["expression": "message", "context": "hover"])
        #expect(evaluated["body"]?["result"]?.stringValue?.hasPrefix("&2017 (8215)  [48 45 4C 4C") == true, "\(evaluated)")

        let memory = try await client.request("readMemory", ["memoryReference": "0x2017", "count": 5])
        #expect(memory["body"]?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) } == Data("HELLO".utf8))

        let code = try await client.request("disassemble", ["memoryReference": "0x2011", "instructionCount": 2])
        let lines = try #require(code["body"]?["instructions"]?.arrayValue)
        #expect(lines.map { $0["instruction"]?.stringValue } == ["INC count", "JMP OSWRCH"], "\(lines)")
        #expect(lines[0]["line"] == 19)
        let before = try await client.request("disassemble", ["memoryReference": "0x2011", "instructionOffset": -2, "instructionCount": 3])
        // Two before the reference, then the reference.
        #expect(before["body"]?["instructions"]?.arrayValue?.map { $0["address"] } == ["0x200D", "0x2010", "0x2011"], "\(before)")

        // Step, then back again.
        _ = try await client.request("next", ["threadId": 1])
        #expect(try await client.event("stopped")["body"]?["reason"] == "step")
        let afterStep = try await client.request("stackTrace", ["threadId": 1])
        #expect(afterStep["body"]?["stackFrames"]?.arrayValue?.first?["line"] == 20)
        _ = try await client.request("stepBack", ["threadId": 1])
        _ = try await client.event("stopped")
        let back = try await client.request("stackTrace", ["threadId": 1])
        #expect(back["body"]?["stackFrames"]?.arrayValue?.first?["line"] == 19)

        // Watch count, and log at loop instead of stopping there.
        let info = try await client.request("dataBreakpointInfo", ["name": "count"])
        let dataId = try #require(info["body"]?["dataId"]?.stringValue)
        _ = try await client.request("setBreakpoints", ["source": ["path": .string(resources + "/hello.s")],
                                                        "breakpoints": [["line": 10, "logMessage": "X={X}"]]])
        _ = try await client.request("setDataBreakpoints", ["breakpoints": [["dataId": .string(dataId), "accessType": "write"]]])
        // (It stops again before a poll could see it running, so there's no
        // continued event; the client asked to continue, so needn't be told.)
        _ = try await client.request("continue", ["threadId": 1])
        // At INC count, so the watchpoint hits at once; next time round,
        // the log point runs first.
        let watch = try await client.event("stopped")
        #expect(watch["body"]?["reason"] == "data breakpoint", "\(watch)")
        _ = try await client.request("continue", ["threadId": 1])
        _ = try await client.event("stopped")
        let log = try await client.event("output")
        #expect(log["body"]?["output"] == "X=&1\n", "\(log)")

        _ = try await client.request("disconnect")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.host.debugStop == nil)
    }

    @Test func stopOnEntryAndSettingRegisters() async throws {
        let client = DAPClient()
        _ = try await client.request("initialize")
        _ = try await client.request("launch", ["program": .string(resources + "/hello.bin"), "stopOnEntry": true])
        _ = try await client.request("configurationDone")
        let stopped = try await client.event("stopped")
        #expect(stopped["body"]?["reason"] == "entry", "\(stopped)")
        let set = try await client.request("setVariable", ["variablesReference": 1, "name": "A", "value": "&41"])
        #expect(set["body"]?["value"] == "&41 (65)")
        let function = try await client.request("setFunctionBreakpoints", ["breakpoints": [["name": "done"], ["name": "nowhere"]]])
        let results = function["body"]?["breakpoints"]?.arrayValue
        #expect(results?.map { $0["verified"] } == [true, false])
        _ = try await client.request("continue")
        let done = try await client.event("stopped")
        #expect(done["body"]?["reason"] == "breakpoint")
        let pc = try await client.request("evaluate", ["expression": "PC"])
        #expect(pc["body"]?["result"]?.stringValue?.hasPrefix("&200D") == true)
        _ = try await client.request("disconnect")
    }

    // MARK: BASIC

    static let basicProgram = """
    REM adder
    total=0
    FOR I%=1 TO 3
    PROCadd(I%)
    NEXT
    PRINT total
    END

    DEF PROCadd(N%)
    LOCAL T
    T=N%*2:total=total+T
    ENDPROC
    """

    func basicFile(_ text: String, name: String = "adder.bas") throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-dap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test(arguments: [false, true])
    func debuggingABasicProgram(secondProcessor: Bool) async throws {
        let path = try basicFile(Self.basicProgram)
        let client = DAPClient(secondProcessor: secondProcessor)
        let thread = secondProcessor ? 2 : 1
        let initialize = try await client.request("initialize")
        #expect(initialize["body"]?["exceptionBreakpointFilters"]?.arrayValue?.count == 2)
        let launch = try await client.request("launch", ["basic": .string(path)])
        #expect(launch["success"] == true, "\(launch)")
        // The blank line's breakpoint moves to the DEF after it.
        let set = try await client.request("setBreakpoints", ["source": ["path": .string(path)],
                                                              "breakpoints": [["line": 11, "condition": "N%=2"], ["line": 8]]])
        let results = try #require(set["body"]?["breakpoints"]?.arrayValue)
        #expect(results.map { $0["line"] } == [11, 9] && results.allSatisfy { $0["verified"] == true }, "\(set)")
        // Only the first, then.
        _ = try await client.request("setBreakpoints", ["source": ["path": .string(path)],
                                                        "breakpoints": [["line": 11, "condition": "N%=2"]]])
        _ = try await client.request("configurationDone")

        let stopped = try await client.event("stopped")
        #expect(stopped["body"]?["reason"] == "breakpoint" && stopped["body"]?["threadId"] == .number(Double(thread)), "\(stopped)")
        let trace = try await client.request("stackTrace", ["threadId": .number(Double(thread))])
        let frames = try #require(trace["body"]?["stackFrames"]?.arrayValue)
        #expect(frames.map { $0["name"] } == ["PROCadd", "main program"], "\(frames)")
        #expect(frames.map { $0["line"] } == [11, 4])
        #expect(frames[0]["source"]?["path"]?.stringValue == path)

        let scopes = try await client.request("scopes", ["frameId": frames[0]["id"]!])
        #expect(scopes["body"]?["scopes"]?.arrayValue?.first?["name"] == "Locals")
        let locals = try await client.request("variables", ["variablesReference": .number(Double(DAPSession.basicLocals))])
        let values = locals["body"]?["variables"]?.arrayValue?.map { "\($0["name"]!.stringValue!)=\($0["value"]!.stringValue!)" }
        #expect(values == ["N%=2", "T=0"], "\(locals)")
        let evaluated = try await client.request("evaluate", ["expression": "total*10", "frameId": frames[0]["id"]!])
        #expect(evaluated["body"]?["result"] == "20", "\(evaluated)")
        let changed = try await client.request("setVariable", ["variablesReference": .number(Double(DAPSession.basicLocals)),
                                                               "name": "N%", "value": "5"])
        #expect(changed["body"]?["value"] == "5")

        // A statement, then out to the main program.
        _ = try await client.request("next", ["threadId": .number(Double(thread))])
        #expect(try await client.event("stopped")["body"]?["reason"] == "step")
        let next = try await client.request("stackTrace", ["threadId": .number(Double(thread))])
        #expect(next["body"]?["stackFrames"]?.arrayValue?.first?["line"] == 11)
        #expect(next["body"]?["stackFrames"]?.arrayValue?.first?["column"] == 8, "\(next)")
        _ = try await client.request("stepOut", ["threadId": .number(Double(thread))])
        _ = try await client.event("stopped")
        let out = try await client.request("stackTrace", ["threadId": .number(Double(thread))])
        #expect(out["body"]?["stackFrames"]?.arrayValue?.map { $0["line"] } == [5], "\(out)")
        // 2 + 10 so far.
        let total = try await client.request("evaluate", ["expression": "total"])
        #expect(total["body"]?["result"] == "12", "\(total)")
        _ = try await client.request("disconnect")
    }

    @Test func basicErrorsAreExceptions() async throws {
        let path = try basicFile("10 X=0\n20 PRINT 1/X\n")
        let client = DAPClient(model: .master128)
        _ = try await client.request("initialize")
        _ = try await client.request("launch", ["basic": .string(path)])
        _ = try await client.request("setExceptionBreakpoints", ["filters": ["basicUntrapped"]])
        _ = try await client.request("configurationDone")
        let stopped = try await client.event("stopped")
        #expect(stopped["body"]?["reason"] == "exception", "\(stopped)")
        #expect(stopped["body"]?["description"]?.stringValue?.hasPrefix("Division by zero (error 18) at line 20") == true, "\(stopped)")
        let info = try await client.request("exceptionInfo", ["threadId": 1])
        #expect(info["body"]?["exceptionId"] == "BASIC error 18" && info["body"]?["breakMode"] == "unhandled", "\(info)")
        let trace = try await client.request("stackTrace", ["threadId": 1])
        #expect(trace["body"]?["stackFrames"]?.arrayValue?.first?["line"] == 2)
        _ = try await client.request("disconnect")
        let after = try await client.request("continue")
        #expect(after["success"] == true)
        #expect(try await client.host.performAsync { $0.machine.debugger.basic.errorStop } == .off)
    }

    @Test func aTokenisedProgramIsListedToShow() async throws {
        let tokenised = try BBCBasic.tokenise("10 FOR I%=1 TO 2\n20 PRINT I%\n30 NEXT\n")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-dap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("LOOP").path
        try Data(tokenised).write(to: URL(fileURLWithPath: path))
        let client = DAPClient()
        _ = try await client.request("initialize")
        _ = try await client.request("launch", ["basic": .string(path), "stopOnEntry": true])
        _ = try await client.request("configurationDone")
        _ = try await client.event("stopped")
        let trace = try await client.request("stackTrace", ["threadId": 1])
        let frame = try #require(trace["body"]?["stackFrames"]?.arrayValue?.first)
        let listing = try #require(frame["source"]?["path"]?.stringValue)
        #expect(listing.hasSuffix("LOOP.bas") && frame["line"] == 1, "\(frame)")
        #expect(try String(contentsOfFile: listing, encoding: .utf8) == "10 FOR I%=1 TO 2\n20 PRINT I%\n30 NEXT\n")
        // A breakpoint in the listing.
        let set = try await client.request("setBreakpoints", ["source": ["path": .string(listing)], "breakpoints": [["line": 2]]])
        #expect(set["body"]?["breakpoints"]?.arrayValue?.first?["verified"] == true)
        _ = try await client.request("continue")
        let stopped = try await client.event("stopped")
        #expect(stopped["body"]?["reason"] == "breakpoint", "\(stopped)")
        _ = try await client.request("disconnect")
    }

    @Test func theBasicExample() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/hello-basic/primes.bas").path
        let client = DAPClient()
        _ = try await client.request("initialize")
        let launch = try await client.request("launch", ["basic": .string(path)])
        #expect(launch["success"] == true, "\(launch)")
        // count%=count%+1, in PROCshow, the fifth time.
        _ = try await client.request("setBreakpoints", ["source": ["path": .string(path)],
                                                        "breakpoints": [["line": 24, "hitCondition": "5"]]])
        _ = try await client.request("configurationDone")
        let stopped = try await client.event("stopped")
        #expect(stopped["body"]?["reason"] == "breakpoint", "\(stopped)")
        let trace = try await client.request("stackTrace", ["threadId": 1])
        let frames = try #require(trace["body"]?["stackFrames"]?.arrayValue)
        #expect(frames.map { $0["name"] } == ["PROCshow", "main program"] && frames.map { $0["line"] } == [24, 6], "\(frames)")
        let p = try await client.request("evaluate", ["expression": "p%", "frameId": frames[0]["id"]!])
        #expect(p["body"]?["result"] == "11", "\(p)")
        _ = try await client.request("disconnect")
    }
}
