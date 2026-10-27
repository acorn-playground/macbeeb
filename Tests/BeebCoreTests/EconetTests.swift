// Econet: the ADLC and the line, tested through Acorn's own network
// software (DNFS on the Model B, ANFS on the Master). The machines run in
// lockstep on one thread, as a NetworkHost runs them.

import Foundation
import Testing
@testable import BeebCore
import BeebNetwork
import BeebROMs

/// Machines on one line, run in lockstep here (no threads).
final class EconetRig {
    let bus: EconetBus
    var machines: [BBCMicro]

    /// `nula`: the machines (by index) with VideoNuLA fitted.
    init(_ stations: [(BBCMicro.Model, Int)], clockRate: Int? = 200_000, nula: Set<Int> = []) {
        bus = EconetBus(clockRate: clockRate)
        machines = stations.enumerated().map { index, stationModel in
            var configuration = BeebROMs.configuration(for: stationModel.0, econetStation: stationModel.1)
            configuration.videoNuLA = nula.contains(index)
            return BBCMicro(configuration: configuration)
        }
        for machine in machines { bus.attach(machine) }
    }

    /// Puts another machine on the line.
    func add(_ machine: BBCMicro) {
        machines.append(machine)
        bus.attach(machine)
    }

    /// Switches machine `index` off (it leaves the line) or on again (a
    /// fresh machine, with the same disc in drive 0).
    func powerOff(_ index: Int) {
        bus.detach(machines[index])
        poweredOff.insert(index)
    }

    func powerOn(_ index: Int) {
        let old = machines[index]
        let fresh = BBCMicro(configuration: old.configuration)
        fresh.insertDisc(old.drives[0].disc, drive: 0)
        // Its clock carries on from the network's.
        fresh.run(cycles: 0)
        machines[index] = fresh
        bus.attach(fresh)
        poweredOff.remove(index)
    }

    private var poweredOff: Set<Int> = []

    /// Runs every machine `cycles` (whole quanta).
    func run(cycles: Int) {
        var left = cycles
        while left > 0 {
            bus.beginQuantum { _ in true }
            for (index, machine) in machines.enumerated() where !poweredOff.contains(index) {
                machine.run(cycles: bus.delay)
            }
            bus.endQuantum(cycles: bus.delay)
            left -= bus.delay
        }
    }

    func run(seconds: Double) {
        run(cycles: Int(seconds * 2_000_000))
    }

    /// Runs until `done`, checking every 10ms, for up to `seconds`.
    /// (Then a little longer, so what's being printed is finished.)
    @discardableResult
    func run(until done: () -> Bool, seconds: Double = 30) -> Bool {
        var elapsed = 0.0
        while !done() {
            if elapsed >= seconds { return false }
            run(seconds: 0.01)
            elapsed += 0.01
        }
        run(seconds: 0.2)
        return true
    }

    func screen(_ index: Int) -> String {
        machines[index].screenText().joined(separator: "\n")
    }

    /// Types a line into a machine (others keep running) and waits for it
    /// to be taken.
    func type(_ index: Int, _ text: String) {
        machines[index].type(text)
        run(until: { !machines[index].isTyping }, seconds: 60)
    }

    /// Types a BASIC program (lines separated by newlines) and RUNs it.
    func runProgram(_ index: Int, _ program: String) {
        type(index, "NEW\n")
        for line in program.split(separator: "\n") {
            type(index, line + "\n")
        }
        type(index, "RUN\n")
    }
}

/// OSWORD &11: open a receive block on `port`, then wait for a frame and
/// print it.
let econetReceiver = """
10 DIM B% 80,C% 20
20 C%?0=0:C%?1=&7F:C%?2=&77:C%?3=0:C%?4=0:C%!5=B%:C%!9=B%+80
30 X%=C%:Y%=C% DIV 256:A%=&11:CALL &FFF1
40 N%=C%?0:PRINT "OPEN ";N%
50 REPEAT:A%=&33:X%=N%:R%=USR(&FFF4):UNTIL (R% AND &8000)<>0
60 C%?0=N%:X%=C%:Y%=C% DIV 256:A%=&11:CALL &FFF1
70 PRINT "FROM ";C%?3;" GOT ";$B%
"""

/// OSWORD &10: send "HELLO ECONET" to station `to`, port &77.
func econetSender(to station: Int) -> String {
    """
    10 DIM B% 80,C% 20
    20 $B%="HELLO ECONET"
    30 C%?0=&80:C%?1=&77:C%?2=\(station):C%?3=0:C%!4=B%:C%!8=B%+LEN$B%+1
    40 X%=C%:Y%=C% DIV 256:A%=&10:CALL &FFF1
    50 REPEAT:A%=&32:R%=USR(&FFF4):UNTIL (R% AND &8000)=0
    60 PRINT "RESULT ";(R% AND &FF00) DIV 256;" ";C%?0
    """
}

struct EconetTests {
    /// The station links read back, and with no clock the ROM's own "no
    /// clock" (&43) when it tries to send.
    @Test func stationNumberAndNoClock() {
        let rig = EconetRig([(.modelB, 5)], clockRate: nil)
        rig.run(seconds: 1.5)
        rig.type(0, "PRINT ?&FE18\n")
        rig.run(seconds: 0.2)
        #expect(rig.screen(0).contains("\n         5"), "\(rig.screen(0))")
        rig.runProgram(0, econetSender(to: 2))
        #expect(rig.run(until: { rig.screen(0).contains("RESULT") }), "\(rig.screen(0))")
        #expect(rig.screen(0).contains("RESULT 67"), "\(rig.screen(0))")
    }

    @Test func twoStationsSendAndReceive() {
        let rig = EconetRig([(.modelB, 1), (.modelB, 2)])
        rig.run(seconds: 1.5)
        print(rig.screen(0))
        rig.runProgram(1, econetReceiver)
        #expect(rig.run(until: { rig.screen(1).contains("OPEN") }), "\(rig.screen(1))")
        rig.runProgram(0, econetSender(to: 2))
        #expect(rig.run(until: { rig.screen(0).contains("RESULT") }), "\(rig.screen(0))")
        #expect(rig.screen(0).contains("RESULT 0 "), "\(rig.screen(0))")
        #expect(rig.run(until: { rig.screen(1).contains("GOT") }, seconds: 5), "\(rig.screen(1))")
        #expect(rig.screen(1).contains("FROM 1 GOT HELLO ECONET"), "\(rig.screen(1))")
    }

    /// Nobody listening on station 3: the ROM's own "not listening".
    @Test func nobodyListening() {
        let rig = EconetRig([(.modelB, 1), (.modelB, 2)])
        rig.run(seconds: 1.5)
        rig.runProgram(0, econetSender(to: 3))
        #expect(rig.run(until: { rig.screen(0).contains("RESULT") }), "\(rig.screen(0))")
        // &42: not listening.
        #expect(rig.screen(0).contains("RESULT 66"), "\(rig.screen(0))")
    }

    /// Immediate operations, which NFS answers itself on a BBC at BASIC
    /// (DFS selected, no *NET): a POKE puts code in station 2, and a JSR
    /// runs it, typing "A" there. DNFS makes the call from an interrupt it
    /// raises with the system VIA's shift register (mode 2, then a read).
    @Test func remotePokeAndJSR() {
        let rig = EconetRig([(.modelB, 1), (.modelB, 2)])
        rig.run(seconds: 1.5)
        rig.runProgram(0, """
        10 S%=&3000:FOR I%=0 TO 9:READ D%:S%?I%=D%:NEXT
        20 DATA &A9,&8A,&A2,0,&A0,&41,&20,&F4,&FF,&60
        30 C%=&3100:C%?1=0:C%?2=2:C%?3=0:C%!12=&A00
        40 ?C%=&82:C%!4=&FFFF3000:C%!8=&FFFF300A:PROCgo
        50 ?C%=&83:C%!4=&FFFF3000:C%!8=&FFFF3001:PROCgo
        60 END
        70 DEF PROCgo:X%=C%:Y%=C%DIV256:A%=&10:CALL &FFF1
        80 REPEAT A%=&32:U%=USR&FFF4:UNTIL (U%AND&8000)=0
        90 PRINT "RESULT ";(U% DIV 256) AND 255:ENDPROC
        """)
        #expect(rig.run(until: { rig.screen(0).components(separatedBy: "RESULT 0").count == 3 }), "\(rig.screen(0))")
        #expect((0..<10).map { rig.machines[1].peek(UInt16(0xA00 + $0)) } == [0xA9, 0x8A, 0xA2, 0, 0xA0, 0x41, 0x20, 0xF4, 0xFF, 0x60])
        #expect(rig.run(until: { rig.lastLines(1, 1) == ">A" }, seconds: 2), "\(rig.screen(1))")
    }
}

struct EconetDebug {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECONET_DEBUG"] != nil))
    func trace() {
        let rig = EconetRig([(.modelB, 1), (.modelB, 2)])
        var events: [String] = []
        rig.bus.observer = { e in
            let s: String = switch e.symbol {
            case .flag: "F"
            case .byte(let b): String(format: "%02X", b)
            case .check: "c"
            case .abort: "A"
            case .garbage: "G"
            }
            events.append("\(e.time) s\(e.station) \(s)\(e.collided ? "!" : "")")
        }
        rig.run(seconds: 1.5)
        rig.runProgram(1, econetReceiver)
        rig.run(until: { rig.screen(1).contains("OPEN") })
        events.removeAll()
        var accesses: [String] = []
        rig.machines[0].econet?.accessObserver = { accesses.append($0) }
        rig.runProgram(0, econetSender(to: 2))
        defer { print(accesses.suffix(80).joined(separator: "\n")) }
        rig.run(until: { rig.screen(0).contains("RESULT") })
        rig.run(seconds: 0.2)
        print(rig.screen(0))
        print(rig.screen(1))
        // Collapse runs of flags.
        var out: [String] = []
        var flags = 0
        for e in events {
            if e.hasSuffix(" F") { flags += 1; if flags > 3 { continue } } else { flags = 0 }
            out.append(e)
        }
        print(out.prefix(300).joined(separator: "\n"))
        print("events \(events.count)")
    }
}

extension EconetRig {
    /// Starts Acorn's Level 1 file server on machine `index` from the
    /// bundled disc in its drive 0, giving each client the directory
    /// `directories` says (by default its own: A, B, ...).
    func startLevel1FileServer(_ index: Int, clients: [Int], directories: [String]? = nil, disc: Disc? = nil) throws {
        let level1 = BeebROMs.BundledDisc.econetLevel1
        machines[index].insertDisc(try disc ?? Disc.fromImage(level1.data, format: level1.format), drive: 0)
        run(seconds: 1.5)
        type(index, "CH.\"FS\"\n")
        run(until: { screen(index).contains("files per user") })
        type(index, "20\n")
        run(until: { screen(index).contains("Manual?") })
        type(index, "Y\n")
        for (n, station) in clients.enumerated() {
            run(until: { screen(index).hasSuffix("Directory:") || screen(index).contains("Directory:\n") }, seconds: 5)
            type(index, (directories?[n] ?? String(Character(UnicodeScalar(65 + n)!))) + "\n")
            run(until: { screen(index).contains("Station number:") }, seconds: 5)
            type(index, "\(station)\n")
        }
        type(index, "\n")
        run(until: { screen(index).contains("Ready") })
    }

    /// The last non-blank line on machine `index`'s screen.
    func lastLines(_ index: Int, _ count: Int = 6) -> String {
        machines[index].screenText().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .suffix(count).joined(separator: "\n")
    }
}

/// Acorn's Level 1 file server, on a Model B at station 254, serving two
/// Model Bs: everything through DNFS and the server's own software.
struct EconetFileServerTests {
    /// Two stations sharing directory A: one saves, the other loads.
    @Test func saveOnOneLoadOnAnother() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 1), (.modelB, 2)])
        try rig.startLevel1FileServer(0, clients: [1, 2], directories: ["A", "A"])
        for client in [1, 2] {
            rig.type(client, "*NET\n")
        }
        // A BASIC program, saved by station 1 and run by station 2.
        rig.type(1, "10 PRINT \"HELLO FROM STATION \";?&FE18\n")
        rig.type(1, "SAVE \"PROG\"\n")
        #expect(rig.run(until: { rig.lastLines(1, 1) == ">" }), "\(rig.screen(1))")
        rig.type(2, "CHAIN \"PROG\"\n")
        defer { print("STATION 1:\n\(rig.screen(1))\nSTATION 2:\n\(rig.screen(2))\nSERVER:\n\(rig.screen(0))") }
        #expect(rig.run(until: { rig.screen(2).contains("HELLO FROM STATION 2") }), "\(rig.screen(2))")

        // Binary: 1K of a pattern, saved and loaded back elsewhere.
        rig.type(1, "FOR I%=0 TO 1023:I%?&3000=(I%*7+3) AND 255:NEXT\n")
        rig.type(1, "*SAVE DATA 3000+400\n")
        rig.run(until: { rig.lastLines(1, 1) == ">" })
        rig.type(2, "*LOAD DATA 4000\n")
        rig.run(until: { rig.lastLines(2, 1) == ">" })
        rig.run(seconds: 0.5)
        let sent = (0..<1024).map { rig.machines[1].peek(UInt16(0x3000 + $0)) }
        let received = (0..<1024).map { rig.machines[2].peek(UInt16(0x4000 + $0)) }
        let pattern: [UInt8] = (0..<1024).map { (i: Int) -> UInt8 in UInt8((i * 7 + 3) & 255) }
        #expect(sent == pattern)
        #expect(received == sent)
        rig.type(1, "*CAT\n")
        #expect(rig.run(until: { rig.screen(1).contains("DATA") && rig.screen(1).contains("PROG") }), "\(rig.screen(1))")
    }

    /// The Studio starts the server by typing everything at once (as
    /// NetworkSession.fileServerStartup does): the server takes its answers
    /// from the keyboard buffer in turn.
    @Test func startsFromTypedAnswers() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 1), (.modelB, 2)])
        let level1 = BeebROMs.BundledDisc.econetLevel1
        rig.machines[0].insertDisc(try Disc.fromImage(level1.data, format: level1.format), drive: 0)
        rig.run(seconds: 1.5)
        rig.machines[0].type("CH.\"FS\"\n3\nY\nA\n1\nA\n2\n\n")
        #expect(rig.run(until: { rig.screen(0).contains("Ready") }, seconds: 60), "\(rig.screen(0))")
        rig.type(2, "*NET\n")
        rig.type(2, "*CAT\n")
        #expect(rig.run(until: { rig.screen(2).contains("Level 1 FS") }), "\(rig.screen(2))")
    }

    /// Files put on the server's disc from the Mac while it's serving:
    /// the stations load them without the server being restarted, and the
    /// stations' own files stay.
    @Test func filesFromTheMacWhileServing() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 1)])
        let disc = try Disc.fromImage(FileServerDisc.image(), format: .ssd)
        try rig.startLevel1FileServer(0, clients: [1], directories: ["A"], disc: disc)
        rig.type(1, "*NET\n")
        rig.type(1, "10 PRINT \"MINE\"\nSAVE \"MINE\"\n")
        rig.run(until: { rig.lastLines(1, 1) == ">" })

        // From the Mac: a BASIC listing as text, as Disc Contents would.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("FROMMAC.bas")
        try "10 PRINT \"HELLO FROM THE MAC\"\n".write(to: file, atomically: true, encoding: .utf8)
        // (As HostSession.changeVolume does it.)
        let before = try DiscVolume(disc: rig.machines[0].drives[0].disc!)
        var volume = before
        #expect(try FileServerDisc.add([file], to: &volume) == ["A.FROMMAC"])
        rig.machines[0].insertDisc(try Disc.fromImage(volume.image, format: .ssd), drive: 0)
        #expect(rig.machines[0].refreshCachedCatalogue(old: before.image, new: volume.image))

        rig.type(1, "CHAIN \"FROMMAC\"\n")
        #expect(rig.run(until: { rig.screen(1).contains("HELLO FROM THE MAC\n") }), "\(rig.screen(1))")
        rig.type(1, "*CAT\n")
        #expect(rig.run(until: { rig.screen(1).contains("MINE") && rig.screen(1).contains("FROMMAC") }), "\(rig.screen(1))")
    }

    /// A Master 128 (ANFS 4.25) and a Model B (DNFS) on one server.
    @Test func masterAndModelB() throws {
        let rig = EconetRig([(.modelB, 254), (.master128, 1), (.modelB, 2)])
        try rig.startLevel1FileServer(0, clients: [1, 2], directories: ["A", "A"])
        #expect(rig.machines[1].sidewaysSlots[8].header?.title.contains("ANFS") == true)
        rig.type(1, "*NET\n")
        rig.type(1, "10 PRINT \"FROM THE MASTER\"\n")
        rig.type(1, "SAVE \"MPROG\"\n")
        #expect(rig.run(until: { rig.lastLines(1, 1) == ">" }), "\(rig.screen(1))")
        rig.type(2, "*NET\n")
        rig.type(2, "CHAIN \"MPROG\"\n")
        #expect(rig.run(until: { rig.screen(2).contains("FROM THE MASTER\n") }), "\(rig.screen(2))")
    }

    /// The server switched off: the client's network software says so,
    /// as it would. Switched on and started again, it serves the same disc.
    @Test func serverOffAndBack() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 1)])
        try rig.startLevel1FileServer(0, clients: [1])
        rig.type(1, "*NET\n")
        rig.type(1, "10 PRINT \"KEPT\"\n")
        rig.type(1, "SAVE \"KEEP\"\n")
        rig.run(until: { rig.lastLines(1, 1) == ">" })

        rig.powerOff(0)
        rig.type(1, "*CAT\n")
        #expect(rig.run(until: { rig.lastLines(1, 1) == ">" && rig.lastLines(1, 2).contains("*CAT") == false }, seconds: 60))
        // DNFS's own error for a station that doesn't answer.
        #expect(rig.lastLines(1, 2) == "Not listening\n>", "\(rig.screen(1))")

        rig.powerOn(0)
        try rig.startLevel1FileServer(0, clients: [1], disc: rig.machines[0].drives[0].disc)
        rig.type(1, "CHAIN \"KEEP\"\n")
        #expect(rig.run(until: { rig.screen(1).contains("KEPT\n") }), "\(rig.screen(1))")
    }
}

/// The trace: frames put back together from the line, and read as the
/// four-way handshake.
struct EconetTraceTests {
    /// Port 0's scouts say which immediate operation they are.
    @Test func immediateOperationsAreNamed() {
        let poke = EconetFrame(id: 0, start: 0, end: 0, transmitter: 1, bytes: [2, 0, 1, 0, 0x82, 0, 0, 0x0A, 0, 0],
                               status: .valid, kind: .scout)
        #expect(poke.summary == "Scout · control &82 · port &00 (immediate POKE)")
        let jsr = EconetFrame(id: 0, start: 0, end: 0, transmitter: 1, bytes: [2, 0, 1, 0, 0x83, 0], status: .valid, kind: .scout)
        #expect(jsr.summary.hasSuffix("(immediate JSR)"))
        #expect(EconetFrame.immediateOperation(0x88) == "machine type")
    }

    @Test func oneTransmissionIsOneTransaction() {
        let rig = EconetRig([(.modelB, 1), (.modelB, 2)])
        let trace = EconetTrace()
        rig.bus.observer = { trace.observe($0) }
        rig.run(seconds: 1.5)
        rig.runProgram(1, econetReceiver)
        rig.run(until: { rig.screen(1).contains("OPEN") })
        trace.clear()
        rig.runProgram(0, econetSender(to: 2))
        #expect(rig.run(until: { rig.screen(0).contains("RESULT") }))
        let frames = trace.frames(after: nil)
        #expect(frames.map(\.kind) == [.scout, .acknowledgement, .data, .acknowledgement], "\(frames.map(\.summary))")
        #expect(Set(frames.compactMap(\.transaction)).count == 1)
        #expect(frames.allSatisfy { $0.status == .valid })
        #expect(frames[0].port == 0x77 && frames[0].control == 0x80)
        #expect(frames[0].transmitter == 1 && frames[1].transmitter == 2)
        #expect(Array(frames[2].payload) == Array("HELLO ECONET\r".utf8))
        #expect(frames[0].summary == "Scout · control &80 · port &77")
    }

    /// Nobody listening: a scout, and no acknowledgement.
    @Test func unansweredScout() {
        let rig = EconetRig([(.modelB, 1), (.modelB, 2)])
        let trace = EconetTrace()
        rig.bus.observer = { trace.observe($0) }
        rig.run(seconds: 1.5)
        rig.runProgram(0, econetSender(to: 3))
        rig.run(until: { rig.screen(0).contains("RESULT") })
        let frames = trace.frames(after: nil)
        #expect(!frames.isEmpty && frames.allSatisfy { $0.kind == .scout && $0.destinationStation == 3 })
    }
}

/// The Econet Demo network's programs, run as a visitor would.
struct EconetDemoTests {
    @Test func everyProgramWorks() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 235), (.modelB, 1), (.modelB, 2), (.modelB, 3)])
        try rig.startLevel1FileServer(0, clients: [1, 2, 3], directories: ["A", "A", "A"],
                                      disc: Disc.fromImage(DemoNetwork.fileServerDisc(), format: .ssd))
        let printed = try rig.startPrinterServer(1)

        // The Welcome machine boots its disc into the instructions.
        rig.machines[2].insertDisc(try Disc.fromImage(DemoNetwork.welcomeDisc(), format: .ssd), drive: 0)
        rig.machines[2].shiftBreak()
        #expect(rig.run(until: { rig.screen(2).contains("ECONET DEMONSTRATION") && rig.screen(2).contains(">") }), "\(rig.screen(2))")
        #expect(rig.screen(2).contains("sign the visitors' book"))

        for client in [3, 4] { rig.type(client, "*NET\n") }
        rig.type(3, "CHAIN \"HELLO\"\n")
        #expect(rig.run(until: { rig.screen(3).contains("Hello from the file server!") }), "\(rig.screen(3))")

        // The visitors' book: signed on one BBC, read on another.
        rig.type(3, "CHAIN \"GUESTS\"\n")
        #expect(rig.run(until: { rig.screen(3).contains("Your name:") }), "\(rig.screen(3))")
        rig.type(3, "ALICE\n")
        #expect(rig.run(until: { rig.screen(3).contains("Thank you!") }), "\(rig.screen(3))")
        rig.type(4, "CHAIN \"GUESTS\"\n")
        #expect(rig.run(until: { rig.screen(4).contains("Your name:") }), "\(rig.screen(4))")
        #expect(rig.screen(4).contains("ALICE") && rig.screen(4).contains("1 so far"), "\(rig.screen(4))")
        rig.type(4, "\n")

        // Chat: station 2 to station 3.
        rig.type(4, "CHAIN \"CHAT\"\n")
        #expect(rig.run(until: { rig.screen(4).contains("Chat to station") }), "\(rig.screen(4))")
        rig.type(4, "2\n")
        rig.type(3, "CHAIN \"CHAT\"\n")
        #expect(rig.run(until: { rig.screen(3).contains("Chat to station") }), "\(rig.screen(3))")
        rig.type(3, "3\n")
        rig.type(3, "HI THERE\n")
        #expect(rig.run(until: { rig.screen(4).contains("Station 2:") && rig.screen(4).contains("HI THERE") }), "\(rig.screen(4))")
        #expect(rig.screen(3).contains("(sent)"), "\(rig.screen(3))")

        // Printing, from the welcome machine.
        rig.type(2, "CHAIN \"PRINTME\"\n")
        #expect(rig.run(until: { printed.text.contains("PRINTED OVER ECONET") && rig.screen(2).contains("click the printer") }, seconds: 90),
                "\(printed.text.debugDescription) \(rig.screen(2))")
    }
}
