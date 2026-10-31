import BeebCore
import BeebNetwork
import Foundation
import Observation

/// What the Hardware window sets up: a running machine (changes restart
/// it), or a machine's set-up where no machine's running (a network's
/// station that's off, or a saved machine configuration), whose changes
/// are saved for when it next starts.
@MainActor
protocol HardwareTarget: AnyObject {
    /// The machine as it's set up now.
    var setup: MachineSetup { get }
    /// The running machine, if there is one: for what's in its memory.
    var running: MachineController? { get }
    /// A network's station: its Econet ROM takes a socket.
    var isStation: Bool { get }
    var romSource: ROMSource { get }
    /// Counts changes, for refreshing what the window shows.
    var hardwareChanges: Int { get }
    /// What it is, for the window: "Master 4", "Word Processor".
    var hardwareTitle: String? { get }
    func apply(_ draft: MachineController.HardwareDraft)
}

extension HardwareTarget {
    var hardwareDraft: MachineController.HardwareDraft { MachineController.HardwareDraft(setup) }
}

extension MachineController.HardwareDraft {
    init(_ setup: MachineSetup) {
        self.init(model: setup.model, expansions: setup.expansions, controllerROMPaths: setup.controllerROMPaths,
                  videoNuLA: setup.videoNuLA, sockets: setup.sockets)
    }

    /// `setup` with the draft's changes.
    func applied(to setup: MachineSetup) -> MachineSetup {
        var new = setup
        new.model = model
        new.expansions = expansions
        new.controllerROMPaths = controllerROMPaths
        new.videoNuLA = videoNuLA
        new.sockets = sockets
        return new
    }
}

extension MachineController: HardwareTarget {
    var running: MachineController? { self }
    var hardwareTitle: String? { station?.stationTitle(self) }
}

/// A network's station, whether it's on or off: while it's on, its
/// machine; while it's off, its set-up in the network.
@MainActor
@Observable
final class StationHardwareTarget: HardwareTarget {
    let session: NetworkSession
    let node: UUID
    private(set) var hardwareChanges = 0

    init(session: NetworkSession, node: UUID) {
        self.session = session
        self.node = node
    }

    var running: MachineController? { session.controllers[node] }
    var setup: MachineSetup { running?.setup ?? session.project[node]?.setup ?? MachineSetup() }
    var isStation: Bool { true }
    var romSource: ROMSource { session.romSource }
    var hardwareTitle: String? { session.project[node]?.name }

    func apply(_ draft: MachineController.HardwareDraft) {
        if let running {
            running.apply(draft)
        } else {
            let new = draft.applied(to: setup)
            session.update { $0[node]?.setup = new }
            hardwareChanges += 1
        }
    }
}

/// A saved machine configuration.
@MainActor
@Observable
final class ConfigurationHardwareTarget: HardwareTarget {
    let id: UUID
    private(set) var hardwareChanges = 0

    init(id: UUID) {
        self.id = id
    }

    private var saved: SavedMachine? { MachineConfigurations.shared[id] }
    var setup: MachineSetup { saved?.setup ?? MachineSetup() }
    var running: MachineController? { nil }
    var isStation: Bool { false }
    var romSource: ROMSource { .library }
    var hardwareTitle: String? { saved?.name }

    func apply(_ draft: MachineController.HardwareDraft) {
        guard let saved else { return }
        try? MachineConfigurations.shared.update(saved.id, setup: draft.applied(to: saved.setup))
        hardwareChanges += 1
    }
}

/// Which Hardware window: a running machine's, a network station's, or a
/// saved configuration's.
enum HardwareRef: Codable, Hashable {
    case machine(UUID)
    case station(network: URL, node: UUID)
    case configuration(UUID)

    /// The same one each time (a window's view is made again and again).
    @MainActor private static var targets: [HardwareRef: any HardwareTarget] = [:]

    @MainActor
    var target: (any HardwareTarget)? {
        switch self {
        case .machine(let id):
            return MachineController.all[id]
        case .station(let network, let node):
            guard let session = NetworkSession.existing(network), session.project[node] != nil else { return nil }
            if let station = Self.targets[self] as? StationHardwareTarget, station.session === session { return station }
            let station = StationHardwareTarget(session: session, node: node)
            Self.targets[self] = station
            return station
        case .configuration(let id):
            guard MachineConfigurations.shared[id] != nil else { return nil }
            if let cached = Self.targets[self] { return cached }
            let configuration = ConfigurationHardwareTarget(id: id)
            Self.targets[self] = configuration
            return configuration
        }
    }
}
