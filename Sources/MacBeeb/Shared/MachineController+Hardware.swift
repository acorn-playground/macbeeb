import Foundation
import BeebCore
import BeebHost
import BeebNetwork
import BeebROMs

/// The Model B's expansions: choosing the board (a power cycle), and
/// loading, clearing and saving sideways RAM in the running machine.
extension MachineController {
    /// What the Hardware Expansions window shows of the running machine.
    struct HardwareSnapshot: Sendable, Equatable {
        var model: BBCMicro.Model
        var expansions: BBCMicro.Expansions
        var slots: [BBCMicro.SidewaysSlot]
        var romsel: UInt8
        var watfordMapping: BBCMicro.WatfordMapping?
        var aries: BBCMicro.AriesState?
        var nula: NuLAView?
    }

    /// What the window shows of VideoNuLA.
    struct NuLAView: Sendable, Equatable {
        var colours: [UInt16]
        var flashing: [Bool]
        var direct: Bool
        var disabled: Bool
        var offset: UInt8
        var blanking: UInt8

        init(_ n: VideoNuLA) {
            colours = (0..<16).map { n.outputPalette[$0] }
            flashing = (0..<16).map { n.flash[$0] }
            direct = n.directPalette
            disabled = n.disableA1
            offset = n.scrollOffset
            blanking = n.blankingSize
        }
    }

    /// The hardware being chosen in the Hardware Expansions window: the
    /// board, and any controller ROMs in place of the bundled ones.
    struct HardwareDraft: Equatable {
        var model: BBCMicro.Model
        var expansions: BBCMicro.Expansions
        var controllerROMPaths: [BBCMicro.MemoryBoard: String]
        var videoNuLA: Bool
        var sockets: SocketSetup

        /// The controller ROM the board would use.
        var controllerROMPath: String? { controllerROMPaths[expansions.board] }
    }

    var hardwareDraft: HardwareDraft {
        HardwareDraft(model: model, expansions: expansions, controllerROMPaths: controllerROMPaths, videoNuLA: videoNuLA, sockets: sockets)
    }

    static var savedExpansions: BBCMicro.Expansions {
        guard let data = UserDefaults.standard.data(forKey: expansionsKey),
              let saved = try? JSONDecoder().decode(BBCMicro.Expansions.self, from: data),
              saved.problem == nil else { return .none }
        return saved
    }

    static var savedPowerOnImagePaths: [Int: String] {
        guard let saved = UserDefaults.standard.dictionary(forKey: powerOnImagesKey) as? [String: String] else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, path in Int(key).map { ($0, path) } })
    }

    static var savedSockets: SocketSetup {
        guard let data = UserDefaults.standard.data(forKey: socketsKey),
              let saved = try? JSONDecoder().decode(SocketSetup.self, from: data) else { return .standard }
        return saved
    }

    static var savedVideoNuLA: Bool {
        UserDefaults.standard.bool(forKey: videoNuLAKey)
    }

    static var savedControllerROMPaths: [BBCMicro.MemoryBoard: String] {
        guard let saved = UserDefaults.standard.dictionary(forKey: controllerROMsKey) as? [String: String] else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, path in BBCMicro.MemoryBoard(rawValue: key).map { ($0, path) } })
    }

    private static let expansionsKey = "MacBeebExpansions"
    private static let controllerROMsKey = "MacBeebControllerROMs"
    private static let videoNuLAKey = "MacBeebVideoNuLA"
    private static let powerOnImagesKey = "MacBeebSidewaysPowerOnImages"
    private static let socketsKey = "MacBeebROMSockets"

    /// Fits a different board (or changes its wiring or controller ROM),
    /// which power cycles a Model B. On other models it's remembered for
    /// when it's a B again.
    func apply(_ draft: HardwareDraft) {
        guard draft != hardwareDraft, draft.expansions.problem == nil else { return }
        let modelChanged = draft.model != model
        if modelChanged { takeModel(draft.model) }
        setExpansionsValue(draft.expansions)
        if let data = try? JSONEncoder().encode(draft.expansions) {
            remember(data, forKey: Self.expansionsKey)
        }
        setControllerROMPathsValue(draft.controllerROMPaths)
        remember(Dictionary(uniqueKeysWithValues: draft.controllerROMPaths.map { ($0.key.rawValue, $0.value) }),
                                  forKey: Self.controllerROMsKey)
        let nulaChanged = draft.videoNuLA != videoNuLA
        setVideoNuLAValue(draft.videoNuLA)
        remember(draft.videoNuLA, forKey: Self.videoNuLAKey)
        let socketsChanged = draft.sockets != sockets
        setSocketsValue(draft.sockets)
        if let data = try? JSONEncoder().encode(draft.sockets) {
            remember(data, forKey: Self.socketsKey)
        }
        // The board matters only on a Model B; NuLA and ROMs on any model.
        if model == .modelB || modelChanged || nulaChanged || socketsChanged {
            restartWithHardware()
        }
    }

    /// Takes on hardware choices and remembers them, without restarting.
    func rememberHardware(expansions: BBCMicro.Expansions, powerOnImagePaths: [Int: String],
                          controllerROMPaths: [BBCMicro.MemoryBoard: String], videoNuLA: Bool, sockets: SocketSetup) {
        setExpansionsValue(expansions)
        if let data = try? JSONEncoder().encode(expansions) { remember(data, forKey: Self.expansionsKey) }
        setPowerOnImagePathsValue(powerOnImagePaths)
        remember(Dictionary(uniqueKeysWithValues: powerOnImagePaths.map { (String($0.key), $0.value) }), forKey: Self.powerOnImagesKey)
        setControllerROMPathsValue(controllerROMPaths)
        remember(Dictionary(uniqueKeysWithValues: controllerROMPaths.map { ($0.key.rawValue, $0.value) }), forKey: Self.controllerROMsKey)
        setVideoNuLAValue(videoNuLA)
        remember(videoNuLA, forKey: Self.videoNuLAKey)
        setSocketsValue(sockets)
        if let data = try? JSONEncoder().encode(sockets) { remember(data, forKey: Self.socketsKey) }
    }

    func setExpansions(_ new: BBCMicro.Expansions) {
        var draft = hardwareDraft
        draft.expansions = new
        apply(draft)
    }

    /// A file to put in a sideways RAM bank at every power on (nil: none).
    /// Takes effect at the next power cycle.
    func setPowerOnImage(_ url: URL?, bank: Int) {
        var paths = powerOnImagePaths
        paths[bank] = url?.path
        setPowerOnImagePathsValue(paths)
        remember(Dictionary(uniqueKeysWithValues: paths.map { (String($0.key), $0.value) }),
                                  forKey: Self.powerOnImagesKey)
    }

    /// The running machine's hardware.
    func hardwareSnapshot() async -> HardwareSnapshot? {
        try? await host.performAsync { session in
            let m = session.machine
            return HardwareSnapshot(model: m.model, expansions: m.configuration.fittedExpansions,
                                    slots: m.sidewaysSlots, romsel: m.romsel,
                                    watfordMapping: m.watfordFitted ? m.watfordMapping : nil,
                                    aries: m.ariesFitted ? m.aries : nil,
                                    nula: m.nula.map(NuLAView.init))
        }
    }

    /// Puts a ROM image file into a sideways RAM bank of the running
    /// machine (the BBC finds it at the next Break).
    func loadSidewaysImage(_ url: URL, bank: Int) async throws {
        let image = [UInt8](try Data(contentsOf: url))
        try await host.performAsync { session in try session.machine.loadSidewaysImage(image, bank: bank) }
        noteHardwareChanged()
        showToast("Loaded \(url.lastPathComponent) into bank \(bank). Press Break for the BBC to find it.")
    }

    func clearSidewaysBank(_ bank: Int) async throws {
        try await host.performAsync { session in try session.machine.clearSidewaysBank(bank) }
        noteHardwareChanged()
        showToast("Cleared bank \(bank)")
    }

    func saveSidewaysBank(_ bank: Int, to url: URL) async throws {
        let contents = try await host.performAsync { session in session.machine.sidewaysBankContents(bank) }
        guard let contents else { return }
        try Data(contents).write(to: url)
    }
}
