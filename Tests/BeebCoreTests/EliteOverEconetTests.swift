// Elite over Econet: Mark Moxon's Level 3 file server disc, on a Master
// with the SCSI hard disc, and players that set themselves up from their
// startup scripts and report to the scoreboard.

import Foundation
import Testing
@testable import BeebCore
@testable import BeebNetwork
import BeebROMs
import BeebCapture

struct EliteOverEconetTests {
    @Test func level3ServerStartsFromTheHardDisc() {
        let rig = EconetRig([])
        let server = Self.server()
        rig.add(server)
        rig.run(seconds: 2)
        server.type(EliteOverEconet.level3Startup)
        #expect(rig.run(until: { server.screenText().contains { $0.hasSuffix("Starting - Ready") } }, seconds: 60),
                "\(server.screenText().joined(separator: "\n"))")
        #expect(server.screenText().contains { $0.contains("File Server Level 3") })
    }

    @Test func todaysDateGoesInTheServersBoot() throws {
        var image = EliteOverEconet.disc.contents.image
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 5)))
        let changed = EliteOverEconet.dateBoot(&image, now: date)
        #expect(changed)
        let file = try #require(EliteOverEconet.rootFile("!BOOT", in: image))
        let boot = String(decoding: image[file.start..<file.start + file.length], as: UTF8.self)
        #expect(boot.hasPrefix("*KEY0 27/10/26|M09:05|M1|MS10|M\r"), "\(boot)")
    }

    /// Three kinds of player (Model B with sideways RAM, 6502 Second
    /// Processor, Master) on the scoreboard, under their own names.
    @Test func playersReportToTheScoreboard() {
        let rig = EconetRig([])
        let server = Self.server()
        rig.add(server)
        let scoreboard = BBCMicro(configuration: MachineSetup(model: .modelB).configuration(econetStation: 1))
        rig.add(scoreboard)
        let setups = [EliteOverEconet.playerSetup, MachineSetup(model: .modelB, secondProcessor: true), MachineSetup(model: .master128)]
        var runners = [(scoreboard, StartupScriptRunner(EliteOverEconet.scoreboardScript))]
        for (index, setup) in setups.enumerated() {
            let player = BBCMicro(configuration: setup.configuration(econetStation: 2 + index))
            rig.add(player)
            let script = EliteOverEconet.playerScript(commander: EliteOverEconet.commanderName(index), scoreboard: 1,
                                                      startDelay: Double(index) * EliteOverEconet.playerSpacing)
            runners.append((player, StartupScriptRunner(script)))
        }
        rig.run(seconds: 2)
        server.type(EliteOverEconet.level3Startup)
        let names = ["BLAKE", "VEGA", "RIGEL"]
        let done = rig.run(until: {
            let ready = server.screenText().contains { $0.hasSuffix("Starting - Ready") }
            for (machine, runner) in runners { runner.advance(machine, serverReady: ready) }
            let board = scoreboard.screenText()
            return names.allSatisfy { name in board.contains { $0.contains(name) } }
        }, seconds: 240)
        #expect(done, "\(scoreboard.screenText().joined(separator: "\n"))")
        if !done, let folder = ProcessInfo.processInfo.environment["ELITE_SHOTS"] {
            for (index, (machine, _)) in runners.enumerated() {
                let tv = TVOutput()
                machine.tv = tv
                machine.run(seconds: 0.1)
                try? Screenshot.writePNG(tv, to: URL(fileURLWithPath: folder).appendingPathComponent("machine-\(index).png"))
            }
        }
        let board = scoreboard.screenText()
        #expect(board.contains { $0.contains("B+") && $0.contains("0.002") && $0.contains("BLAKE") }, "\(board)")
        #expect(board.contains { $0.contains("SP") && $0.contains("0.003") && $0.contains("VEGA") }, "\(board)")
        #expect(board.contains { $0.contains("M ") && $0.contains("0.004") && $0.contains("RIGEL") }, "\(board)")
    }

    /// The template's package has the server's hard disc (its .dat and
    /// .dsc), which counts as used.
    @Test func templateKeepsTheHardDiscInThePackage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("elite-\(UUID().uuidString).macbeebnet")
        defer { try? FileManager.default.removeItem(at: url) }
        let project = try NetworkPackage.create(.eliteOverEconet, at: url)
        let server = try #require(project.nodes.first { $0.kind == .fileServer })
        #expect(server.level == .level3 && server.setup?.model == .master128 && server.setup?.secondProcessor == true)
        let media = try #require(server.hardDisc)
        let dat = try Data(contentsOf: NetworkPackage.url(of: media, in: url))
        let dsc = try Data(contentsOf: NetworkPackage.parametersURL(of: media, in: url))
        #expect(dat.count == 10_002_432 && dsc.count == 22)
        #expect(NetworkPackage.unusedMedia(of: project, in: url).isEmpty)
        let reloaded = try NetworkPackage.load(from: url)
        #expect(reloaded.nodes.filter { $0.startupScript != nil }.count == 4)
        #expect(Set(reloaded.nodes.compactMap { $0.startupScript.flatMap(EliteOverEconet.commander(in:)) }) == ["BLAKE", "VEGA", "RIGEL"])
    }

    /// A copy of a player is another commander, reporting to the same
    /// scoreboard.
    @Test func copiedPlayerKeepsItsScoreboard() {
        let script = EliteOverEconet.playerScript(commander: "BLAKE", scoreboard: 7, startDelay: 9)
        let copy = EliteOverEconet.playerScript(like: script, commander: "VEGA")
        #expect(EliteOverEconet.commander(in: copy) == "VEGA")
        #expect(copy == EliteOverEconet.playerScript(commander: "VEGA", scoreboard: 7))
        #expect(EliteOverEconet.playerScript(like: EliteOverEconet.playerScript(commander: "A", scoreboard: nil), commander: "B")
            == EliteOverEconet.playerScript(commander: "B", scoreboard: nil))
    }

    /// A Master with a 6502 Second Processor and the Elite disc on SCSI,
    /// as the Level 3 server.
    static func server() -> BBCMicro {
        let server = BBCMicro(configuration: FileServerLevel.level3.setup.configuration(econetStation: EliteOverEconet.serverStation))
        let disc = EliteOverEconet.disc.contents
        server.attachHardDisc(HardDisc(image: disc.image, parameters: disc.parameters))
        return server
    }
}
