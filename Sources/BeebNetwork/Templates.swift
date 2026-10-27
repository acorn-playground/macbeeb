import BeebCore
import Foundation

/// Ready-made networks to start from.
public enum NetworkTemplate: String, CaseIterable, Sendable, Identifiable {
    case econetDemo, econetTimes, eliteOverEconet, distributedMandelbrot, mandelbrotInColour, twoBBCs, schoolClassroom, bbcAndMaster, empty

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .econetDemo: "Econet Demo"
        case .econetTimes: "The Econet Times"
        case .eliteOverEconet: "Elite over Econet"
        case .distributedMandelbrot: "Distributed Mandelbrot"
        case .mandelbrotInColour: "Mandelbrot in Colour"
        case .twoBBCs: "Two BBCs"
        case .schoolClassroom: "School Classroom"
        case .bbcAndMaster: "BBC and Master"
        case .empty: "Empty Network"
        }
    }

    public var summary: String {
        switch self {
        case .econetDemo: "A classroom ready to try: a welcome screen, and programs on the file server to chat, sign a shared visitors' book and print."
        case .econetTimes: "A newsroom: reporters on three BBCs file stories with the file server, and the editor prints the paper on the printer server, in two columns under a masthead."
        case .eliteOverEconet: "Mark Moxon's multiplayer Elite: three commanders on a BBC, a 6502 Second Processor and a Master, reporting to a scoreboard, from a Level 3 file server."
        case .distributedMandelbrot: "Eight BBCs draw the Mandelbrot set between them over Econet, each tile worked out by its own 6502: *CLUSTER, then *MANDEL."
        case .mandelbrotInColour: "The Distributed Mandelbrot in MODE 2: the Guide's VideoNuLA gives it sixteen colours of 4,096, and cycles them when it's done. *CLUSTER, then *MANDEL2."
        case .twoBBCs: "The smallest network: two Model Bs, stations 1 and 2, and a clock."
        case .schoolClassroom: "Four Model Bs, a file server on station 254 and a printer server on 235, as a 1980s school had."
        case .bbcAndMaster: "A Model B and a Master 128 side by side, sharing a file server."
        case .empty: "Just the clock. Add machines from the palette."
        }
    }

    public var symbolName: String {
        switch self {
        case .econetDemo: "sparkles"
        case .econetTimes: "newspaper"
        case .eliteOverEconet: "airplane"
        case .distributedMandelbrot: "square.grid.3x3.fill"
        case .mandelbrotInColour: "paintpalette"
        case .twoBBCs: "rectangle.on.rectangle"
        case .schoolClassroom: "building.columns"
        case .bbcAndMaster: "rectangle.split.2x1"
        case .empty: "square.dashed"
        }
    }

    /// Canvas spacing between machines.
    static let spacing = 260.0

    public func makeProject() -> NetworkProject {
        let modelB = MachineSetup(model: .modelB)
        func station(_ name: String, _ number: Int, _ x: Double, _ y: Double, setup: MachineSetup = modelB) -> NetworkNode {
            NetworkNode(kind: .station, name: name, stationNumber: number, setup: setup, position: CanvasPoint(x: x, y: y))
        }
        func server(_ kind: NetworkNode.Kind, _ x: Double, _ y: Double) -> NetworkNode {
            NetworkNode(kind: kind, name: kind.displayName, stationNumber: kind.conventionalStation, setup: modelB,
                        position: CanvasPoint(x: x, y: y))
        }
        // Level 2: a Model B with a 6502 Second Processor. (Its station
        // count comes from the network, when it starts.)
        func level2Server(_ x: Double, _ y: Double) -> NetworkNode {
            var node = NetworkNode(kind: .fileServer, name: "Level 2 File Server", stationNumber: 254,
                                   setup: FileServerLevel.level2.setup, position: CanvasPoint(x: x, y: y))
            node.fileServerLevel = .level2
            return node
        }
        let s = Self.spacing
        var project = NetworkProject(name: title)
        switch self {
        case .econetDemo:
            var welcome = station("Welcome", 1, -1.5 * s, 0)
            welcome.bootsDisc = true
            project.nodes = [welcome, station("BBC 2", 2, -0.5 * s, 0), station("BBC 3", 3, 0.5 * s, 0),
                             station("Master 4", 4, 1.5 * s, 0, setup: MachineSetup(model: .master128)),
                             server(.fileServer, -s / 2, 330), server(.printServer, s / 2, 330), .clock(at: CanvasPoint(x: 1.5 * s + 40, y: 330))]
        case .econetTimes:
            // The editor and three reporters, each booting their own desk.
            var editor = station("Editor", 1, -1.5 * s, 0)
            editor.bootsDisc = true
            var reporters = [station("Reporter 2", 2, -0.5 * s, 0), station("Reporter 3", 3, 0.5 * s, 0),
                             station("Reporter 4", 4, 1.5 * s, 0, setup: MachineSetup(model: .master128))]
            for index in reporters.indices { reporters[index].bootsDisc = true }
            project.nodes = [editor] + reporters
                + [server(.fileServer, -s / 2, 330), server(.printServer, s / 2, 330), .clock(at: CanvasPoint(x: 1.5 * s + 40, y: 330))]
        case .eliteOverEconet:
            // The scoreboard and three commanders, each a different kind of
            // BBC, starting a little apart (see EliteOverEconet).
            var scoreboard = station(EliteOverEconet.scoreboardName, 1, -1.5 * s, 0)
            scoreboard.startupScript = EliteOverEconet.scoreboardScript
            let setups = [EliteOverEconet.playerSetup, MachineSetup(model: .modelB, secondProcessor: true), MachineSetup(model: .master128)]
            let players = setups.enumerated().map { index, setup in
                let commander = EliteOverEconet.commanderName(index)
                var node = station("Cmdr \(commander.capitalized)", 2 + index, (Double(index) - 0.5) * s, 0, setup: setup)
                node.startupScript = EliteOverEconet.playerScript(commander: commander, scoreboard: 1,
                                                                  startDelay: Double(index) * EliteOverEconet.playerSpacing)
                return node
            }
            var server = NetworkNode(kind: .fileServer, name: "Level 3 File Server", stationNumber: EliteOverEconet.serverStation,
                                     setup: FileServerLevel.level3.setup, position: CanvasPoint(x: -s / 2, y: 330))
            server.fileServerLevel = .level3
            project.nodes = [scoreboard] + players + [server, .clock(at: CanvasPoint(x: s / 2 + 40, y: 330))]
        case .distributedMandelbrot, .mandelbrotInColour:
            // The Guide (with VideoNuLA for the colour one), then the
            // workers, along the trunk.
            var guide = station("Guide", 1, -4 * s, 0,
                                setup: MachineSetup(model: .modelB, videoNuLA: self == .mandelbrotInColour))
            guide.bootsDisc = true
            // The workers only switch on, to BASIC: *CLUSTER takes them
            // over by remote control.
            project.nodes = [guide] + MandelbrotNetwork.workers.map { number in
                station("Worker \(number)", number, Double(number - 5) * s, 0)
            } + [level2Server(-s / 2, 330), .clock(at: CanvasPoint(x: s / 2 + 40, y: 330))]
        case .twoBBCs:
            project.nodes = [station("BBC 1", 1, -s / 2, 0), station("BBC 2", 2, s / 2, 0), .clock(at: CanvasPoint(x: 0, y: 200))]
        case .schoolClassroom:
            project.nodes = (0..<4).map { station("BBC \($0 + 1)", $0 + 1, (Double($0) - 1.5) * s, 0) }
                + [server(.fileServer, -s / 2, 330), server(.printServer, s / 2, 330), .clock(at: CanvasPoint(x: 1.5 * s + 40, y: 330))]
        case .bbcAndMaster:
            project.nodes = [station("BBC", 1, -s / 2, 0), station("Master", 2, s / 2, 0, setup: MachineSetup(model: .master128)),
                             server(.fileServer, 0, 330), .clock(at: CanvasPoint(x: s, y: 330))]
        case .empty:
            project.nodes = [.clock(at: CanvasPoint())]
        }
        project.workspace.tiles = project.stations.filter { $0.kind == .station }.map(\.id)
        return project
    }

    /// The hard discs a template's machines start with: (node, name, the
    /// .dat and the .dsc).
    public func hardDiscs(for project: NetworkProject) -> [(node: UUID, name: String, contents: (image: [UInt8], parameters: [UInt8]))] {
        guard self == .eliteOverEconet, let server = project.nodes.first(where: { $0.kind == .fileServer }) else { return [] }
        return [(server.id, "Elite over Econet", EliteOverEconet.disc.contents)]
    }

    /// The discs a template's machines start with, for `NetworkPackage`
    /// to put in the package: (node, drive, file name, image).
    public func discs(for project: NetworkProject) throws -> [(node: UUID, drive: Int, name: String, image: [UInt8])] {
        let booted: (name: String, image: [UInt8]), server: (name: String, image: [UInt8])
        switch self {
        case .econetDemo:
            (booted, server) = (("Welcome.ssd", try DemoNetwork.welcomeDisc()), ("File Server.ssd", try DemoNetwork.fileServerDisc()))
        case .econetTimes:
            // The editor's desk, and a reporter's on each of the others.
            let (editor, reporter) = (try EconetTimes.editorDisc(), try EconetTimes.reporterDisc())
            var discs: [(UUID, Int, String, [UInt8])] = project.nodes.filter { $0.bootsDisc == true }.map { node in
                node.stationNumber == 1 ? (node.id, 0, "Editor.ssd", editor) : (node.id, 0, "Reporter.ssd", reporter)
            }
            if let node = project.nodes.first(where: { $0.kind == .fileServer }) {
                discs.append((node.id, 0, "File Server.ssd", try EconetTimes.fileServerDisc()))
            }
            return discs
        case .distributedMandelbrot, .mandelbrotInColour:
            let coordinator: MandelbrotNetwork.Coordinator = self == .distributedMandelbrot ? .mode5 : .mode2
            (booted, server) = (("Guide.ssd", try MandelbrotNetwork.guideDisc(for: coordinator)),
                                ("Level 2 File Server.dsd", try MandelbrotNetwork.fileServerDisc(for: coordinator).image))
        default:
            return []
        }
        var discs: [(UUID, Int, String, [UInt8])] = []
        if let node = project.nodes.first(where: { $0.bootsDisc == true }) {
            discs.append((node.id, 0, booted.name, booted.image))
        }
        if let node = project.nodes.first(where: { $0.kind == .fileServer }) {
            discs.append((node.id, 0, server.name, server.image))
        }
        return discs
    }
}
