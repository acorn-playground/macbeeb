import BeebCore
import BeebHost
import BeebPrint
import Foundation

/// A network project's machines, running: a `NetworkHost` with a station
/// for each machine that's switched on. Use from one thread (the app's main
/// thread); the network itself runs on its own.
public final class NetworkRuntime: @unchecked Sendable {
    public let network: NetworkHost
    /// The package the network's discs are kept in.
    public var packageURL: URL
    /// The stations switched on, by node.
    public private(set) var stations: [UUID: EmulatorHost] = [:]
    /// Builds each station's disc drive sounds.
    private let discDriveSounds: (@Sendable (BBCMicro.Model) -> DiscDriveSounds?)?

    /// `clockRate`: the Econet clock's (nil: no clock).
    public init(packageURL: URL, clockRate: Int?, discDriveSounds: (@Sendable (BBCMicro.Model) -> DiscDriveSounds?)? = nil) {
        self.packageURL = packageURL
        self.discDriveSounds = discDriveSounds
        network = NetworkHost(econetClockRate: .some(clockRate))
    }

    /// The clock's rate for a project: its clock node's, if it has one.
    public static func clockRate(of project: NetworkProject) -> Int? {
        project.nodes.first { $0.kind == .clock }.map { $0.clockRate ?? NetworkNode.defaultClockRate }
    }

    public func start() {
        network.start()
    }

    public func stop() {
        network.stop()
        stations.removeAll()
    }

    /// Switches a machine on: a new machine, as at power on, with the
    /// node's discs in its drives. If it's already on, its station.
    @discardableResult
    public func powerOn(_ node: NetworkNode, discDriveSoundsOn: Bool = false,
                        printer: (name: String, jobs: @Sendable (PrintJob) -> Void)? = nil) -> EmulatorHost? {
        guard node.isMachine, let setup = node.setup else { return nil }
        if let running = stations[node.id] { return running }
        let configuration = setup.configuration(econetStation: node.stationNumber, roms: NetworkPackage.romSource(for: packageURL))
        let host = network.addStation(id: node.id, discDriveSounds: discDriveSounds, discDriveSoundsOn: discDriveSoundsOn,
                                      printer: printer) {
            BBCMicro(configuration: configuration)
        }
        for (drive, media) in node.discs {
            insert(media, drive: drive, into: host)
        }
        if let media = node.hardDisc {
            attachHardDisc(media, to: host)
        }
        stations[node.id] = host
        return host
    }

    /// Connects one of the package's hard discs to a station's SCSI
    /// interface; the BBC's writes go back to the package's copy as it
    /// makes them. `prepare` can change the image first.
    public func attachHardDisc(_ media: MediaReference, to host: EmulatorHost, prepare: ((inout [UInt8]) -> Void)? = nil) {
        let url = NetworkPackage.url(of: media, in: packageURL)
        let parametersURL = NetworkPackage.parametersURL(of: media, in: packageURL)
        guard var image = FileManager.default.contents(atPath: url.path).map({ [UInt8]($0) }) else { return }
        if let prepare {
            let before = image
            prepare(&image)
            if image != before { try? Data(image).write(to: url, options: .atomic) }
        }
        let parameters = FileManager.default.contents(atPath: parametersURL.path).map { [UInt8]($0) }
        let disc = HardDisc(image: image, parameters: parameters)
        let file = HardDiscFile(url: url, parametersURL: parametersURL)
        disc.onSectorWritten = { lba, bytes in file.write(bytes, at: lba * 256) }
        disc.onParametersWritten = { file.writeParameters($0) }
        disc.onFormatted = { file.truncate() }
        host.send(.perform { session in session.machine.attachHardDisc(disc) })
    }

    /// Switches a machine off: it stops, and its memory is gone. Its discs
    /// have been written back as it went.
    public func powerOff(_ id: UUID) {
        guard stations[id] != nil else { return }
        network.removeStation(id: id)
        stations[id] = nil
    }

    /// Puts one of the package's discs in a station's drive; the BBC's
    /// writes go back to the package's copy.
    public func insert(_ media: MediaReference, drive: Int, into host: EmulatorHost) {
        let url = NetworkPackage.url(of: media, in: packageURL)
        guard let data = FileManager.default.contents(atPath: url.path),
              let format = Disc.ImageFormat(path: url.path) else { return }
        host.send(.insertDisc(image: [UInt8](data), format: format, drive: drive, onWrite: { bytes in
            try? Data(bytes).write(to: url, options: .atomic)
        }))
    }
}

/// A hard disc's .dat, written as the BBC writes its sectors (on the
/// emulation thread).
final class HardDiscFile: @unchecked Sendable {
    let url: URL
    let parametersURL: URL
    private var handle: FileHandle?

    init(url: URL, parametersURL: URL) {
        self.url = url
        self.parametersURL = parametersURL
    }

    func write(_ bytes: ArraySlice<UInt8>, at offset: Int) {
        if handle == nil { handle = try? FileHandle(forWritingTo: url) }
        guard let handle else { return }
        try? handle.seek(toOffset: UInt64(offset))
        try? handle.write(contentsOf: Data(bytes))
    }

    func writeParameters(_ bytes: [UInt8]) {
        try? Data(bytes).write(to: parametersURL, options: .atomic)
    }

    func truncate() {
        if handle == nil { handle = try? FileHandle(forWritingTo: url) }
        try? handle?.truncate(atOffset: 0)
    }

    deinit {
        try? handle?.close()
    }
}
