import BeebCore
import BeebROMs
import Foundation

/// Mark Moxon's Elite over Econet (elite.bbcelite.com/hacks/elite_over_econet):
/// Elite, with each player's ship reporting to a scoreboard over the
/// network. The game and the scoreboard are on a Level 3 file server's
/// hard disc (his, for BeebEm), in the ELITE user's directory.
///
/// The players and the scoreboard set themselves up as his instructions
/// say, by startup scripts: log on as ELITE, run *ELITE (or *ELITE S for
/// the scoreboard, on port 100), save the commander under its own name, and
/// point it at the scoreboard from the Network Menu (COPY, then N).
public enum EliteOverEconet {
    /// The file server's station, and the user the game's installed for.
    public static let serverStation = 254
    public static let user = "ELITE"
    /// The scoreboard's Econet port.
    public static let scoreboardPort = 100
    /// The scoreboard machine's name: Mark Moxon's Elite multiplayer
    /// scoreboard.
    public static let scoreboardName = "Elite multiplayer scoreboard"

    /// Whether a machine's name, or a room station's label, is the
    /// scoreboard's: "scoreboard" anywhere in it (networks saved before it
    /// had its full name call it "Scoreboard"; so do older hosts).
    public static func isScoreboard(_ name: String) -> Bool {
        name.range(of: "scoreboard", options: .caseInsensitive) != nil
    }

    /// The hard disc the template's server has.
    public static let disc = BeebROMs.BundledHardDisc.eliteOverEconetFlickerFree

    /// How far apart the template's players start.
    public static let playerSpacing = 9.0

    /// The machine a player needs most: a Model B with 16K of sideways RAM
    /// (which runs the full game; without it, a cut-down one).
    public static let playerSetup = MachineSetup(model: .modelB, expansions: .init(sidewaysRAM: .ram16))

    /// Commanders' names for new players, by turn (each needs its own, or
    /// they'd overwrite each other's saved commanders, which share the
    /// ELITE user's directory).
    public static let commanderNames = ["BLAKE", "VEGA", "RIGEL", "ORION", "ALTAIR", "DENEB", "SIRIUS", "LYRA", "CASTOR",
                                        "POLLUX", "SPICA", "ANTARES"]

    /// A name for player `index` that isn't one of `taken`.
    public static func commanderName(_ index: Int, avoiding taken: Set<String> = []) -> String {
        let free = commanderNames.filter { !taken.contains($0) }
        if index < free.count { return free[index] }
        return "CMDR\(index + 1)"
    }

    /// Time for a machine to start up before anything's typed (a server
    /// in an Internet room may be ready before it is).
    static let bootSeconds = 3.0

    static var logOn: String { "*NET\n*I AM 0.\(serverStation) \(user)\n" }

    /// The scoreboard: *ELITE S, and its port.
    public static var scoreboardScript: [StartupStep] {
        [.wait(bootSeconds), .waitForServer, .type(logOn + "*ELITE S\n"), .waitForText(["Please enter the port number"], timeout: 60), .type("\(scoreboardPort)\n")]
    }

    /// A player: loads Elite (on a Model B, Break and a key free memory
    /// for it), saves its commander as `commander` from the title screen,
    /// and, if there's a scoreboard (station `scoreboard`), reports to it.
    /// `startDelay`: seconds to wait for the server first. The scoreboard
    /// takes a moment to listen again after each report, and a docked ship
    /// doesn't try again, so players that report together (having started
    /// together) would be missed.
    public static func playerScript(commander: String, scoreboard: Int?, startDelay: Double = 0) -> [StartupStep] {
        var steps: [StartupStep] = [
            .wait(bootSeconds),
            .waitForServer,
            .wait(startDelay),
            .type(logOn + "*ELITE\n"),
            // The Model B's loader asks for Break (to switch off the DFS),
            // then a key; the others go straight into the game.
            .waitForText(["Press BREAK", "Press any key"], timeout: 30),
            // (Not at once: it's still setting up what Break does.)
            .ifShowing("Press BREAK", [.wait(2), .pressBreak, .waitForText(["Press any key"], timeout: 30)]),
            // (Once it's waiting: it empties the keyboard buffer first.)
            .ifShowing("Press any key", [.wait(2), .press("SPACE")]),
            // The title's up once it's loaded the game: the network goes
            // quiet. (Elite can't be read off the screen.)
            .waitForQuiet(4, timeout: 120), .wait(2),
            // "Load New Commander (Y/N)?" Y: the disk access menu. 2 saves:
            // its name prompt may already have the 2 in it.
            .press("Y"), .wait(1), .press("2"), .wait(1), .press("DELETE"), .press("DELETE"),
            .wait(1)] + keys(String(commander.prefix(7))) + [.wait(3),
            // "Press Space Or Fire, Commander."
            .press("SPACE"), .wait(3),
        ]
        if let scoreboard {
            // Pause, then the Network Menu: network, station, port, and
            // reset the scores; then a key once it says OK.
            // Each prompt empties the keyboard buffer: nothing's typed ahead.
            steps += [.press("COPY"), .press("N"), .wait(2)] + keys("0") + [.wait(2)] + keys("\(scoreboard)") + [.wait(2)]
                + keys("\(scoreboardPort)") + [.wait(2), .press("Y"), .wait(3), .press("SPACE"), .wait(2)]
        }
        return steps + [.press("f8")]
    }

    /// A player for a network joining an Internet room that has the game's
    /// server: station `number`, playing as a commander none of the room's
    /// machines is named for, reporting to the room's scoreboard (if it has
    /// one). `stations`: the room's, by number and label.
    public static func remotePlayer(number: Int, joining stations: [(station: Int, label: String)]) -> NetworkNode {
        let names = Set(stations.map { $0.label.replacingOccurrences(of: "Cmdr ", with: "").uppercased() })
        let commander = commanderName(0, avoiding: names)
        let scoreboard = stations.first { isScoreboard($0.label) }?.station
        var node = NetworkNode(kind: .station, name: "Cmdr \(commander.capitalized)", stationNumber: number, setup: playerSetup,
                               position: CanvasPoint())
        node.startupScript = playerScript(commander: commander, scoreboard: scoreboard)
        return node
    }

    /// The commander a player's script saves, if it's a player's: the keys
    /// between the name prompt and its Return.
    public static func commander(in script: [StartupStep]) -> String? {
        guard let start = script.firstIndex(of: .press("DELETE")).map({ $0 + 3 }), start < script.count else { return nil }
        return pressed(in: script[start...])
    }

    /// The keys pressed from the start of `steps` up to a Return.
    static func pressed(in steps: ArraySlice<StartupStep>) -> String? {
        var text = ""
        for step in steps {
            guard case .press(let key) = step else { return nil }
            if key == "RETURN" { return text.isEmpty ? nil : text }
            text += key
        }
        return nil
    }

    /// A player's script for another commander, reporting where `script`
    /// does (for a copy of a player).
    public static func playerScript(like script: [StartupStep], commander: String) -> [StartupStep] {
        var scoreboard: Int?
        // COPY, N, wait, network keys, wait, then the station's keys.
        if let menu = script.firstIndex(of: .press("COPY")), let network = script[(menu + 3)...].firstIndex(of: .press("RETURN")),
           network + 2 < script.count {
            scoreboard = pressed(in: script[(network + 2)...]).flatMap { Int($0) }
        }
        return playerScript(commander: commander, scoreboard: scoreboard)
    }

    /// Typing into Elite, which reads the keyboard itself and can miss a
    /// quick press while it's busy: each key held, then Return.
    static func keys(_ text: String) -> [StartupStep] {
        text.map { .press(String($0)) } + [.press("RETURN")]
    }

    /// What a Level 3 server types once it's reset: ADFS on the hard disc
    /// (drive 0), and its !BOOT, which starts the server and answers its
    /// questions (the date, the time, one drive, Start).
    public static let level3Startup = "*FADFS\n*MOUNT 0\n*EXEC !BOOT\n"

    /// Puts today's date and the time in a Level 3 server disc's !BOOT
    /// (whose *KEY0 answers the server's questions), so its files are
    /// dated now. Returns whether it changed anything.
    @discardableResult
    public static func dateBoot(_ image: inout [UInt8], now: Date = Date()) -> Bool {
        guard let (start, length) = rootFile("!BOOT", in: image), start + length <= image.count else { return false }
        let boot = Array(image[start..<start + length])
        // "*KEY0 dd/mm/yy|Mhh:mm"
        let prefix = Array("*KEY0 ".utf8)
        guard boot.count >= prefix.count + 16, boot.starts(with: prefix) else { return false }
        let at = prefix.count
        let pattern = Array("00/00/00|M00:00".utf8)
        for (index, byte) in pattern.enumerated() {
            let actual = boot[at + index]
            if byte == UInt8(ascii: "0") ? !(48...57).contains(actual) : actual != byte { return false }
        }
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents([.day, .month, .year, .hour, .minute], from: now)
        let text = String(format: "%02d/%02d/%02d|M%02d:%02d", c.day ?? 1, c.month ?? 1, (c.year ?? 1984) % 100, c.hour ?? 12, c.minute ?? 0)
        image.replaceSubrange(start + at..<start + at + pattern.count, with: Array(text.utf8))
        return true
    }

    /// Where a file in an ADFS hard disc's root directory ($, sector 2) is:
    /// its byte offset and length.
    static func rootFile(_ name: String, in image: [UInt8]) -> (start: Int, length: Int)? {
        let root = 0x200
        guard image.count >= root + 0x500, image[root + 1..<root + 5].elementsEqual("Hugo".utf8) else { return nil }
        for index in 0..<47 {
            let entry = root + 5 + index * 26
            guard image[entry] != 0 else { break }
            let entryName = String(decoding: image[entry..<entry + 10].map { $0 & 0x7F }.prefix { $0 > 32 }, as: UTF8.self)
            guard entryName == name else { continue }
            func number(_ at: Int, _ count: Int) -> Int {
                (0..<count).reduce(0) { $0 | Int(image[entry + at + $1]) << (8 * $1) }
            }
            return (number(22, 3) * 256, number(18, 4))
        }
        return nil
    }
}
