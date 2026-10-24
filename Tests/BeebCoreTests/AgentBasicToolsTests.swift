import Foundation
import Testing
@testable import BeebAgentKit
@testable import BeebCore
import BeebHost
import BeebROMs

struct AgentBasicToolsTests {
    static let program = """
    10 total=0
    20 FOR I%=1 TO 3
    30 PROCadd(I%)
    40 NEXT
    50 PRINT total
    60 END
    100 DEF PROCadd(N%)
    110 LOCAL T
    120 T=N%*2
    130 total=total+T
    140 ENDPROC
    """

    func makeTools(_ model: BBCMicro.Model = .modelB) -> AgentTools {
        let session = HeadlessSession { BBCMicro(configuration: BeebROMs.configuration(for: model)) }
        session.machine.runUntilIdle()
        let tools = AgentTools(context: session)
        _ = tools.call("run_command", arguments: ["text": .string(Self.program)])
        return tools
    }

    func text(_ result: ToolResult) -> String {
        result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    @Test func breakpointsSteppingAndVariables() {
        let tools = makeTools()
        let set = text(tools.call("basic_set_breakpoint", arguments: ["line": 120, "condition": "N%=2"]))
        #expect(set.hasPrefix("BASIC breakpoint 1: line 120 if N%=2"), "\(set)")

        let run = text(tools.call("run_command", arguments: ["text": "RUN"]))
        #expect(run.contains("stopped in the debugger: BASIC breakpoint 1 (line 120)"), "\(run)")

        let here = text(tools.call("basic_where", arguments: [:]))
        #expect(here.contains("BASIC stopped at line 120:\n  120 T=N%*2"), "\(here)")
        #expect(here.contains("PROCadd at line 120\n  main program at line 30"), "\(here)")
        #expect(here.contains("locals: N% = 2 (LOCAL), T = 0 (LOCAL)"), "\(here)")
        #expect(here.contains("BASIC: BASIC 2 (host, bank 15)"), "\(here)")

        let list = text(tools.call("basic_list", arguments: ["from": 100, "to": 130]))
        #expect(list.contains(">*120 T=N%*2"), "\(list)")

        let variables = text(tools.call("basic_variables", arguments: [:]))
        #expect(variables.contains("I% = 2"), "\(variables)")
        #expect(variables.contains("total = 2"), "\(variables)")
        #expect(!variables.contains("A% = 0"), "\(variables)")

        let step = text(tools.call("basic_step", arguments: ["kind": "over"]))
        #expect(step.contains("stopped: BASIC step finished"), "\(step)")
        #expect(step.contains("line 130:\n  130 total=total+T"), "\(step)")

        _ = tools.call("basic_set_variable", arguments: ["name": "T", "value": "100"])
        #expect(text(tools.call("basic_evaluate", arguments: ["expression": "T+N%"])) == "102")

        let out = text(tools.call("basic_step", arguments: ["kind": "out"]))
        #expect(out.contains("line 40"), "\(out)")
        #expect(text(tools.call("basic_evaluate", arguments: ["expression": "total"])) == "102")

        _ = tools.call("basic_delete_breakpoint", arguments: ["all": true])
        let finished = text(tools.call("run_command", arguments: ["text": "", "resume": true]))
        #expect(finished.contains("108"), "\(finished)")
    }

    @Test func stopsOnErrors() {
        let tools = makeTools(.master128)
        _ = tools.call("run_command", arguments: ["text": "125 T=T/0"])
        _ = tools.call("basic_stop_on_errors", arguments: ["mode": "untrapped"])
        let run = text(tools.call("run_command", arguments: ["text": "RUN"]))
        #expect(run.contains("stopped in the debugger: BASIC error 18"), "\(run)")
        let here = text(tools.call("basic_where", arguments: [:]))
        #expect(here.contains("BASIC stopped at line 125"), "\(here)")
        #expect(here.contains("error 18: Division by zero"), "\(here)")
        #expect(here.contains("PROCadd at line 125"), "\(here)")
        let list = text(tools.call("basic_list_breakpoints", arguments: [:]))
        #expect(list.contains("stop on errors: untrapped"), "\(list)")
    }
}
