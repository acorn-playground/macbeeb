// The printer port, and Acorn's Econet printer server: bytes as the BBC
// sends them, through the OS's own printer drivers.

import Foundation
import Testing
@testable import BeebCore
import BeebNetwork
import BeebROMs

final class PrinterCapture: @unchecked Sendable {
    var bytes: [UInt8] = []
    /// When each byte was strobed (the machine's 2MHz cycles), if kept.
    var cycles: [UInt64] = []
    var text: String { String(decoding: bytes, as: UTF8.self) }

    /// The longest the printer waited between bytes, from byte `start` on,
    /// in seconds.
    func longestGap(after start: Int) -> Double {
        guard cycles.count > start + 1 else { return 0 }
        return zip(cycles[start...], cycles[(start + 1)...]).map { Double($1 - $0) / 2_000_000 }.max() ?? 0
    }
}

struct PrinterTests {
    /// *FX5,1 (the parallel printer), VDU 2 ... VDU 3: the printer gets the
    /// text, as the OS sends it.
    @Test func parallelPortPrints() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        let capture = PrinterCapture()
        m.printer = ParallelPrinter { byte, _ in capture.bytes.append(byte) }
        m.runUntilIdle()
        m.type("*FX5,1\nVDU 2:PRINT \"HELLO PRINTER\":PRINT \"LINE 2\":VDU 3\n")
        m.runUntilIdle()
        m.run(seconds: 1)
        #expect(capture.text.contains("HELLO PRINTER\r"), "\(capture.bytes)")
        #expect(capture.text.contains("LINE 2\r"), "\(capture.bytes)")
    }

    /// Without a printer the OS waits for one, as a real BBC does.
    @Test func noPrinterNoOutput() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        m.runUntilIdle()
        m.type("*FX5,1\nVDU 2:PRINT \"X\":VDU 3\n")
        m.run(seconds: 1)
        #expect(m.printer == nil)
    }
}

extension EconetRig {
    /// Boots MacBeeb's printer server on machine `index`, with a printer on
    /// its printer port.
    func startPrinterServer(_ index: Int) throws -> PrinterCapture {
        let capture = PrinterCapture()
        machines[index].printer = ParallelPrinter { byte, cycle in
            capture.bytes.append(byte)
            capture.cycles.append(cycle)
        }
        machines[index].insertDisc(try Disc.fromImage(PrinterServer.disc(), format: .ssd), drive: 0)
        run(seconds: 0.5)
        machines[index].shiftBreak()
        run(until: { screen(index).contains("Ready") }, seconds: 30)
        return capture
    }
}

/// MacBeeb's printer server on station 235: clients print with their own
/// network filing system (*FX5,4, VDU 2 ... VDU 3), and what reaches the
/// server's printer is what they printed.
struct PrinterServerTests {
    @Test func printsOverEconet() throws {
        let rig = EconetRig([(.modelB, 235), (.modelB, 1)])
        let printed = try rig.startPrinterServer(0)
        #expect(rig.screen(0).contains("Ready"), "\(rig.screen(0))")
        rig.type(1, "*FX5,4\n")
        rig.type(1, "VDU 2:PRINT \"HELLO FROM ECONET\":PRINT \"SECOND LINE\":VDU 3\n")
        #expect(rig.run(until: { rig.screen(0).contains("Printed") }, seconds: 60), "\(rig.screen(0))")
        #expect(printed.text == "HELLO FROM ECONET\rSECOND LINE\r", "\(printed.text.debugDescription)")
        #expect(rig.screen(0).contains("Job from station 1"))
    }

    /// A longer job, in several packets: nothing lost, nothing twice.
    @Test func longJob() throws {
        let rig = EconetRig([(.modelB, 235), (.modelB, 1)])
        let printed = try rig.startPrinterServer(0)
        rig.type(1, "*FX5,4\n")
        rig.type(1, "VDU 2:FOR I%=1 TO 40:PRINT \"LINE \";I%:NEXT:VDU 3\n")
        #expect(rig.run(until: { rig.screen(0).contains("Printed") }, seconds: 120), "\(rig.screen(0))")
        let expected = (1...40).map { "LINE \($0)\r" }.joined()
        #expect(printed.text == expected, "\(printed.text.debugDescription)")
    }

    /// Two stations printing at once: the server holds the printer for the
    /// first one's job, the second's network software gives up ("No
    /// reply"), and once the first's done the second can print.
    @Test func secondStationWaitsItsTurn() throws {
        let rig = EconetRig([(.modelB, 235), (.modelB, 1), (.modelB, 2)])
        let printed = try rig.startPrinterServer(0)
        for client in [1, 2] { rig.type(client, "*FX5,4\n") }
        rig.machines[1].type("VDU 2:FOR I%=1 TO 20:PRINT \"ONE \";I%:NEXT:VDU 3\n")
        rig.machines[2].type("VDU 2:FOR I%=1 TO 20:PRINT \"TWO \";I%:NEXT:VDU 3\n")
        #expect(rig.run(until: { rig.screen(2).contains("No reply") }, seconds: 120), "\(rig.screen(2))")
        rig.run(until: { rig.screen(0).contains("Printed") }, seconds: 60)
        #expect(printed.text == (1...20).map { "ONE \($0)\r" }.joined(), "\(printed.text.debugDescription)")
        rig.type(2, "VDU 2:PRINT \"TWO, LATER\":VDU 3\n")
        #expect(rig.run(until: { printed.text.hasSuffix("TWO, LATER\r") }, seconds: 60), "\(printed.text.debugDescription)")
    }
}
