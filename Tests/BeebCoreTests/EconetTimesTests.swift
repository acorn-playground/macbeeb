// The Econet Times network's programs, run as visitors would: reporters
// file stories with the file server, and the editor prints the paper on
// the printer server.

import Foundation
import Testing
@testable import BeebCore
import BeebNetwork
import BeebROMs

struct EconetTimesTests {
    @Test func reportersFileAndTheEditorPrints() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 235), (.modelB, 1), (.modelB, 2), (.master128, 3)])
        try rig.startLevel1FileServer(0, clients: [1, 2, 3], directories: ["A", "A", "A"],
                                      disc: Disc.fromImage(EconetTimes.fileServerDisc(), format: .ssd))
        let printed = try rig.startPrinterServer(1)
        rig.machines[2].insertDisc(try Disc.fromImage(EconetTimes.editorDisc(), format: .ssd), drive: 0)
        for reporter in [3, 4] {
            rig.machines[reporter].insertDisc(try Disc.fromImage(EconetTimes.reporterDisc(), format: .ssd), drive: 0)
        }
        rig.run(seconds: 0.5)
        for machine in [2, 3, 4] { rig.machines[machine].shiftBreak() }

        // The editor's board: nothing filed yet.
        #expect(rig.run(until: { rig.screen(2).contains("Nothing to print yet") }, seconds: 60), "\(rig.screen(2))")
        #expect(rig.screen(2).contains("waiting for a story"))

        // Station 2 files the News desk's own story.
        #expect(rig.run(until: { rig.screen(3).contains("Which desk") }, seconds: 30), "\(rig.screen(3))")
        #expect(rig.screen(3).contains("station 2"), "\(rig.screen(3))")
        rig.type(3, "1")
        #expect(rig.run(until: { rig.screen(3).contains("Ten BBCs Join Hands") }), "\(rig.screen(3))")
        rig.type(3, "\nALICE\n\n")
        #expect(rig.run(until: { rig.screen(3).contains("Filed!") }, seconds: 30), "\(rig.screen(3))")

        // Station 3, a Master, writes its own for Sport, and prints a proof.
        #expect(rig.run(until: { rig.screen(4).contains("Which desk") }, seconds: 30), "\(rig.screen(4))")
        rig.type(4, "2")
        #expect(rig.run(until: { rig.screen(4).contains("Headline") }), "\(rig.screen(4))")
        rig.type(4, "GOAL FOR STATION 3\nBOB\nIt was a close match, decided in the last minute by a header.\n\n")
        #expect(rig.run(until: { rig.screen(4).contains("Filed!") }, seconds: 30), "\(rig.screen(4))")
        rig.type(4, "P")
        #expect(rig.run(until: { rig.screen(4).contains("Printed:") }, seconds: 60), "\(rig.screen(4))")
        // (The Master's CAPS LOCK is on.)
        #expect(rig.run(until: { printed.text.uppercased().contains("DECIDED IN THE LAST") }, seconds: 30), "\(printed.text.debugDescription)")
        #expect(printed.text.contains("PROOF: The Sport desk"), "\(printed.text.debugDescription)")
        #expect(!printed.text.contains("\n"), "\(printed.text.debugDescription)")
        let proof = printed.bytes.count

        // The editor's board shows them both; P prints the paper.
        #expect(rig.run(until: { rig.screen(2).contains("Ten BBCs Join Hands") && rig.screen(2).contains("GOAL FOR STATION 3") }, seconds: 30),
                "\(rig.screen(2))")
        rig.type(2, "P")
        #expect(rig.run(until: { rig.screen(2).contains("Printed:") }, seconds: 120), "\(rig.screen(2))")
        rig.run(seconds: 1)
        let paper = String(decoding: printed.bytes[proof...], as: UTF8.self)
        print(paper.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{1B}", with: "^"))
        #expect(paper.contains("T  I  M  E  S"))
        #expect(paper.contains("PRINTED OVER ECONET"))
        #expect(paper.contains("NEWS ---") && paper.contains(" | \u{1B}ESPORT ---"), "\(paper.debugDescription)")
        #expect(paper.contains("\u{1B}E\u{1B}-\u{01}Ten BBCs Join Hands"), "\(paper.debugDescription)")
        #expect(paper.contains("By ALICE, station 2") && paper.contains("By BOB, station 3"), "\(paper.debugDescription)")
        #expect(paper.contains("every byte of it over Econet"))
        #expect(rig.screen(2).contains("Ten BBCs Join Hands"), "The board's still there: \(rig.screen(2))")
        // One job: the printer never waits long enough for the Print Centre
        // to call it two.
        let quiet = printed.longestGap(after: proof)
        #expect(quiet < 2.0, "The printer waited \(quiet)s mid-paper")

        // N: the next edition, with the desks cleared.
        rig.type(2, "N")
        #expect(rig.run(until: { rig.screen(2).contains("edition 2") && rig.screen(2).contains("Nothing to print yet") }, seconds: 60),
                "\(rig.screen(2))")
    }
}
