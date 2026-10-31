import BeebAgentKit
import BeebCapture
import BeebCore
import BeebDAP
import BeebHost
import BeebLibrary
import BeebNetwork
import BeebROMs
import Foundation
import Observation

/// What a network station's controller tells its network: the station's
/// hardware and discs belong to the network's project, not the app's
/// defaults.
@MainActor
protocol StationOwner: AnyObject {
    /// The station's hardware changed (its window's menus or Hardware
    /// Expansions).
    func stationSetupChanged(_ controller: MachineController)
    /// A disc is going into one of its drives: where the station should
    /// use it from (the network's copy), or nil not to.
    func station(_ controller: MachineController, willInsert url: URL, drive: Int) -> URL?
    func station(_ controller: MachineController, didEject drive: Int)
    /// "BBC 2 · station 2", for the window title.
    func stationTitle(_ controller: MachineController) -> String
    /// Its Econet station number, which its machine is built with.
    func stationNumber(_ controller: MachineController) -> Int?
    /// Where its ROMs are: the network's copies, then the library.
    var romSource: ROMSource { get }
}

/// One emulated machine and its window's actions.
@MainActor
@Observable
final class MachineController {
    let host: EmulatorHost
    private let audio: AudioOutput
    /// The network this machine is a station of, if it is one. Its hardware
    /// is remembered there, and it runs whether or not it has a window.
    @ObservationIgnored private(set) weak var station: StationOwner?
    /// The station's node in its network's project.
    let stationID: UUID?
    var isStation: Bool { stationID != nil }
    /// Whether its sound is playing (a station's is only while it's the
    /// one chosen).
    private(set) var audible = false
    /// For a server: the last line on its screen, read about once a
    /// second while `watchesConsole`.
    private(set) var consoleLine: String?
    @ObservationIgnored var watchesConsole = false
    @ObservationIgnored private var consoleTick = 0
    private(set) var paused = false
    /// An agent's holding the machine still between its tool calls
    /// (set_real_time). Resume lets it go.
    private(set) var heldForAgent = false
    /// Paused, by the user or for an agent.
    var isStill: Bool { paused || heldForAgent }
    private(set) var speedLimited = true
    /// The emulated model. New windows start with the last one chosen.
    private(set) var model: BBCMicro.Model
    /// How the window draws the picture. Shared by all windows.
    var displayStyle = DisplayStyle.saved {
        didSet { UserDefaults.standard.set(displayStyle.rawValue, forKey: DisplayStyle.defaultsKey) }
    }
    /// The monitor it's drawn on: colour, or green or amber monochrome.
    /// Shared by all windows.
    var monitor = Monitor.saved {
        didSet { UserDefaults.standard.set(monitor.rawValue, forKey: Monitor.defaultsKey) }
    }
    /// The window's renderer, for capturing the display as shown.
    @ObservationIgnored weak var renderer: Renderer?

    private static let modelDefaultsKey = "MacBeebModel"
    /// Whether a 6502 Second Processor is fitted. Remembered like the model.
    private(set) var secondProcessor: Bool
    private static let secondProcessorDefaultsKey = "MacBeebSecondProcessor"
    /// Which second processor, when one's fitted.
    private(set) var coprocessor: BBCMicro.Coprocessor
    private static let coprocessorDefaultsKey = "MacBeebCoprocessor"

    /// The second processor fitted, if any.
    var fittedCoprocessor: BBCMicro.Coprocessor? {
        secondProcessor && coprocessor.fits(model) ? coprocessor : nil
    }
    /// The Model B's disc interface. Remembered like the model.
    private(set) var discInterface: BBCMicro.DiscInterface
    private static let discInterfaceDefaultsKey = "MacBeebDiscInterface"
    /// The Model B's expansion board. Remembered like the model.
    private(set) var expansions: BBCMicro.Expansions
    private static let expansionsDefaultsKey = "MacBeebExpansions"
    /// Files put into sideways RAM banks at power on, by bank.
    private(set) var powerOnImagePaths: [Int: String]
    /// Controller ROMs the user has chosen in place of the bundled ones,
    /// by board.
    private(set) var controllerROMPaths: [BBCMicro.MemoryBoard: String]
    /// VideoNuLA fitted in place of the Video ULA (any model). Remembered
    /// like the model.
    private(set) var videoNuLA: Bool
    /// The user's ROMs in the sockets, and a Master's cartridges and
    /// links. Remembered like the model.
    private(set) var sockets: SocketSetup
    private static let powerOnImagesDefaultsKey = "MacBeebSidewaysPowerOnImages"
    /// Counts changes to the hardware (a power cycle with new hardware, or
    /// sideways RAM loaded or cleared), for the Hardware Expansions window.
    private(set) var hardwareChanges = 0
    /// Set to open the Hardware Expansions window.
    var hardwareRequested = false
    /// Identifies this machine to its debugger window.
    let id = UUID()
    /// Open machines, for finding a debugger window's machine.
    static var all: [UUID: MachineController] = [:]
    /// The debugger's view of this machine.
    @ObservationIgnored private(set) lazy var debugger = DebuggerModel(host: host)
    /// Set when the debugger stops the machine, so the window opens.
    var debuggerRequested = false
    /// Set to open the disc contents window (the machine window opens it).
    var discContentsRequested = false
    /// Set to open the BBC Micro Classics bookshelf.
    var bookshelfRequested = false
    /// Counts changes to the discs in the drives: a disc put in or taken
    /// out, or written to by the BBC.
    private(set) var discChanges = 0
    @ObservationIgnored private var lastDebugStop: StopReason?
    /// Why the debugger has stopped the machine, if it has.
    private(set) var debugStop: StopReason?
    /// The TV pixel under the mouse, while the debugger's open.
    var hoveredPixel: (x: Int, y: Int)?

    /// What's under the mouse: the screen address it came from.
    var inspection: String? {
        guard let (x, y) = hoveredPixel, debugger.isVisible,
              let metadata = host.frame?.metadata else { return nil }
        let index = (y / 2) * TVOutput.metadataWidth + x / 8
        guard index < metadata.count, let source = VideoSource(metadata: metadata[index]) else {
            return "x \(x), line \(y / 2): blanking"
        }
        let place = source.display ? "&\(hex(source.address, 4))" + (source.teletext ? "" : ", raster \(source.raster)") : "border"
        return "x \(x), line \(y / 2): \(place)"
    }

    /// The machine's indicator lights, refreshed a few times a second.
    private(set) var lights = BBCMicro.Lights()
    @ObservationIgnored private var lightsTimer: MainTimer?

    /// A standalone machine, set up as the last one was.
    convenience init() {
        let defaults = UserDefaults.standard
        let setup = MachineSetup(
            model: defaults.string(forKey: Self.modelDefaultsKey).flatMap(BBCMicro.Model.init(rawValue:)) ?? .modelB,
            secondProcessor: defaults.bool(forKey: Self.secondProcessorDefaultsKey),
            coprocessor: defaults.string(forKey: Self.coprocessorDefaultsKey).flatMap(BBCMicro.Coprocessor.init(rawValue:)) ?? .mos6502,
            discInterface: defaults.string(forKey: Self.discInterfaceDefaultsKey)
                .flatMap(BBCMicro.DiscInterface.init(rawValue:)) ?? .intel8271,
            expansions: Self.savedExpansions, powerOnImagePaths: Self.savedPowerOnImagePaths,
            controllerROMPaths: Self.savedControllerROMPaths, videoNuLA: Self.savedVideoNuLA,
            sockets: Self.savedSockets)
        let discDriveSounds = defaults.object(forKey: Self.discDriveSoundsDefaultsKey) as? Bool ?? true
        let configuration = setup.configuration()
        let host = EmulatorHost(discDriveSounds: Self.discDriveSounds(for:), discDriveSoundsOn: discDriveSounds) {
            BBCMicro(configuration: configuration)
        }
        // A printer on its printer port, for *FX5,1 and VDU 2.
        host.printerName = setup.model.displayName
        host.printJobs = PrintCentre.receiver()
        self.init(setup: setup, host: host, discDriveSounds: discDriveSounds, station: nil)
    }

    /// A network's station, which its network runs (already set up as
    /// `setup`).
    convenience init(station id: UUID, host: EmulatorHost, setup: MachineSetup, owner: StationOwner) {
        self.init(setup: setup, host: host, discDriveSounds: false, station: (id, owner))
    }

    private init(setup: MachineSetup, host: EmulatorHost, discDriveSounds: Bool, station: (UUID, StationOwner)?) {
        model = setup.model
        secondProcessor = setup.secondProcessor
        coprocessor = setup.coprocessor
        discInterface = setup.discInterface
        expansions = setup.expansions
        powerOnImagePaths = setup.powerOnImagePaths
        controllerROMPaths = setup.controllerROMPaths
        videoNuLA = setup.videoNuLA
        sockets = setup.sockets
        self.discDriveSounds = discDriveSounds
        self.host = host
        stationID = station?.0
        self.station = station?.1
        audio = AudioOutput(host: host)
        if station == nil {
            host.start()
            audio.start()
            audible = true
            if Joysticks.shared.machine == nil {
                Joysticks.shared.machine = self
            }
        }
        startupDiscName = setup.configuration().startupDisc?.name
        discNames[0] = startupDiscName
        lightsTimer = MainTimer.repeating(every: 1.0 / 15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.consoleTick += 1
                if self.watchesConsole && self.consoleTick % 15 == 0 {
                    self.readConsole()
                }
                let lights = self.host.lights
                if lights != self.lights {
                    self.lights = lights
                }
                let held = self.host.isHeldForAgent
                if held != self.heldForAgent {
                    self.heldForAgent = held
                }
                let stop = self.host.debugStop
                if stop != self.debugStop {
                    self.debugStop = stop
                    if stop != nil {
                        self.debuggerRequested = true
                        self.debugger.refresh()
                    }
                }
            }
        }
        Self.all[id] = self
        // A station is its network's: the agent server, documentation
        // captures, self-tests and the Game Library use standalone machines.
        guard station == nil else { return }
        startAgentServer()
        DocumentationCapture.start(for: self)
        if Self.frontmost == nil {
            Self.frontmost = self
        }
        runSelfTestIfRequested()
    }

    // MARK: Stations

    private func readConsole() {
        Task {
            let line = try? await host.performAsync { session in
                session.machine.screenText().map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            }
            if let line, line != consoleLine {
                consoleLine = line
            }
        }
    }

    /// The hardware as set up now.
    var setup: MachineSetup {
        MachineSetup(model: model, secondProcessor: secondProcessor, coprocessor: coprocessor, discInterface: discInterface,
                     expansions: expansions, powerOnImagePaths: powerOnImagePaths, controllerROMPaths: controllerROMPaths,
                     videoNuLA: videoNuLA, sockets: sockets)
    }

    /// Where the machine's ROMs come from.
    var romSource: ROMSource { station?.romSource ?? .library }

    /// Remembers a hardware choice: in the app's defaults for a standalone
    /// machine (new windows start with it), or in a station's network.
    func remember(_ value: Any?, forKey key: String) {
        if let station {
            station.stationSetupChanged(self)
        } else if stationID == nil {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// Plays or silences a station's sound (a standalone machine's always
    /// plays).
    func setAudible(_ on: Bool) {
        guard isStation, on != audible else { return }
        audible = on
        if on {
            audio.start()
        } else {
            audio.stop()
        }
    }

    /// The station's machine has gone (switched off, or its network
    /// closed): stop watching it.
    func detachFromNetwork() {
        setAudible(false)
        lightsTimer?.invalidate()
        lightsTimer = nil
        Self.all[id] = nil
    }

    /// The first window's machine is the one `macbeeb-mcp --attach` drives.
    private static var agentServer: AgentSocketServer?
    /// Whether this is that machine.
    private(set) var servesAgents = false

    /// The standalone machine agents drive when they don't name one.
    static weak var agentDefault: MachineController?

    private func startAgentServer() {
        if Self.agentDefault == nil {
            Self.agentDefault = self
            startDebugAdapter()
        }
        if Self.startAgentServerIfNeeded() && Self.agentDefault === self {
            servesAgents = true
        }
    }

    /// Starts the socket `macbeeb-mcp --attach` talks to, once: for the
    /// first standalone window, or a network if that comes first. Returns
    /// whether it's serving.
    @discardableResult
    static func startAgentServerIfNeeded() -> Bool {
        // Self-tests leave a running copy's servers alone.
        guard agentServer == nil, UserDefaults.standard.string(forKey: "MacBeebSelfTest") == nil,
              NetworkSelfTest.path == nil else { return agentServer != nil }
        let tools = AgentTools(defaultContext: {
            DispatchQueue.main.sync { MainActor.assumeIsolated { MachineController.agentDefault?.host } }
        }, directory: AppMachineDirectory())
        let server = AgentSocketServer(tools: LoggedTools(tools: tools))
        server.onConnection = { connected in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentLog.shared.add(connected ? .connected : .disconnected)
                    // The last agent's gone: don't leave machines held.
                    if !connected && AgentLog.shared.connections == 0 {
                        for controller in MachineController.all.values {
                            controller.host.setHeldForAgent(false)
                        }
                    }
                }
            }
        }
        do {
            try server.start()
            agentServer = server
            agentDefault?.servesAgents = true
            AgentLog.shared.serverState = .serving
        } catch AgentSocketServer.StartError.inUse {
            AgentLog.shared.serverState = .inUse
        } catch {
            NSLog("MacBeeb: no agent socket: \(error)")
            AgentLog.shared.serverState = .failed(error.localizedDescription)
        }
        return agentServer != nil
    }

    /// The first window's machine is the one DAP clients (VS Code) debug.
    private static var debugAdapter: DAPServer?
    static let debugAdapterEnabledKey = "MacBeebDebugAdapterEnabled"
    static let debugAdapterPortKey = "MacBeebDebugAdapterPort"

    private func startDebugAdapter() {
        let defaults = UserDefaults.standard
        guard Self.debugAdapter == nil, defaults.object(forKey: Self.debugAdapterEnabledKey) as? Bool ?? true else { return }
        let port = UInt16(exactly: defaults.integer(forKey: Self.debugAdapterPortKey)).flatMap { $0 == 0 ? nil : $0 } ?? DAPServer.defaultPort
        let server = DAPServer(host: host, port: port) { [weak self] model, secondProcessor in
            Task { @MainActor in self?.setHardware(model: model, secondProcessor: secondProcessor) }
        }
        do {
            try server.start()
            Self.debugAdapter = server
        } catch {
            NSLog("MacBeeb: no debug adapter on port \(port): \(error)")
        }
    }

    // MARK: Disc drive sounds

    private static let discDriveSoundsDefaultsKey = "MacBeebDiscDriveSounds"
    /// Whether the drives are heard (on unless turned off).
    private(set) var discDriveSounds: Bool

    func setDiscDriveSounds(_ on: Bool) {
        discDriveSounds = on
        remember(on, forKey: Self.discDriveSoundsDefaultsKey)
        host.send(.setDiscDriveSounds(on))
    }

    /// Read once for each drive type, for every machine.
    nonisolated private static let sounds525 = BeebROMs.discDriveSounds(for: .modelB)
    nonisolated private static let sounds35 = BeebROMs.discDriveSounds(for: .masterCompact)

    nonisolated static func discDriveSounds(for model: BBCMicro.Model) -> DiscDriveSounds? {
        model == .masterCompact ? sounds35 : sounds525
    }

    // MARK: Zoom

    static let zoomLevels: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// The picture's zoom, as the window's size has it.
    @ObservationIgnored private var currentZoom = 1.0
    /// The zoom level the window's at, if it's at one (to within 1%).
    private(set) var zoom: Double? = 1

    func pictureZoomed(_ zoom: Double) {
        currentZoom = zoom
        let level = Self.zoomLevels.first { abs($0 - zoom) < 0.01 * $0 }
        if level != self.zoom {
            self.zoom = level
        }
    }

    func setZoom(_ zoom: Double) {
        NotificationCenter.default.post(name: MachineWindowEvent.setZoom, object: host, userInfo: ["zoom": zoom])
    }

    /// The next level up (or down) from the zoom now.
    func zoom(in zoomIn: Bool) {
        let next = zoomIn ? Self.zoomLevels.first { $0 > currentZoom * 1.01 } : Self.zoomLevels.last { $0 < currentZoom * 0.99 }
        if let next { setZoom(next) }
    }

    /// Hands the Mac's mouse to the BBC's AMX mouse, or takes it back.
    func toggleMouseCapture() {
        NotificationCenter.default.post(name: MachineWindowEvent.toggleMouseCapture, object: host)
    }

    func powerCycle() {
        // An empty drive 0 gets the system disc back.
        if discNames[0] == nil {
            discNames[0] = startupDiscName
        }
        host.send(.powerCycle)
    }

    // MARK: Rewind

    /// Shows the rewind timeline.
    var showingTimeline = false

    /// Goes back `seconds` of emulated time (as far as the history goes).
    func rewind(seconds: Double) {
        host.send(.perform { session in
            let m = session.machine
            guard let earliest = m.rewinder?.earliestCycle else { return }
            let back = UInt64(seconds * 2_000_000)
            Self.seek(session, to: m.cycles > earliest + back ? m.cycles - back : earliest)
        })
    }

    /// Seeks to a frame before `cycle` and runs up to it, so the TV has
    /// drawn the picture (even when paused).
    nonisolated static func seek(_ session: MachineSession, to cycle: UInt64) {
        guard let rewinder = session.machine.rewinder, let earliest = rewinder.earliestCycle else { return }
        let start = max(earliest, cycle > 40_000 ? cycle - 40_000 : 0)
        try? rewinder.seek(to: start)
        let m = session.machine
        if cycle > m.cycles {
            session.advance(cycles: Int(cycle - m.cycles))
        }
    }

    /// The rewind history's points: their cycles, and the current cycle.
    func rewindPoints() async -> (points: [UInt64], now: UInt64) {
        (try? await host.performAsync { session in
            (session.machine.rewinder?.points.map(\.cycle) ?? [], session.machine.cycles)
        }) ?? ([], 0)
    }

    /// A rewind point's thumbnail's pixels (0x00RRGGBB,
    /// `Rewinder.thumbnailWidth` x `Rewinder.thumbnailHeight`), if it has
    /// one.
    func rewindThumbnailPixels(_ index: Int) async -> [UInt32]? {
        let pixels = try? await host.performAsync { session -> [UInt32] in
            let points = session.machine.rewinder?.points ?? []
            return points.indices.contains(index) ? points[index].thumbnail : []
        }
        guard let pixels, pixels.count == Rewinder.thumbnailWidth * Rewinder.thumbnailHeight else { return nil }
        return pixels
    }

    func seek(to cycle: UInt64) {
        host.send(.perform { Self.seek($0, to: cycle) })
    }

    /// Pauses (or unpauses) without the menu's toggle.
    func setPaused(_ value: Bool) {
        paused = value
        host.send(.setPaused(value))
    }

    /// Switches model, which power cycles. Discs stay in the drives.
    func setModel(_ newModel: BBCMicro.Model) {
        guard newModel != model else { return }
        model = newModel
        remember(newModel.rawValue, forKey: Self.modelDefaultsKey)
        changeMachine()
    }

    /// Takes on a model and remembers it, without restarting.
    func takeModel(_ newModel: BBCMicro.Model) {
        model = newModel
        remember(newModel.rawValue, forKey: Self.modelDefaultsKey)
    }

    /// Sets the machine up as `new` (a saved machine), in one power cycle.
    func use(_ new: MachineSetup) {
        guard new != setup else { return }
        model = new.model
        secondProcessor = new.secondProcessor
        coprocessor = new.coprocessor
        discInterface = new.discInterface
        remember(model.rawValue, forKey: Self.modelDefaultsKey)
        remember(secondProcessor, forKey: Self.secondProcessorDefaultsKey)
        remember(coprocessor.rawValue, forKey: Self.coprocessorDefaultsKey)
        remember(discInterface.rawValue, forKey: Self.discInterfaceDefaultsKey)
        rememberHardware(expansions: new.expansions, powerOnImagePaths: new.powerOnImagePaths,
                         controllerROMPaths: new.controllerROMPaths, videoNuLA: new.videoNuLA, sockets: new.sockets)
        changeMachine()
    }

    /// Switches model and second processor at once (one power cycle).
    func setHardware(model newModel: BBCMicro.Model, secondProcessor fitted: Bool) {
        guard newModel != model || fitted != secondProcessor else { return }
        model = newModel
        secondProcessor = fitted
        remember(newModel.rawValue, forKey: Self.modelDefaultsKey)
        remember(fitted, forKey: Self.secondProcessorDefaultsKey)
        changeMachine()
    }

    /// Changes the Model B's disc interface, which power cycles.
    func setDiscInterface(_ interface: BBCMicro.DiscInterface) {
        guard interface != discInterface else { return }
        discInterface = interface
        remember(interface.rawValue, forKey: Self.discInterfaceDefaultsKey)
        if model == .modelB {
            changeMachine()
        }
    }

    /// Fits a second processor (nil removes it), which power cycles.
    func setCoprocessor(_ new: BBCMicro.Coprocessor?) {
        guard new != fittedCoprocessor else { return }
        secondProcessor = new != nil
        if let new { coprocessor = new }
        remember(secondProcessor, forKey: Self.secondProcessorDefaultsKey)
        remember(coprocessor.rawValue, forKey: Self.coprocessorDefaultsKey)
        changeMachine()
    }

    /// Fits or removes the 6502 Second Processor, which power cycles.
    func setSecondProcessor(_ fitted: Bool) {
        guard fitted != secondProcessor else { return }
        secondProcessor = fitted
        remember(fitted, forKey: Self.secondProcessorDefaultsKey)
        changeMachine()
    }

    // For the hardware extension (another file).
    func setExpansionsValue(_ new: BBCMicro.Expansions) { expansions = new }
    func setPowerOnImagePathsValue(_ new: [Int: String]) { powerOnImagePaths = new }
    func setControllerROMPathsValue(_ new: [BBCMicro.MemoryBoard: String]) { controllerROMPaths = new }
    func setVideoNuLAValue(_ new: Bool) { videoNuLA = new }
    func setSocketsValue(_ new: SocketSetup) { sockets = new }
    func noteHardwareChanged() { hardwareChanges += 1 }
    /// Power cycles into the hardware as now set.
    func restartWithHardware() { changeMachine() }

    private func changeMachine() {
        let configuration = setup.configuration(econetStation: station?.stationNumber(self), roms: romSource)
        hardwareChanges += 1
        // As BBCMicro.insertDiscs: an empty drive 0, or one with the old
        // machine's system disc, gets the new machine's.
        let startup = configuration.startupDisc?.name
        if discNames[0] == nil || discNames[0] == startupDiscName {
            discNames[0] = startup
        }
        startupDiscName = startup
        host.send(.changeMachine(configuration))
    }

    func togglePause() {
        if heldForAgent && !paused {
            host.setHeldForAgent(false)
            heldForAgent = false
            return
        }
        paused.toggle()
        host.send(.setPaused(paused))
    }

    func toggleSpeedLimit() {
        speedLimited.toggle()
        host.send(.setSpeedLimited(speedLimited))
    }

    /// Pastes the clipboard's text into the BBC as if typed (fast).
    func pasteText() {
        let host = host
        Platform.readClipboardText { text in
            // Mac line endings become Return.
            host.send(.paste(text.replacingOccurrences(of: "\r\n", with: "\n")))
        }
    }

    func screenshotPNG() -> Data? {
        guard let frame = host.frame else { return nil }
        return Screenshot.png(pixels: frame.pixels, width: EmulatorHost.Frame.width, height: EmulatorHost.Frame.height)
    }

    func copyScreenshot() {
        guard let png = screenshotPNG() else { return }
        Platform.copyToClipboard(png: png)
    }

    func saveScreenshot() {
        guard let png = screenshotPNG() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        Platform.chooseSaveLocation(.png, suggestedName: "BBC Micro \(formatter.string(from: Date())).png", message: nil) { url in
            guard let url else { return }
            do {
                try png.write(to: url)
            } catch {
                Platform.showError(error)
            }
        }
    }

    /// Disc images the BBC has in its drives, by drive.
    private(set) var discNames: [Int: String] = [:]

    /// A network put a disc in this station's drive as it switched it on.
    func noteNetworkDisc(_ name: String, drive: Int) {
        discNames[drive] = name
    }
    /// The path of the disc image file in drive 0 (not a bundled disc's),
    /// whose own keys apply.
    private(set) var bootDiscPath: String?
    /// The bundled system disc the machine starts with (the Z80's CP/M,
    /// the Master 512's DOS Plus), if any.
    @ObservationIgnored private var startupDiscName: String?

    /// Who the discs in the drives are, for quick saves, by drive.
    private(set) var driveMedia: [Int: DiscMedia] = [:]
    /// The quick saves of the disc that owns them now, newest first.
    private(set) var snapshotHistory: [SnapshotManifest] = []
    /// A quick save or load is under way.
    private(set) var snapshotBusy = false
    /// A brief message over the picture ("Snapshot saved · 3 of 5").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// The machine whose window was in front last: the bookshelf plays
    /// games in it.
    static weak var frontmost: MachineController?
    /// What a new machine window does when it opens (the bookshelf opens
    /// one to play a game in, when there isn't one).
    static var pendingLaunch: ((MachineController) -> Void)?

    /// Asks for a disc image, puts it in `drive`, and (for drive 0, if
    /// `boot`) Shift-Breaks to boot it.
    // MARK: Tape

    private(set) var tapeName: String?

    func openTape() {
        Platform.chooseFiles(.tapes, multiple: false, message: nil) { urls in
            guard let url = urls.first else { return }
            self.insertTape(url)
        }
    }

    /// Puts a tape in the recorder and, with `load`, types *TAPE and
    /// CHAIN "" to load its first program.
    func insertTape(_ url: URL, load: Bool = true) {
        let image: [UInt8]
        do {
            image = [UInt8](try Data(contentsOf: url))
            _ = try Tape(image: image)
        } catch {
            Platform.showError(error)
            return
        }
        host.send(.perform { session in
            session.machine.insertTape(try? Tape(image: image))
            if load {
                session.machine.paste("*TAPE\nCHAIN \"\"\n")
            }
        })
        tapeName = url.lastPathComponent
        Platform.noteRecentDocument(url)
    }

    /// A BASIC program file (text or tokenised), dropped or opened: loaded
    /// at PAGE and RUN, as CHAIN would, if BASIC is at its prompt.
    func runBASICProgram(_ url: URL) {
        let program: [UInt8]
        do {
            program = try BasicDebugger.program(fromFile: [UInt8](Data(contentsOf: url)))
        } catch {
            Platform.showError(error)
            return
        }
        let name = url.lastPathComponent
        Task {
            let problem: String?
            do {
                problem = try await host.performAsync { session -> String? in
                    do {
                        try session.machine.debugger.basic.loadAtPrompt(program)
                        session.machine.paste("RUN\n")
                        return nil
                    } catch {
                        return "\(error)"
                    }
                }
            } catch {
                problem = "\(error)"
            }
            if let problem {
                showToast("Can't run \(name): \(problem)")
            } else {
                showToast("Running \(name)")
                if !LaunchScreen.isSelfTest {
                    Platform.noteRecentDocument(url)
                }
            }
        }
    }

    func rewindTape() {
        host.send(.perform { $0.machine.rewindTape() })
    }

    func ejectTape() {
        host.send(.perform { $0.machine.insertTape(nil) })
        tapeName = nil
    }

    // MARK: Discs

    func openDisc(drive: Int = 0, boot: Bool = true) {
        Platform.chooseFiles(.discs, multiple: false, message: nil) { urls in
            guard let url = urls.first else { return }
            self.insertDisc(url, drive: drive, boot: boot)
        }
    }

    /// File > New Disc…: saves a blank, formatted disc image where the user
    /// says, and puts it in the drive they choose (without booting it:
    /// there's nothing on it to boot).
    ///
    /// `drive`: the drive to offer to put it in, rather than the first
    /// empty one.
    func newDisc(drive: Int? = nil) {
        let empty = drive.map { [$0] } ?? [0, 1].filter { discNames[$0] == nil }
        NewDiscPanel(model: model, emptyDrives: empty).present { choice in
            guard let choice else { return }
            do {
                try Data(choice.kind.image(title: choice.title)).write(to: choice.url, options: .atomic)
            } catch {
                Platform.showError(error)
                return
            }
            if let drive = choice.drive {
                self.insertDisc(choice.url, drive: drive, boot: false)
            } else {
                RecentDiscs.shared.add(choice.url)
            }
        }
    }

    /// Opens and boots a disc from File > Open Recent Disc, or says it's
    /// gone (and forgets it).
    func openRecentDisc(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            RecentDiscs.shared.remove(url)
            Platform.showAlert(title: "“\(url.lastPathComponent)” can’t be found",
                               message: "It may have been moved, renamed or deleted, so it’s been taken off the list.")
            return
        }
        insertDisc(url)
    }

    /// Puts the disc image at `url` in `drive`. Writes go back to the file.
    ///
    /// `media`: who the disc is, for quick saves (a library game's disc);
    /// otherwise it's looked up, or registered, by its file.
    func insertDisc(_ url: URL, drive: Int = 0, boot: Bool = true, media: DiscMedia? = nil) {
        // A station uses its network's copy.
        let original = url
        var url = url
        if let station {
            guard let copy = station.station(self, willInsert: url, drive: drive) else { return }
            url = copy
        }
        guard let data = try? Data(contentsOf: url) else {
            Platform.showError(CocoaError(.fileReadUnknown))
            return
        }
        let format = Disc.ImageFormat(path: url.path) ?? .ssd
        let media = media ?? DiscMedia(id: ClassicsLibrary.shared.media.identity(forFileAt: url, digest: GameLibrary.sha256(data)),
                                       name: url.lastPathComponent, gameID: nil, managed: false)
        host.send(.insertDisc(image: [UInt8](data), format: format, drive: drive,
                              onWrite: writeBack(to: url, media: media).onWrite))
        discChanges += 1
        discNames[drive] = media.name
        setMedia(media, drive: drive)
        if drive == 0 {
            bootDiscPath = url.standardizedFileURL.path
        }
        // Library discs are reached through the bookshelf.
        if !media.managed {
            Platform.noteRecentDocument(original)
            RecentDiscs.shared.add(original)
        }
        if boot && drive == 0 {
            host.send(.shiftBreak)
        }
    }

    /// Writing a disc back to its file, as the BBC writes to it.
    private func writeBack(to url: URL, media: DiscMedia) -> EmulatorHost.WriteBack {
        let format = Disc.ImageFormat(path: url.path) ?? .ssd
        let writable = FileManager.default.isWritableFile(atPath: url.path)
        let noteWrite = noteDiscWrite
        let registry = ClassicsLibrary.shared.media
        return EmulatorHost.WriteBack(format: format) { bytes in
            if writable {
                DispatchQueue.global(qos: .utility).async {
                    let data = Data(bytes)
                    try? data.write(to: url, options: .atomic)
                    if !media.managed {
                        registry.noteWritten(id: media.id, digest: GameLibrary.sha256(data))
                    }
                }
            }
            noteWrite()
        }
    }

    /// Tells the disc contents window, from any thread, that a disc's
    /// been written to.
    private var noteDiscWrite: @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor in self?.discChanges += 1 }
        }
    }

    /// Puts one of the bundled discs in `drive`. Writes stay in memory.
    func insertBundledDisc(_ disc: BeebROMs.BundledDisc, drive: Int) {
        let noteWrite = noteDiscWrite
        host.send(.insertDisc(image: disc.data, format: disc.format, drive: drive, onWrite: { _ in noteWrite() }))
        discChanges += 1
        discNames[drive] = disc.rawValue
        setMedia(nil, drive: drive)
        if drive == 0 {
            bootDiscPath = nil
        }
    }

    func ejectDisc(drive: Int) {
        host.send(.insertDisc(image: nil, format: .ssd, drive: drive, onWrite: nil))
        station?.station(self, didEject: drive)
        discChanges += 1
        discNames[drive] = nil
        setMedia(nil, drive: drive)
        if drive == 0 {
            bootDiscPath = nil
        }
    }

    func shiftBreak() {
        host.send(.shiftBreak)
    }

    /// Ctrl-Break: a hard reset that keeps memory (the OS scans the
    /// sideways ROMs afresh).
    func ctrlBreak() {
        host.send(.perform { $0.machine.ctrlBreak() })
    }

    private(set) var recordingURL: URL?

    /// Starts recording to a movie the user picks, or stops.
    func toggleRecording() {
        if recordingURL != nil {
            host.send(.stopRecording { error in
                Task { @MainActor in
                    if let error {
                        Platform.showError(error)
                    }
                }
            })
            recordingURL = nil
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        Platform.chooseSaveLocation(.movie, suggestedName: "BBC Micro \(formatter.string(from: Date())).mp4", message: nil) { url in
            guard let url else { return }
            let codec: VideoRecorder.Codec = url.pathExtension.lowercased() == "mov" ? .proRes : .h264
            self.host.send(.startRecording(url, codec))
            self.recordingURL = url
        }
    }

    func saveState() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "BBC Micro \(formatter.string(from: Date())).\(SaveStateFile.fileExtension)"
        Platform.chooseSaveLocation(.saveState, suggestedName: name, message: nil) { url in
            guard let url else { return }
            self.host.send(.saveState(url) { error in
                guard let error else { return }
                Task { @MainActor in Platform.showError(error) }
            })
        }
    }

    func loadState() {
        Platform.chooseFiles(.saveState, multiple: false, message: nil) { urls in
            guard let url = urls.first else { return }
            self.loadState(url)
        }
    }

    func loadState(_ url: URL) {
        do {
            let file = try SaveStateFile(data: Data(contentsOf: url))
            host.send(.loadState(file))
            model = file.configuration.model
            secondProcessor = file.configuration.secondProcessorROM != nil
            coprocessor = file.configuration.coprocessor
            discInterface = file.configuration.discInterface
            expansions = file.configuration.expansions
            videoNuLA = file.configuration.videoNuLA
            hardwareChanges += 1
            discNames = [:]
            driveMedia = [:]
            refreshSnapshotHistory()
            discChanges += 1
            bootDiscPath = nil
            startupDiscName = nil
            tapeName = file.snapshot.hasTape ? "Tape" : nil
            Platform.noteRecentDocument(url)
        } catch {
            Platform.showError(error)
        }
    }

    func pressBreak() {
        host.send(.pressBreak)
    }
}

/// A disc image's identity, for quick saves: a library game's disc, or a
/// disc file registered by MediaRegistry.
struct DiscMedia: Equatable, Sendable {
    var id: UUID
    var name: String
    /// The curated game, for a library disc.
    var gameID: String?
    /// Whether it's a library disc, whose file follows a restored state.
    var managed: Bool
}

// MARK: Classics and quick saves

extension MachineController {
    /// The disc whose quick saves these are: drive 0's, or drive 1's if
    /// drive 0 has none.
    var snapshotOwner: DiscMedia? {
        driveMedia[0] ?? driveMedia[1]
    }

    private func setMedia(_ media: DiscMedia?, drive: Int) {
        let owner = snapshotOwner
        driveMedia[drive] = media
        if snapshotOwner != owner {
            refreshSnapshotHistory()
        }
    }

    func refreshSnapshotHistory() {
        guard let owner = snapshotOwner else {
            snapshotHistory = []
            return
        }
        Task {
            let history = await ClassicsLibrary.shared.snapshots.history(owner: owner.id)
            if snapshotOwner?.id == owner.id {
                snapshotHistory = history
            }
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    /// Whether the machine has a disc of the user's in it, which playing
    /// something else would take out.
    var isPlayingSomething: Bool {
        guard let name = discNames[0] else { return false }
        return name != startupDiscName
    }

    /// Plays a library game: sets the machine up as the game needs (a
    /// power cycle), puts its disc in drive 0 and boots it.
    func play(_ game: CuratedGame, disc url: URL, record: InstalledGame) {
        let requirement = game.machine
        model = requirement.model
        // The games were checked on the standard 8271 interface, with no
        // expansion board.
        discInterface = .intel8271
        expansions = .none
        videoNuLA = false
        secondProcessor = requirement.coprocessor != nil
        if let coprocessor = requirement.coprocessor {
            self.coprocessor = coprocessor
        }
        // Always a fresh machine, even if it's the same one.
        changeMachine()
        insertDisc(url, drive: 0, boot: true,
                   media: DiscMedia(id: record.libraryID, name: game.title, gameID: game.id, managed: true))
        NotificationCenter.default.post(name: MachineWindowEvent.bringToFront, object: host)
    }

    /// Plays one of My Games on the machine the user chose for it,
    /// starting it as they said.
    func play(_ game: PersonalGame, disc url: URL) {
        model = game.model
        secondProcessor = game.coprocessor != nil
        if let coprocessor = game.coprocessor {
            self.coprocessor = coprocessor
        }
        changeMachine()
        let media = DiscMedia(id: game.id, name: game.title, gameID: nil, managed: true)
        switch game.start {
        case .boot:
            insertDisc(url, drive: 0, boot: true, media: media)
        case .insertOnly:
            insertDisc(url, drive: 0, boot: false, media: media)
        case .type(let command):
            insertDisc(url, drive: 0, boot: false, media: media)
            let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty {
                // Once the machine's at its prompt.
                let host = host
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    host.send(.paste(command + "\n"))
                }
            }
        }
        NotificationCenter.default.post(name: MachineWindowEvent.bringToFront, object: host)
    }

    /// Takes a snapshot of the machine and its discs, for the disc in the
    /// drive.
    func quickSave() {
        guard let owner = snapshotOwner else {
            showToast("Put a disc in to quick save")
            return
        }
        guard !snapshotBusy else { return }
        snapshotBusy = true
        let drives = discNames.keys.sorted().map { drive in
            let media = driveMedia[drive]
            return SnapshotManifest.DriveMedia(drive: drive, media: media?.id, name: discNames[drive] ?? "",
                                               managed: media?.managed ?? false)
        }
        let manifest = SnapshotManifest(owner: owner.id, gameID: owner.gameID, title: owner.name, model: model,
                                        coprocessor: fittedCoprocessor, drives: drives)
        Task {
            defer { snapshotBusy = false }
            do {
                // One consistent capture, between slices on the emulation
                // thread; everything else happens off it.
                let (state, frame) = try await host.performAsync { session in
                    (SaveStateFile(session.machine), session.tv.lastFrame)
                }
                let thumbnail = await Task.detached {
                    Screenshot.png(pixels: frame, width: EmulatorHost.Frame.width, height: EmulatorHost.Frame.height)
                }.value
                let history = try await ClassicsLibrary.shared.snapshots.save(state, thumbnailPNG: thumbnail, manifest: manifest)
                if snapshotOwner?.id == owner.id {
                    snapshotHistory = history
                }
                ClassicsLibrary.shared.noteSnapshotsChanged()
                showToast("Snapshot saved · \(history.count) of \(ClassicsLibrary.shared.snapshots.limit)")
            } catch {
                showToast("Couldn’t save a snapshot")
                Platform.showError(error)
            }
        }
    }

    /// Restores a snapshot (the newest of the current disc's, by default).
    /// It's checked before the running machine is touched.
    func quickLoad(_ chosen: SnapshotManifest? = nil) {
        guard let manifest = chosen ?? snapshotHistory.first else {
            showToast("No snapshots yet")
            return
        }
        guard !snapshotBusy else { return }
        snapshotBusy = true
        let library = ClassicsLibrary.shared
        Task {
            defer { snapshotBusy = false }
            do {
                let file = try await library.snapshots.load(manifest)
                // Library discs' files follow the restored discs.
                var writeBacks: [Int: EmulatorHost.WriteBack] = [:]
                var restoredMedia: [Int: DiscMedia] = [:]
                var paths: [Int: URL] = [:]
                for drive in manifest.drives {
                    guard let id = drive.media else { continue }
                    // (Drives without one held bundled discs.)
                    var media = DiscMedia(id: id, name: drive.name, gameID: nil, managed: drive.managed)
                    if drive.managed, let disc = await library.managedDisc(id: id) {
                        media.gameID = disc.gameID
                        writeBacks[drive.drive] = writeBack(to: disc.url, media: media)
                        paths[drive.drive] = disc.url
                    } else if !drive.managed, let record = library.media.record(id: id) {
                        // Files outside the library aren't overwritten
                        // with older contents: the restored disc stays in
                        // memory.
                        paths[drive.drive] = URL(fileURLWithPath: record.path)
                    }
                    restoredMedia[drive.drive] = media
                }
                let error: Error? = await withCheckedContinuation { continuation in
                    host.send(.restoreState(file, writeBacks: writeBacks, completion: { continuation.resume(returning: $0) }))
                }
                if let error { throw error }
                model = file.configuration.model
                secondProcessor = file.configuration.secondProcessorROM != nil
                coprocessor = file.configuration.coprocessor
                discInterface = file.configuration.discInterface
                expansions = file.configuration.expansions
                videoNuLA = file.configuration.videoNuLA
                hardwareChanges += 1
                startupDiscName = nil
                discNames = Dictionary(uniqueKeysWithValues: manifest.drives.map { ($0.drive, $0.name) })
                driveMedia = restoredMedia
                bootDiscPath = paths[0]?.standardizedFileURL.path
                tapeName = file.snapshot.hasTape ? "Tape" : nil
                discChanges += 1
                NotificationCenter.default.post(name: MachineWindowEvent.resetKeys, object: host)
                snapshotHistory = await library.snapshots.history(owner: manifest.owner)
                showToast("Snapshot restored")
            } catch {
                Platform.showError(error)
            }
        }
    }
}
