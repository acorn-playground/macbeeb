import BeebCore
import Foundation

/// A network of BBC Micros as saved: its machines and what they're for,
/// their hardware, discs and places on the canvas. Configuration only; the
/// machines' running state isn't saved.
public struct NetworkProject: Codable, Sendable, Equatable {
    /// The manifest's format. Older manifests are migrated on load (see
    /// `NetworkPackage`); newer ones are refused rather than half-read.
    public static let currentSchemaVersion = 1

    public var schemaVersion = Self.currentSchemaVersion
    public var id = UUID()
    public var name: String
    /// The Econet's network number: 0, the local network.
    public var networkNumber = 0
    public var nodes: [NetworkNode] = []
    public var canvas = CanvasLayout()
    public var workspace = Workspace()
    /// The Internet Econet room it's in, if it's shared or joined one
    /// (nothing secret: the room's credentials are in the Keychain).
    public var internetRoom: InternetRoomLink?
    /// New and not yet kept: closing it asks whether to save it (with a
    /// name and a place) or delete it, as a new document does.
    public var draft: Bool?

    public var isDraft: Bool { draft == true }

    public init(name: String, nodes: [NetworkNode] = []) {
        self.name = name
        self.nodes = nodes
    }

    public subscript(id: UUID) -> NetworkNode? {
        get { nodes.first { $0.id == id } }
        set {
            guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
            if let newValue {
                nodes[index] = newValue
            } else {
                nodes.remove(at: index)
            }
        }
    }

    /// The machines (everything but the clock), in station number order.
    public var stations: [NetworkNode] {
        nodes.filter(\.isMachine).sorted { ($0.stationNumber ?? 0, $0.name) < ($1.stationNumber ?? 0, $1.name) }
    }

    public var hasClock: Bool {
        nodes.contains { $0.kind == .clock }
    }

    /// The lowest station number that's free, from `start`.
    public func freeStationNumber(from start: Int = 1) -> Int? {
        let used = Set(nodes.compactMap(\.stationNumber))
        return (start...254).first { !used.contains($0) } ?? (1...254).first { !used.contains($0) }
    }

    /// A name like "BBC 3" that isn't taken.
    public func freeName(_ base: String) -> String {
        let names = Set(nodes.map(\.name))
        if !names.contains(base) { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0) }!
    }

    // MARK: Placing

    /// A machine card's size on the canvas, and the space between them.
    public static let cardSize = CanvasPoint(x: 236, y: 230)
    public static let columnSpacing = 260.0
    public static let rowSpacing = 330.0

    /// Where a new node of `kind` goes: at the end of its row, so the
    /// trunk grows to reach it. Stations go along the top row, servers and
    /// the clock along the row below.
    public func nextPosition(for kind: NetworkNode.Kind) -> CanvasPoint {
        let stationRow = commonY(nodes.filter { $0.kind == .station })
        let serverRow = commonY(nodes.filter { $0.kind != .station })
        let y: Double
        switch kind {
        case .station:
            y = stationRow ?? serverRow.map { $0 - Self.rowSpacing } ?? 0
        case .fileServer, .printServer, .clock:
            y = serverRow ?? stationRow.map { $0 + Self.rowSpacing } ?? Self.rowSpacing
        }
        let row = nodes.filter { abs($0.position.y - y) < Self.cardSize.y / 2 }
        let x = row.map(\.position.x).max().map { $0 + Self.columnSpacing } ?? nodes.map(\.position.x).min() ?? 0
        return freePosition(near: CanvasPoint(x: x, y: y))
    }

    /// `point`, or the nearest place to the right of it along its row
    /// that no card covers.
    public func freePosition(near point: CanvasPoint, excluding id: UUID? = nil) -> CanvasPoint {
        var candidate = point
        for _ in 0..<500 {
            let covered = nodes.contains { node in
                node.id != id && abs(node.position.x - candidate.x) < Self.cardSize.x
                    && abs(node.position.y - candidate.y) < Self.cardSize.y
            }
            if !covered { return candidate }
            candidate.x += Self.columnSpacing
        }
        return candidate
    }

    /// The y most of these nodes share (their row), if there are any.
    private func commonY(_ nodes: [NetworkNode]) -> Double? {
        let counts = Dictionary(grouping: nodes, by: { ($0.position.y / 10).rounded() * 10 }).mapValues(\.count)
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
    }

    // MARK: Problems

    /// What's wrong with the network as set up, for the canvas to show.
    public var problems: [NetworkProblem] {
        var problems: [NetworkProblem] = []
        let machines = nodes.filter(\.isMachine)
        for (number, group) in Dictionary(grouping: machines.filter { $0.stationNumber != nil }, by: { $0.stationNumber! })
        where group.count > 1 {
            problems.append(.duplicateStation(number, group.map(\.id)))
        }
        for node in machines {
            if let number = node.stationNumber, !NetworkNode.validStationNumbers.contains(number) {
                problems.append(.reservedStation(number, node.id))
            }
        }
        if machines.count > 1 && !hasClock {
            problems.append(.noClock)
        }
        if nodes.filter({ $0.kind == .clock }).count > 1 {
            problems.append(.twoClocks)
        }
        return problems
    }

    /// Why `number` can't be station `node`'s, if it can't.
    public func stationNumberProblem(_ number: Int, for node: UUID) -> String? {
        guard NetworkNode.validStationNumbers.contains(number) else {
            return "Station numbers go from 1 to 254: 0 and 255 are for broadcasts"
        }
        if let other = nodes.first(where: { $0.id != node && $0.stationNumber == number }) {
            return "\(other.name) is station \(number)"
        }
        return nil
    }
}

/// Something about the network a real one wouldn't work with.
public enum NetworkProblem: Sendable, Equatable, Hashable {
    case duplicateStation(Int, [UUID])
    case reservedStation(Int, UUID)
    case noClock
    case twoClocks

    public var message: String {
        switch self {
        case .duplicateStation(let number, let ids): "\(ids.count) machines are station \(number): each needs its own number"
        case .reservedStation(let number, _): "Station \(number) is reserved: use 1 to 254"
        case .noClock: "No clock: an Econet needs one to carry anything"
        case .twoClocks: "Two clocks: a network has one"
        }
    }

    /// The nodes it's about.
    public var nodes: [UUID] {
        switch self {
        case .duplicateStation(_, let ids): ids
        case .reservedStation(_, let id): [id]
        case .noClock, .twoClocks: []
        }
    }
}

/// One thing on the network: a BBC Micro (an ordinary station, or one that
/// serves files or a printer), or the network's clock.
public struct NetworkNode: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case station, fileServer, printServer, clock

        public var displayName: String {
            switch self {
            case .station: "BBC Micro"
            case .fileServer: "File Server"
            case .printServer: "Printer Server"
            case .clock: "Network Clock"
            }
        }

        /// The usual station number for a server.
        public var conventionalStation: Int? {
            switch self {
            case .fileServer: 254
            case .printServer: 235
            case .station, .clock: nil
            }
        }
    }

    public static let validStationNumbers = 1...254

    /// Stable whatever the station number becomes.
    public var id = UUID()
    public var kind: Kind
    public var name: String
    /// Nil for the clock.
    public var stationNumber: Int?
    /// Nil for the clock.
    public var setup: MachineSetup?
    /// The discs in its drives, by drive.
    public var discs: [Int: MediaReference] = [:]
    /// Its place on the canvas, in canvas points.
    public var position = CanvasPoint()
    /// Whether it's switched on when the network opens.
    public var poweredOn = true
    /// The clock's rate, in bits per second (the clock only).
    public var clockRate: Int?
    /// A server: whether its server software starts when it's switched on
    /// (nil, the default, is yes).
    public var startsServer: Bool?

    public var startsServerWhenOn: Bool { kind != .station && kind != .clock && startsServer != false }
    /// Boots the disc in its drive 0 when it's switched on (Shift-Break).
    public var bootsDisc: Bool?
    /// Boots from the network when it's switched on, once the file server's
    /// ready: logs on as BOOT, and Level 2 runs its !BOOT. (Level 1 has no
    /// boot options, so the Studio types what its !BOOT says.)
    public var bootsNetwork: Bool?
    /// A file server: which of Acorn's servers it runs (nil, the default
    /// and what networks saved before had, is Level 1).
    public var fileServerLevel: FileServerLevel?
    /// The hard disc on its SCSI interface (a Level 3 file server's), kept
    /// in the package as BeebEm keeps one: the .dat, with its .dsc beside it.
    public var hardDisc: MediaReference?
    /// What's typed into it when it's switched on (once the file server's
    /// ready, if it waits for it): Elite over Econet's players and
    /// scoreboard set themselves up with one.
    public var startupScript: [StartupStep]?

    public var level: FileServerLevel { fileServerLevel ?? .level1 }

    public var isMachine: Bool { kind != .clock }

    public init(kind: Kind, name: String, stationNumber: Int?, setup: MachineSetup?, position: CanvasPoint = CanvasPoint()) {
        self.kind = kind
        self.name = name
        self.stationNumber = stationNumber
        self.setup = setup
        self.position = position
        if kind == .clock {
            clockRate = Self.defaultClockRate
        }
    }

    public static func clock(at position: CanvasPoint) -> NetworkNode {
        NetworkNode(kind: .clock, name: "Clock", stationNumber: nil, setup: nil, position: position)
    }

    /// A typical school network's clock: 200 kbit/s.
    public static let defaultClockRate = 200_000
}

/// Acorn's file servers. Level 1 runs on a plain Model B from a DFS disc;
/// Level 2 needs a 6502 Second Processor and its own disc format, and has
/// users, passwords, directories and boot options. Level 3 runs from an
/// ADFS hard disc, on a Master 128 with a 6502 Second Processor here (as
/// BeebEm runs it); MacBeeb has no blank one, so it comes with a network
/// whose disc has it (Elite over Econet's).
public enum FileServerLevel: Int, Codable, Sendable, CaseIterable {
    case level1 = 1
    case level2 = 2
    case level3 = 3

    public var displayName: String {
        switch self {
        case .level1: "Level 1"
        case .level2: "Level 2"
        case .level3: "Level 3"
        }
    }

    /// Its station numbers, in order of preference: 254 is the one the
    /// network filing systems log on to by default, 253 the next server's.
    public var conventionalStations: [Int] {
        switch self {
        case .level1, .level3: [254]
        case .level2: [254, 253]
        }
    }

    /// The hardware it needs.
    public var setup: MachineSetup {
        switch self {
        case .level1: MachineSetup(model: .modelB)
        case .level2: MachineSetup(model: .modelB, secondProcessor: true)
        case .level3: MachineSetup(model: .master128, secondProcessor: true)
        }
    }

    /// Whether the user can choose it for a file server: Level 3 needs a
    /// hard disc with the server on it.
    public var isChoosable: Bool { self != .level3 }
}

/// A disc a station's drive holds: a copy kept in the network's package
/// (so the BBCs never write to the user's own file), and where it came
/// from.
public struct MediaReference: Codable, Sendable, Equatable {
    /// The copy's name in the package's Media folder.
    public var storedName: String
    /// What it was called when it was added.
    public var displayName: String
    /// The original's path, for reference only.
    public var originalPath: String?

    public init(storedName: String, displayName: String, originalPath: String? = nil) {
        self.storedName = storedName
        self.displayName = displayName
        self.originalPath = originalPath
    }
}

public struct CanvasPoint: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

/// How the canvas was last shown.
public struct CanvasLayout: Codable, Sendable, Equatable {
    /// 0 until the network's first shown: then it's fitted to the window.
    public var zoom = 0.0
    /// The canvas point at the centre of the view.
    public var centre = CanvasPoint()
    public var snapToGrid = true

    public init() {}
}

/// The tiled workspace: which stations, how many columns.
public struct Workspace: Codable, Sendable, Equatable {
    public var tiles: [UUID] = []
    /// 0 for as many as fit.
    public var columns = 0
    /// The machine the Focus view shows large.
    public var focus: UUID?

    public init() {}
}
