import AppKit
import BeebCore
import BeebHost
import BeebNetwork
import BeebROMs
import Observation

/// An open network: its project, saved as it changes, and its machines,
/// running. Each machine that's on has a `MachineController`, whether or
/// not it has a window, so its window, tile and canvas card all show the
/// same running machine.
@MainActor
@Observable
final class NetworkSession: StationOwner {
    private(set) var project: NetworkProject
    /// Where it's saved: a `.macbeebnet` package. Changes are saved there
    /// as they're made.
    private(set) var url: URL
    @ObservationIgnored let runtime: NetworkRuntime
    /// The machines switched on, by node.
    private(set) var controllers: [UUID: MachineController] = [:]
    /// The nodes selected on the canvas.
    var selection: Set<UUID> = []
    /// The station typed into (in the tiles) and heard.
    private(set) var focused: UUID?
    /// The whole network is paused.
    private(set) var paused = false
    /// The network's status, refreshed a few times a second.
    private(set) var status = NetworkHost.Status()
    /// The nodes that put something on the line since the last refresh.
    private(set) var transmitting: Set<UUID> = []
    /// A save failed: why.
    private(set) var saveError: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored let thumbnails = ThumbnailCache()
    /// Its Internet Econet room, while it's in one (NetworkSession+Internet).
    @ObservationIgnored var internet: InternetEconetLink?
    /// The room as last heard.
    var room: RoomConnection.Snapshot?
    /// The invitation made this session, to show the host (its code isn't
    /// kept anywhere).
    var currentInvite: Invite?
    /// What the room was told of the stations, to tell it changes.
    @ObservationIgnored var lastClaims: [StationClaim] = []
    @ObservationIgnored private var closed = false
    /// The room's screens connection, while the room allows screen sharing.
    @ObservationIgnored var screens: RoomScreens?
    @ObservationIgnored var screenTimer: Timer?
    @ObservationIgnored var sendingScreens: Set<UUID> = []
    /// Other members' machines' screens, by station.
    var remoteScreens: [Int: CGImage] = [:]

    /// The sessions open, by package (one each).
    private(set) static var open: [URL: NetworkSession] = [:]
    /// Packages that have moved (renamed or kept somewhere) since a window
    /// was given their address: old to new.
    private static var moves: [URL: URL] = [:]

    /// A package's address as `open` keys it (a folder's URL can come with
    /// or without its trailing slash).
    static func key(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    /// The open session for the network at `url`, or that was there.
    static func existing(_ url: URL) -> NetworkSession? {
        var key = key(url)
        for _ in 0..<8 {
            if let session = open[key] { return session }
            guard let next = moves[key] else { return nil }
            key = next
        }
        return nil
    }

    /// The session for the network at `url`, opening it if it isn't.
    static func session(for url: URL) throws -> NetworkSession {
        let key = key(url)
        if let session = existing(key) { return session }
        let session = try NetworkSession(url: key)
        open[key] = session
        return session
    }

    private init(url: URL) throws {
        self.url = url
        let loaded = try NetworkPackage.load(from: url)
        project = loaded
        runtime = NetworkRuntime(packageURL: url, clockRate: NetworkRuntime.clockRate(of: loaded),
                                 discDriveSounds: MachineController.discDriveSounds(for:))
        runtime.start()
        for node in project.nodes where node.isMachine && node.poweredOn {
            powerOn(node.id, remember: false)
        }
        focused = project.workspace.tiles.first { controllers[$0] != nil } ?? controllers.keys.sorted { $0.uuidString < $1.uuidString }.first
        controllers[focused ?? UUID()]?.setAudible(true)
        runtime.network.setAudioStation(focused)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let status = self.runtime.network.status
                guard status != self.status else {
                    if !self.transmitting.isEmpty { self.transmitting = [] }
                    return
                }
                let before = self.status.traffic
                let sent = Set(status.traffic.compactMap { station, traffic in
                    traffic.bytes != before[station]?.bytes ? station : nil
                })
                let nodes = Set(self.project.nodes.filter { $0.stationNumber.map { sent.contains(UInt8(clamping: $0)) } ?? false }.map(\.id))
                if nodes != self.transmitting { self.transmitting = nodes }
                self.status = status
            }
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        RecentNetworks.shared.add(url)
        connectToRoomIfLinked()
        // Agents can reach the network's machines even with no standalone
        // window open.
        MachineController.startAgentServerIfNeeded()
    }

    /// Closes the network: its machines stop, and it's saved.
    func close() {
        // Once (deleting a network closes it before its window goes).
        guard !closed else { return }
        closed = true
        stopScreens()
        internet?.stop()
        internet = nil
        renameFileToMatch()
        saveNow()
        statusTimer?.invalidate()
        for controller in controllers.values {
            controller.detachFromNetwork()
        }
        controllers.removeAll()
        runtime.stop()
        for (key, session) in Self.open where session === self { Self.open[key] = nil }
    }

    /// Keeps a new network: named `name`, in `folder` (its name's own if
    /// it's taken there), no longer a draft.
    func keep(as name: String, in folder: URL) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update {
            $0.name = name.isEmpty ? $0.name : name
            $0.draft = nil
        }
        saveNow()
        let clean = project.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var target = folder.appendingPathComponent(clean).appendingPathExtension(NetworkPackage.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) && target.standardizedFileURL != url {
            target = folder.appendingPathComponent("\(clean) \(n)").appendingPathExtension(NetworkPackage.fileExtension)
            n += 1
        }
        guard target.standardizedFileURL != url else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: target)
        moved(to: target)
    }

    /// Deletes a new network: it closes (leaving its Internet room, if it's
    /// in one) and goes in the Trash.
    func discard() async {
        if isInRoom { await leaveRoom() }
        let package = url
        close()
        RecentNetworks.shared.remove(package)
        if LaunchScreen.isSelfTest {
            // (Not the user's Trash.)
            try? FileManager.default.removeItem(at: package)
        } else {
            try? FileManager.default.trashItem(at: package, resultingItemURL: nil)
        }
    }

    /// The package is somewhere else now.
    private func moved(to target: URL) {
        let old = Self.key(url)
        url = Self.key(target)
        runtime.packageURL = url
        // Windows that know it by its old address still find it.
        Self.open[old] = nil
        Self.open[url] = self
        Self.moves[old] = url
        // Discs in drives write back to the package: to its new place.
        for (id, controller) in controllers {
            for (drive, media) in project[id]?.discs ?? [:] {
                runtime.insert(media, drive: drive, into: controller.host)
            }
        }
        RecentNetworks.shared.replace(old, with: url)
    }

    /// Renames the package to the network's name (so Open Recent and the
    /// Finder say what the network's called), keeping it in its folder.
    /// The name's own, if it's taken there: "Name 2".
    func renameFileToMatch() {
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, !name.hasPrefix("."), name != url.deletingPathExtension().lastPathComponent else { return }
        saveNow()
        let folder = url.deletingLastPathComponent()
        var target = folder.appendingPathComponent(name).appendingPathExtension(NetworkPackage.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(NetworkPackage.fileExtension)
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            saveError = "Couldn't rename the network's file: \(error.localizedDescription)"
            return
        }
        moved(to: target)
    }

    // MARK: Saving

    /// Changes the project and saves it shortly (changes in quick
    /// succession, like a drag, save once).
    func update(_ change: (inout NetworkProject) -> Void) {
        var project = self.project
        change(&project)
        guard project != self.project else { return }
        let roms = { (p: NetworkProject) in Set(p.nodes.compactMap(\.setup).flatMap(\.pluggedROMs).map(\.id)) }
        if roms(project) != roms(self.project) {
            // The package's own copies of the ROMs its machines use.
            try? NetworkPackage.syncROMs(of: project, into: url)
        }
        let clock = NetworkRuntime.clockRate(of: project)
        if clock != NetworkRuntime.clockRate(of: self.project) {
            runtime.network.setClock(clock)
        }
        self.project = project
        scheduleSave()
        roomClaimsMayHaveChanged()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try NetworkPackage.save(project, to: url)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Saves a copy elsewhere and carries on with the copy.
    func saveAs(_ newURL: URL) throws {
        saveNow()
        let key = Self.key(newURL)
        if FileManager.default.fileExists(atPath: key.path) {
            try FileManager.default.removeItem(at: key)
        }
        try FileManager.default.copyItem(at: url, to: key)
        let old = Self.key(url)
        Self.open[old] = nil
        Self.moves[old] = key
        url = key
        runtime.packageURL = key
        Self.open[key] = self
        update {
            $0.name = key.deletingPathExtension().lastPathComponent
            // Saved somewhere: kept.
            $0.draft = nil
        }
        // Discs already in drives keep writing to the old copies until
        // they're changed; put the package's copies back in.
        for (id, controller) in controllers {
            for (drive, media) in project[id]?.discs ?? [:] {
                runtime.insert(media, drive: drive, into: controller.host)
            }
        }
        saveNow()
        RecentNetworks.shared.add(key)
    }

    // MARK: Nodes

    func node(_ id: UUID) -> NetworkNode? { project[id] }

    /// Adds a station set up as a saved machine, named after it.
    @discardableResult
    func add(_ saved: SavedMachine, at point: CanvasPoint) -> UUID? {
        add(.station, model: saved.setup.model, setup: saved.setup, name: saved.name, at: point)
    }

    /// Adds a machine (or the clock) at a canvas point, switched on. A
    /// Level 2 file server is a Model B with a 6502 Second Processor.
    @discardableResult
    func add(_ kind: NetworkNode.Kind, model: BBCMicro.Model = .modelB, level: FileServerLevel = .level1,
             setup: MachineSetup? = nil, name baseName: String? = nil, at point: CanvasPoint) -> UUID? {
        var node: NetworkNode
        if kind == .clock {
            guard !project.hasClock else { return nil }
            node = .clock(at: point)
        } else {
            let level2 = kind == .fileServer && level == .level2
            let conventional = level2 ? level.conventionalStations : kind.conventionalStation.map { [$0] } ?? []
            let preferred = conventional.first { project.stationNumberProblem($0, for: UUID()) == nil }
            guard let number = preferred ?? project.freeStationNumber() else { return nil }
            let base = kind == .station ? (model == .modelB ? "BBC" : model.displayName) : level2 ? "Level 2 File Server" : kind.displayName
            let name = baseName.map { project.freeName($0) }
                ?? (kind == .station ? project.freeName("\(base) \(number)") : project.freeName(base))
            node = NetworkNode(kind: kind, name: name, stationNumber: number,
                               setup: level2 ? level.setup : setup ?? MachineSetup(model: model),
                               position: point)
            if level2 { node.fileServerLevel = .level2 }
        }
        update { $0.nodes.append(node) }
        if node.isMachine {
            powerOn(node.id)
        }
        return node.id
    }

    /// Adds an Elite over Econet player: a Model B with sideways RAM that
    /// logs on to the file server as ELITE when it's ready, plays as a
    /// commander of its own, and reports to the scoreboard (this network's
    /// or the Internet room's), switched on.
    @discardableResult
    func addElitePlayer(at point: CanvasPoint) -> UUID? {
        let taken = Set(remoteStations.map(\.station))
        guard let number = (1...253).first(where: { !taken.contains($0) && $0 != 235 && project.stationNumberProblem($0, for: UUID()) == nil })
        else { return nil }
        let commander = freeCommanderName()
        var node = NetworkNode(kind: .station, name: project.freeName("Cmdr \(commander.capitalized)"), stationNumber: number,
                               setup: EliteOverEconet.playerSetup, position: point)
        node.startupScript = EliteOverEconet.playerScript(commander: commander, scoreboard: scoreboardStation)
        update { $0.nodes.append(node) }
        powerOn(node.id)
        return node.id
    }

    /// Elite over Econet's scoreboard: a machine here called Scoreboard, or
    /// one in the room.
    var scoreboardStation: Int? {
        project.nodes.first { EliteOverEconet.isScoreboard($0.name) }?.stationNumber
            ?? remoteStations.first { EliteOverEconet.isScoreboard($0.label) }?.station
    }

    /// A copy of a machine beside it, with the next free station number
    /// and copies of its discs.
    func duplicate(_ id: UUID) {
        guard var node = project[id], node.isMachine, let number = project.freeStationNumber(from: (node.stationNumber ?? 0) + 1) else { return }
        node.id = UUID()
        node.stationNumber = number
        node.name = project.freeName(node.name)
        node.position.x += 40
        node.position.y += 40
        node.discs = node.discs.compactMapValues { media in
            try? NetworkPackage.importMedia(NetworkPackage.url(of: media, in: url), into: url)
        }
        node.hardDisc = node.hardDisc.flatMap { try? NetworkPackage.copyHardDisc($0, in: url) }
        // An Elite player's copy is another commander.
        if let script = node.startupScript, EliteOverEconet.commander(in: script) != nil {
            node.startupScript = EliteOverEconet.playerScript(like: script, commander: freeCommanderName())
        }
        update { $0.nodes.append(node) }
        if node.poweredOn {
            powerOn(node.id)
        }
    }

    /// Takes nodes off the network: their machines stop, and their discs'
    /// copies go.
    func remove(_ ids: Set<UUID>) {
        for id in ids {
            powerOff(id, remember: false)
        }
        update { project in project.nodes.removeAll { ids.contains($0.id) } }
        selection.subtract(ids)
        project.workspace.tiles.removeAll { ids.contains($0) }
        removeUnusedMedia()
        saveNow()
    }

    func move(_ id: UUID, to point: CanvasPoint) {
        update { $0[id]?.position = point }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        update { $0[id]?.name = trimmed }
    }

    /// Changes a station's number, unless another machine has it or it's
    /// reserved. Returns why not, if not.
    @discardableResult
    func setStationNumber(_ id: UUID, to number: Int) -> String? {
        if let problem = project.stationNumberProblem(number, for: id) { return problem }
        update { $0[id]?.stationNumber = number }
        return nil
    }

    /// A new station number, taking effect now: a machine's network
    /// interface takes its number when it starts, so a machine that's on
    /// starts again (its memory is lost; its discs stay). Off and on, not a
    /// power cycle, which would rebuild it with its old number.
    func renumber(_ id: UUID, to number: Int) -> String? {
        guard number != project[id]?.stationNumber else { return nil }
        if let problem = setStationNumber(id, to: number) { return problem }
        if controllers[id] != nil {
            powerOff(id, remember: false)
            powerOn(id, remember: false)
        }
        return nil
    }

    // MARK: Power

    func isOn(_ id: UUID) -> Bool { controllers[id] != nil }

    /// Switches a machine on: a fresh machine, as at power on.
    func powerOn(_ id: UUID, remember: Bool = true, startingServer: Bool = true) {
        guard controllers[id] == nil, let node = project[id], node.isMachine, let setup = node.setup else { return }
        let printerName = node.kind == .printServer
            ? "\(node.name) · station \(node.stationNumber ?? 0)"
            : "\(node.name)'s printer port"
        guard let host = runtime.powerOn(node, printer: (printerName, PrintCentre.receiver())) else { return }
        if node.bootsDisc == true {
            host.send(.shiftBreak)
        }
        if node.bootsNetwork == true {
            bootFromNetwork(id)
        }
        if let script = node.startupScript, !script.isEmpty {
            runStartupScript(id, script)
        }
        let controller = MachineController(station: id, host: host, setup: setup, owner: self)
        controller.watchesConsole = node.kind != .station
        for (drive, media) in node.discs {
            controller.noteNetworkDisc(media.displayName, drive: drive)
        }
        controllers[id] = controller
        if remember {
            update { $0[id]?.poweredOn = true }
        }
        if startingServer && node.kind == .fileServer && node.startsServerWhenOn {
            startFileServer(id)
        }
        if startingServer && node.kind == .printServer && node.startsServerWhenOn {
            startPrinterServer(id)
        }
        if focused == nil {
            focus(id)
        }
    }

    /// A station that boots from the network: once a file server's ready,
    /// it selects the network and logs on as BOOT. A Level 2 server then
    /// has it run BOOT's !BOOT (boot option 3); for Level 1, which can't,
    /// what the server's !BOOT says is typed.
    private func bootFromNetwork(_ id: UUID) {
        Task { @MainActor [weak self] in
            // (For two minutes: a server that hasn't started by then won't.)
            for _ in 0..<240 {
                guard let self, let controller = self.controllers[id] else { return }
                if let commands = await self.serverBootCommands() {
                    controller.host.send(.type((["*NET", "*I AM BOOT"] + commands).map { $0 + "\n" }.joined()))
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Plays a machine's startup script into it while it's on: a little
    /// every 50ms, on its own thread, telling it whether a file server's
    /// ready.
    private func runStartupScript(_ id: UUID, _ steps: [StartupStep]) {
        let runner = StartupScriptRunner(steps)
        Task { @MainActor [weak self] in
            while let self, let controller = self.controllers[id] {
                let ready = await self.fileServerReady()
                let finished = (try? await controller.host.performAsync { session in
                    runner.advance(session.machine, serverReady: ready)
                }) ?? true
                if finished { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Whether a file server's ready: one of this network's, or one in the
    /// Internet room it's in.
    func fileServerReady() async -> Bool {
        if await serverBootCommands() != nil { return true }
        return remoteStations.contains { $0.role == "fileServer" && $0.online }
    }

    /// A commander's name no Elite player here has.
    func freeCommanderName() -> String {
        let taken = Set(project.nodes.compactMap { $0.startupScript.flatMap(EliteOverEconet.commander(in:)) })
        return EliteOverEconet.commanderName(0, avoiding: taken)
    }

    /// The file servers that have said they're ready, since they started.
    @ObservationIgnored private var readyServers: Set<UUID> = []

    /// The boot file of a ready file server, if there is one.
    private func serverBootCommands() async -> [String]? {
        for node in project.nodes where node.kind == .fileServer {
            guard let controller = controllers[node.id] else { continue }
            let level1 = node.level == .level1
            let (ready, commands) = (try? await controller.host.performAsync { session -> (Bool, [String]?) in
                // Level 1 says "Ready", Levels 2 and 3 "Starting - Ready".
                let ready = session.machine.screenText().contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("Ready") }
                return (ready, level1 ? session.machine.drives[0].disc.flatMap(FileServerDisc.bootCommands(on:)) : [])
            }) ?? (false, nil)
            if ready { readyServers.insert(node.id) }
            if readyServers.contains(node.id) { return commands ?? [] }
        }
        return nil
    }

    /// Switches a machine off: it stops, and what's in its memory is gone.
    func powerOff(_ id: UUID, remember: Bool = true) {
        readyServers.remove(id)
        guard let controller = controllers.removeValue(forKey: id) else { return }
        controller.detachFromNetwork()
        runtime.powerOff(id)
        thumbnails.forget(id)
        if focused == id {
            focused = nil
            runtime.network.setAudioStation(nil)
        }
        if remember {
            update { $0[id]?.poweredOn = false }
        }
    }

    func togglePower(_ id: UUID) {
        isOn(id) ? powerOff(id) : powerOn(id)
    }

    /// Power off and on: a cold boot, as switching it off and on.
    func coldBoot(_ id: UUID) {
        guard let controller = controllers[id] else {
            powerOn(id)
            return
        }
        controller.host.send(.powerCycle)
    }

    func pressBreak(_ id: UUID) {
        controllers[id]?.host.send(.pressBreak)
    }

    /// A suspended station stops where it is while the others run on.
    func isSuspended(_ id: UUID) -> Bool { controllers[id]?.paused ?? false }

    func setSuspended(_ id: UUID, _ suspended: Bool) {
        controllers[id]?.setPaused(suspended)
    }

    func powerOnAll() {
        for node in project.nodes where node.isMachine {
            powerOn(node.id)
        }
    }

    func powerOffAll() {
        for id in Array(controllers.keys) {
            powerOff(id)
        }
    }

    /// Break on every machine.
    func resetAll() {
        for controller in controllers.values {
            controller.host.send(.pressBreak)
        }
    }

    /// Pauses the whole network: no time passes anywhere, so nothing on
    /// it times out.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        runtime.network.setPaused(paused)
    }

    // MARK: Discs

    /// Asks for a disc image and puts it in a machine's drive: into the
    /// running machine if it's on, else for when it's switched on.
    func chooseDisc(for id: UUID, drive: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MachineController.discTypes
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        insertDisc(source, into: id, drive: drive)
    }

    func insertDisc(_ source: URL, into id: UUID, drive: Int) {
        if let controller = controllers[id] {
            controller.insertDisc(source, drive: drive, boot: false)
            return
        }
        do {
            let media = try NetworkPackage.importMedia(source, into: url)
            update { $0[id]?.discs[drive] = media }
            removeUnusedMedia()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func eject(_ id: UUID, drive: Int) {
        if let controller = controllers[id] {
            controller.ejectDisc(drive: drive)
        } else {
            update { $0[id]?.discs[drive] = nil }
            removeUnusedMedia()
        }
    }

    private func removeUnusedMedia() {
        for old in NetworkPackage.unusedMedia(of: project, in: url) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: Servers

    /// What a file server should type to start Acorn's Level 1 server:
    /// `CH."FS"`, then its questions answered, giving every other machine
    /// on the network the class's shared directory, A.
    func fileServerStartup(for id: UUID) -> String {
        let clients = project.stations.filter { $0.id != id && $0.kind == .station }.compactMap(\.stationNumber)
        // Files per user is the most each directory holds: the stations
        // share one, so it's room for theirs and any put there from the Mac.
        var text = "CH.\"FS\"\n\(Self.filesPerUser)\nY\n"
        for station in clients.prefix(30) {
            text += "A\n\(station)\n"
        }
        return text + "\n"
    }

    static let filesPerUser = 20

    /// Starts Acorn's Level 1 file server on a machine: the network's copy
    /// of the server disc goes in its drive 0 (if it hasn't one), it's
    /// reset, and the start-up is typed, as the server's manual says.
    func startFileServer(_ id: UUID) {
        readyServers.remove(id)
        if project[id]?.level == .level2 {
            startLevel2FileServer(id)
            return
        }
        if project[id]?.level == .level3 {
            startLevel3FileServer(id)
            return
        }
        if !isOn(id) { powerOn(id, startingServer: false) }
        guard let controller = controllers[id] else { return }
        if project[id]?.discs[0] == nil, let image = try? FileServerDisc.image() {
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("File Server.ssd")
            try? Data(image).write(to: staged)
            controller.insertDisc(staged, drive: 0, boot: false)
        }
        controller.host.send(.pressBreak)
        let startup = fileServerStartup(for: id)
        Task { @MainActor in
            // After Break's banner.
            try? await Task.sleep(for: .seconds(1.5))
            controller.host.send(.type(startup))
        }
    }

    /// Starts Acorn's Level 2 file server: the network's copy of its disc
    /// goes in drive 0 and the utilities disc in drive 1 (if they're
    /// empty), and the start-up is typed: *RUN FS from drive 1, the date,
    /// one drive, start, and how many stations may log on.
    private func startLevel2FileServer(_ id: UUID) {
        if !isOn(id) { powerOn(id, startingServer: false) }
        guard let controller = controllers[id] else { return }
        let staging = FileManager.default.temporaryDirectory
        if project[id]?.discs[0] == nil, let disc = try? Level2FileServerDisc.standard() {
            let staged = staging.appendingPathComponent("Level 2 File Server.dsd")
            try? Data(disc.image).write(to: staged)
            controller.insertDisc(staged, drive: 0, boot: false)
        }
        let drive = Level2FileServerDisc.utilitiesDrive
        if project[id]?.discs[drive] == nil {
            let utilities = Level2FileServerDisc.utilities
            let staged = staging.appendingPathComponent("Level 2 Utilities.\(utilities.format.rawValue)")
            try? Data(utilities.data).write(to: staged)
            controller.insertDisc(staged, drive: drive, boot: false)
        }
        controller.host.send(.pressBreak)
        let stations = project.stations.filter { $0.id != id }.count
        let startup = Level2FileServerDisc.startup(stations: max(stations, 10))
        Task { @MainActor in
            // After Break's banner.
            try? await Task.sleep(for: .seconds(1.5))
            controller.host.send(.type(startup))
        }
    }

    /// Starts Acorn's Level 3 file server, from its hard disc: the date
    /// and time go in the !BOOT that answers its questions, and after Break
    /// ADFS mounts the hard disc and runs it.
    private func startLevel3FileServer(_ id: UUID) {
        guard let media = project[id]?.hardDisc else {
            let alert = NSAlert()
            alert.messageText = "This Level 3 file server has no hard disc"
            alert.informativeText = "Level 3 runs from a hard disc with the server on it, as the Elite over Econet network’s has."
            alert.runModal()
            return
        }
        if !isOn(id) { powerOn(id, startingServer: false) }
        guard let controller = controllers[id] else { return }
        // The machine has the disc as it was: give it the dated one.
        runtime.attachHardDisc(media, to: controller.host) { EliteOverEconet.dateBoot(&$0) }
        controller.host.send(.pressBreak)
        Task { @MainActor in
            // After Break's banner.
            try? await Task.sleep(for: .seconds(1.5))
            controller.host.send(.type(EliteOverEconet.level3Startup))
        }
    }

    /// Makes a file server Level 1 or Level 2: its hardware changes to
    /// suit (a power cycle, if it's on), and a disc of the other level's
    /// format comes out, so starting puts in a fresh one of its own.
    func setFileServerLevel(_ id: UUID, _ level: FileServerLevel) {
        guard let node = project[id], node.kind == .fileServer, node.level != level else { return }
        let wasOn = isOn(id)
        powerOff(id)
        update { project in
            project[id]?.fileServerLevel = level == .level1 ? nil : level
            project[id]?.setup?.model = level.setup.model
            project[id]?.setup?.secondProcessor = level.setup.secondProcessor
            for (drive, media) in project[id]?.discs ?? [:] {
                let image = (try? Data(contentsOf: NetworkPackage.url(of: media, in: url))).map { [UInt8]($0.prefix(4)) } ?? []
                if Level2FileServerDisc.isLevel2(image) != (level == .level2) || drive == Level2FileServerDisc.utilitiesDrive {
                    project[id]?.discs[drive] = nil
                }
            }
        }
        removeUnusedMedia()
        if wasOn { powerOn(id) }
    }

    /// Starts MacBeeb's printer server on a machine: the server disc goes
    /// in its drive 0 (if it hasn't one), and it boots it (Shift-Break).
    /// Its printer's jobs go to the Print Centre.
    func startPrinterServer(_ id: UUID) {
        if !isOn(id) { powerOn(id, startingServer: false) }
        guard let controller = controllers[id] else { return }
        if project[id]?.discs[0] == nil, let image = try? PrinterServer.disc() {
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("Printer Server.ssd")
            try? Data(image).write(to: staged)
            controller.insertDisc(staged, drive: 0, boot: false)
        }
        controller.host.send(.shiftBreak)
    }

    /// Puts Mac files on a file server's disc, in the directory every
    /// station shares, while it serves (it sees them at once). Named and
    /// addressed by .inf files beside them; BASIC text (.bas) is tokenised.
    func addFilesToServer(_ id: UUID, _ urls: [URL]) {
        if project[id]?.level == .level3 {
            let alert = NSAlert()
            alert.messageText = "MacBeeb can’t add files to a Level 3 file server yet"
            alert.informativeText = "Copy them over the network from another station instead."
            alert.runModal()
            return
        }
        if project[id]?.level == .level2 {
            addFilesToLevel2Server(id, urls)
            return
        }
        guard let controller = controllers[id], project[id]?.discs[0] != nil else {
            let alert = NSAlert()
            alert.messageText = "The file server isn’t running"
            alert.informativeText = "Switch it on (its disc goes in when it starts), then add the files."
            alert.runModal()
            return
        }
        let host = controller.host
        Task {
            do {
                // The drive may be busy serving: wait for a quiet moment.
                for _ in 0..<40 {
                    switch try await host.changeVolume(drive: 0, { volume in try FileServerDisc.add(urls, to: &volume) }) {
                    case .changed: return
                    case .noDisc: throw CocoaError(.fileNoSuchFile)
                    case .busy: try await Task.sleep(for: .milliseconds(150))
                    }
                }
                throw CocoaError(.fileWriteVolumeReadOnly)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t add the files to the file server"
                alert.informativeText = (error as? DiscEditError).map { "\($0)" } ?? error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// Puts Mac files in a Level 2 server's $.LIBRARY, for every user, with
    /// the server switched off: it keeps its disc's map and directories in
    /// memory while it serves, so a change underneath it would be lost.
    private func addFilesToLevel2Server(_ id: UUID, _ urls: [URL]) {
        do {
            guard !isOn(id) else {
                let alert = NSAlert()
                alert.messageText = "Switch the Level 2 file server off first"
                alert.informativeText = "It keeps its disc’s map and directories in memory while it serves. Switch it off, add the files, and switch it on again."
                alert.runModal()
                return
            }
            var disc: Level2FileServerDisc
            if let media = project[id]?.discs[0] {
                disc = try Level2FileServerDisc(image: [UInt8](Data(contentsOf: NetworkPackage.url(of: media, in: url))))
            } else {
                disc = try Level2FileServerDisc.standard()
            }
            if (try? disc.entry(at: "$.LIBRARY")) == nil {
                try disc.createDirectory("$.LIBRARY")
            }
            try disc.add(urls)
            if let media = project[id]?.discs[0] {
                try Data(disc.image).write(to: NetworkPackage.url(of: media, in: url))
            } else {
                let staged = FileManager.default.temporaryDirectory.appendingPathComponent("Level 2 File Server.dsd")
                try Data(disc.image).write(to: staged)
                let media = try NetworkPackage.importMedia(staged, into: url)
                update { $0[id]?.discs[0] = media }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t add the files to the file server"
            alert.informativeText = (error as? DiscEditError).map { "\($0)" } ?? error.localizedDescription
            alert.runModal()
        }
    }

    func chooseFilesForServer(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = project[id]?.level == .level2
            ? "Choose files for the file server. Each goes in $.LIBRARY, where every user can load it."
            : "Choose files for the file server. Each goes in directory A, where every station can load it."
        guard panel.runModal() == .OK else { return }
        addFilesToServer(id, panel.urls)
    }

    /// What a server's console says: its last non-blank line.
    func serverStatus(_ id: UUID) -> String? {
        guard let controller = controllers[id] else { return nil }
        return controller.consoleLine
    }

    // MARK: Focus

    /// The station typed into in the tiles, and heard.
    func focus(_ id: UUID?) {
        guard focused != id else { return }
        if let old = focused {
            controllers[old]?.setAudible(false)
        }
        focused = id.flatMap { controllers[$0] != nil ? $0 : nil }
        if let focused {
            controllers[focused]?.setAudible(true)
        }
        runtime.network.setAudioStation(focused)
    }

    /// The next (or previous) machine that's on, by station number.
    func focusNext(_ forward: Bool = true) {
        let on = project.stations.filter { controllers[$0.id] != nil }.map(\.id)
        guard !on.isEmpty else { return }
        let index = focused.flatMap { on.firstIndex(of: $0) } ?? (forward ? on.count - 1 : 0)
        focus(on[(index + (forward ? 1 : on.count - 1)) % on.count])
    }

    // MARK: StationOwner

    func stationSetupChanged(_ controller: MachineController) {
        guard let id = controller.stationID else { return }
        let setup = controller.setup
        update { $0[id]?.setup = setup }
    }

    func station(_ controller: MachineController, willInsert source: URL, drive: Int) -> URL? {
        guard let id = controller.stationID else { return nil }
        // Already one of the package's copies.
        if source.standardizedFileURL.path.hasPrefix(NetworkPackage.mediaURL(in: url).standardizedFileURL.path) {
            return source
        }
        do {
            let media = try NetworkPackage.importMedia(source, into: url)
            update { $0[id]?.discs[drive] = media }
            removeUnusedMedia()
            return NetworkPackage.url(of: media, in: url)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    func station(_ controller: MachineController, didEject drive: Int) {
        guard let id = controller.stationID else { return }
        update { $0[id]?.discs[drive] = nil }
        removeUnusedMedia()
    }

    var romSource: ROMSource { NetworkPackage.romSource(for: url) }

    func stationNumber(_ controller: MachineController) -> Int? {
        controller.stationID.flatMap { project[$0]?.stationNumber }
    }

    func stationTitle(_ controller: MachineController) -> String {
        guard let id = controller.stationID, let node = project[id] else { return "Station" }
        return node.stationNumber.map { "\(node.name) · station \($0)" } ?? node.name
    }
}
