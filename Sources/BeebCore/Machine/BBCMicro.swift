#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// BBC Micro Model B and Master 128.
//
// The per-cycle update follows b2's BBCMicro_Update.inl (Copyright (C) Tom
// Seddon, GPLv3).
//
// `step()` runs one 2MHz cycle. Alternate cycles are 1MHz phi2 leading and
// trailing edges. Accesses to 1MHz devices are stretched so the access
// lines up with the 1MHz trailing edge: 1 or 2 extra cycles.
//
// Memory is mapped in 4K pages through two tables, as in b2: one for code
// running in &C000-&DFFF (the Master's VDU driver, which can see shadow RAM
// with ACCCON E) and one for everything else.

public final class BBCMicro {
    public enum Model: String, Codable, Sendable, CaseIterable {
        case modelA
        case modelB
        case bPlus
        case master128
        case masterCompact

        public var displayName: String {
            switch self {
            case .modelA: "BBC Model A"
            case .modelB: "BBC Model B"
            case .bPlus: "BBC Model B+ 128K"
            case .master128: "BBC Master 128"
            case .masterCompact: "BBC Master Compact"
            }
        }

        /// The Master series: 65C12, MOS paging, I/O map and 1770 at &FE24.
        public var isMaster: Bool { self == .master128 || self == .masterCompact }
        /// The Model A and Compact have no Tube or analogue port (ADC); the
        /// Compact no clock or keypad.
        public var hasTube: Bool { self != .masterCompact && self != .modelA }
        public var hasADC: Bool { self != .masterCompact && self != .modelA }
        /// The Model A has 16K of RAM, no user VIA and no disc interface.
        public var hasUserVIA: Bool { self != .modelA }
        public var hasDiscInterface: Bool { self != .modelA }
        /// The B family: the OS 1.20 machines.
        public var isModelBFamily: Bool { self == .modelA || self == .modelB }
        public var hasKeypad: Bool { self == .master128 }
        /// Nor a cassette port.
        public var hasCassette: Bool { self != .masterCompact }
    }

    /// What's on the Tube.
    public enum Coprocessor: String, Codable, Sendable, CaseIterable {
        /// The 6502 Second Processor (3MHz 65C02).
        case mos6502
        /// The Acorn Z80 Second Processor (6MHz, CP/M).
        case z80
        /// The Master 512 (an 80186 with 1MB, for DOS Plus and GEM).
        case master512
        /// The Acorn ARM Second Processor, or ARM Evaluation System (8MHz
        /// ARM1, 4MB).
        case arm
        /// The Master Turbo's 65C102 Co-Processor: a 4MHz 65C02 with 64K,
        /// inside the Master on its internal Tube.
        case masterTurbo

        public var displayName: String {
            switch self {
            case .mos6502: "6502 Second Processor"
            case .z80: "Z80 Second Processor"
            case .master512: "Master 512 (80186)"
            case .arm: "ARM Evaluation System"
            case .masterTurbo: "Master Turbo (65C102)"
            }
        }

        /// Whether it can be fitted to `model`: any of them to a machine
        /// with a Tube, but the Master 512 and the Master Turbo's board
        /// (both inside the Master) only to the Master 128.
        public func fits(_ model: Model) -> Bool {
            model.hasTube && (self != .master512 && self != .masterTurbo || model == .master128)
        }

        /// Whether it's on the Master's internal Tube, which the host sees
        /// while ACCCON's ITU bit is set (the others are on the external
        /// one, as b2 has it).
        public var isInternal: Bool { self == .masterTurbo }
    }

    /// The Model B's disc interface.
    public enum DiscInterface: String, Codable, Sendable, CaseIterable {
        /// The Intel 8271 (Acorn DFS 1.20).
        case intel8271
        /// Acorn's 1770 board (DFS 2.26).
        case acorn1770
        /// Watford's 1770 boards (DDFS 1.53, DDFS 1.54T).
        case watfordDDB2
        case watfordDDB3
        /// Opus's 1770 board (DDOS 3.45).
        case opus

        public var displayName: String {
            switch self {
            case .intel8271: "Intel 8271 (Acorn DFS)"
            case .acorn1770: "Acorn 1770 (DFS 2.26)"
            case .watfordDDB2: "Watford DDB2 (DDFS 1.53)"
            case .watfordDDB3: "Watford DDB3 (DDFS 1.54T)"
            case .opus: "Opus DDOS 1770 (DDOS 3.45)"
            }
        }

        /// The 1770 latch layout, for a 1770 board.
        public var layout: WD1770.ControlLayout? {
            switch self {
            case .intel8271: nil
            case .acorn1770: .acorn1770
            case .watfordDDB2: .watfordDDB2
            case .watfordDDB3: .watfordDDB3
            case .opus: .opus
            }
        }
    }

    public enum IRQDevice {
        public static let systemVIA: UInt8 = 1 << 0
        public static let userVIA: UInt8 = 1 << 1
        /// The Master's ACCCON IRR bit.
        public static let acccon: UInt8 = 1 << 2
        public static let acia: UInt8 = 1 << 3
        public static let tube: UInt8 = 1 << 4
        public static let scsi: UInt8 = 1 << 5
    }

    public enum NMIDevice {
        public static let fdc: UInt8 = 1 << 0
        public static let econet: UInt8 = 1 << 1
    }

    public let model: Model
    public let cpu: M6502
    public var systemVIA = VIA6522()
    public var userVIA = VIA6522()
    public var crtc = CRTC6845()
    public var videoULA = VideoULA()
    /// VideoNuLA, if fitted, beside the Video ULA (whose palette and control
    /// it uses).
    public internal(set) var nula: VideoNuLA?
    public let nulaFitted: Bool
    /// The printer on the printer port, if one's plugged in.
    public var printer: ParallelPrinter?
    /// The Econet module, if fitted.
    public let econet: Econet?
    let econetFitted: Bool
    /// The Acorn SCSI interface on the 1MHz bus, once a hard disc's
    /// attached.
    var scsi: AcornSCSI?
    public var saa5050 = SAA5050()
    public var adc = UPD7002()
    public var soundChip = SN76489()
    /// The two disc drives.
    public let drives = [DiscDrive(id: 0), DiscDrive(id: 1)]
    /// The Model B's disc controller.
    public let intel8271: Intel8271?
    /// The 1770 (the B+'s and Masters', or a board in a Model B).
    public let wd1770: WD1770?
    /// The 1770 board's latch layout, on the B and B+ (at &FE80).
    var boardLayout: WD1770.ControlLayout {
        configuration.discInterface.layout ?? .acorn1770
    }
    /// The 6502 Second Processor, if fitted, and the Tube to it.
    public let secondProcessor: SecondProcessor?
    /// The Z80 Second Processor, if fitted instead.
    public private(set) var z80Processor: Z80SecondProcessor?
    public private(set) var master512: Master512?
    /// The ARM Second Processor, if fitted instead.
    public private(set) var armProcessor: ARMSecondProcessor?
    public internal(set) var tube = Tube()
    /// Parasite half-cycles owed: `parasiteMHz` more each host cycle, 2 per
    /// parasite cycle, so host cycles alternate 1 and 2 parasite cycles at
    /// 3MHz, or have 2 each at 4MHz.
    var parasiteCredit = 0
    /// The 6502 parasite's clock: 3MHz, or the Master Turbo's 4MHz.
    public let parasiteMHz: Int

    /// Rewind history, if enabled.
    public internal(set) var rewinder: Rewinder?

    /// What the video is showing now, for the TV's metadata.
    var videoMetadata: UInt32 = 0

    // Debugging.
    public internal(set) var debuggerIfCreated: Debugger?
    /// Set while the debugger wants to see every access.
    var debugHooks = false
    /// Set while the debugger wants to see the CRTC's syncs.
    var debugVideoHooks = false

    /// The Master Compact's settings EEPROM.
    public var eeprom = PCD8572()
    /// The Compact's digital joystick: bit 4 right, 3 up, 2 down, 1 left,
    /// 0 fire, set when pressed.
    var digitalJoystick: UInt8 = 0
    /// The AMX mouse on the user port (not on the Compact).
    public internal(set) var mouse = AMXMouse()

    /// The Master's real-time clock and CMOS RAM.
    public var rtc = MC146818()
    var mixer: SoundMixer?
    var sampleRing: SampleRing?
    /// The disc drives' noises (nil: silent), mixed in while audio is
    /// attached. Not saved: they don't change what the machine does.
    public var discDriveSounds: DiscDriveSounds? {
        didSet {
            discNoises = [DiscDriveNoise(), DiscDriveNoise()]
            discNoiseStep = (discDriveSounds?.rate ?? 0) / Double(SoundMixer.chipRate)
        }
    }
    var discNoises = [DiscDriveNoise(), DiscDriveNoise()]
    /// MAME's recordings are quiet (the motor's 46dB down, a step's click
    /// about 20dB): mixed at full scale, as b2 does, the motor's lost under
    /// the BBC's own sound. 12dB up puts a click about level with one of
    /// the sound chip's channels at full volume.
    static let discNoiseGain: Float = 4
    /// Frames of the samples to each chip tick.
    var discNoiseStep = 0.0
    /// A second copy of the audio, for recording.
    public var recordingAudio: SampleRing?

    /// The serial ULA (&FE10) and the 6850 ACIA (&FE08) it clocks: the
    /// cassette interface, and RS423 with nothing connected.
    public internal(set) var serial = SerialULA()
    /// The tape in the cassette recorder.
    public internal(set) var tape: Tape?
    /// Called when the cassette motor relay switches (true: on).
    public var onCassetteMotor: ((Bool) -> Void)?

    /// Attach a TV to receive the video stream.
    public var tv: TVOutput?

    /// 2MHz cycles since power on.
    public internal(set) var cycles: UInt64 = 0

    // Memory.

    /// Main RAM (32K), then shadow RAM (32K, of which &3000-&7FFF is
    /// used), ANDY (4K) and HAZEL (8K).
    let ram: UnsafeMutablePointer<UInt8>
    static let ramSize = 0x13000
    static let shadowOffset = 0x8000
    static let andyOffset = 0x10000
    static let hazelOffset = 0x11000
    let osROM: UnsafeMutablePointer<UInt8>
    /// Sideways ROM and RAM banks; nil for an empty socket.
    let sidewaysBanks: [UnsafeMutablePointer<UInt8>?]
    public let sidewaysRAMBanks: Set<Int>
    /// Each bank's ROM mapper (standard for 16K ROMs and RAM).
    public let romMappers: [ROMMapper]
    /// Whether any bank has a bigger ROM, so the bus needs watching.
    let mappersFitted: Bool
    /// The part of each bigger ROM showing, by bank (0 at power on).
    public internal(set) var romRegions = InlineArray<16, UInt8>(repeating: 0)
    /// Writes to ROM land here.
    let discardPage: UnsafeMutablePointer<UInt8>
    /// 4K page -> memory, for reads (nil: nothing there) and writes. Pages
    /// 0-15 are for most code, 16-31 for code in &C000-&DFFF.
    let readPages: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
    let writePages: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>
    /// 0 or 16: the table for the current instruction.
    var pageTable = 0
    /// The table for code fetched from each page: 16 where code sees
    /// shadow RAM as the VDU drivers do (&C000-&DFFF, and on the B+ its
    /// private RAM at &A000-&AFFF).
    var codePageTables = InlineArray<16, Int>(repeating: 0)
    /// ROMSEL (&FE30): the paged ROM bank, and on the Master, bit 7 for
    /// ANDY.
    public internal(set) var romsel: UInt8 = 0
    /// The Master's ACCCON (&FE34).
    public internal(set) var acccon: UInt8 = 0
    /// Offset of the RAM the video hardware reads: shadow when ACCCON D is
    /// set.
    var videoRAMOffset = 0
    /// A Watford 32K RAM board is fitted: its RAM is the shadow area of
    /// `ram` (unused otherwise on the Model B), mapped by `watfordMapping`.
    /// The video always reads main RAM.
    public let watfordFitted: Bool
    public internal(set) var watfordMapping = WatfordMapping.bbc
    /// Writes to &FFFD, which the Watford board decodes to no known effect.
    public internal(set) var watfordFFFDWrites = 0
    /// An Aries B32 is fitted (with or without the B12): its 32K pool is
    /// the shadow area of `ram`, banks 13 (the first 16K) and 14 (the
    /// second), and shadow RAM for &3000-&7FFF.
    public let ariesFitted: Bool
    public let ariesB12Fitted: Bool
    let ariesStartUpLink: Bool
    public internal(set) var aries = AriesState()
    /// The last writes to an expansion board's registers, newest last, for
    /// the debugger.
    public internal(set) var controllerWrites: [ControllerWrite] = []
    /// The Master's data bus isn't buffered: unmapped reads see the last
    /// byte the video fetched.
    var lastVideoByte: UInt8 = 0
    /// The video's RAM address bits: 16K on the Model A.
    var videoAddressMask: UInt16 { model == .modelA ? 0x3FFF : 0x7FFF }

    /// Base addresses for Mode 7, by MA11. The B and B+ can show &3C00.
    let teletextBases: (UInt16, UInt16)

    /// True for each address in &FC00-&FEFF that's a 1MHz device.
    let stretchTable: [Bool]
    var stretch = false

    // System VIA port B drives the addressable latch (IC32).
    public internal(set) var addressableLatch: UInt8 = 0xFF
    var oldAddressableLatch: UInt8 = 0xFF
    var oldSystemVIAPB: UInt8 = 0xFF
    var systemVIAIRQ: UInt8 = 0
    var userVIAIRQ: UInt8 = 0

    // Keyboard: one byte per column, bit per row.
    var keyColumns = InlineArray<16, UInt8>(repeating: 0)
    var keyScanColumn = 0
    /// Joystick fire buttons on system VIA PB4/PB5, active low.
    var notJoystickButtons: UInt8 = 0x30
    public internal(set) var resetting = false
    /// Scheduled presses and releases from `type(_:)`, in time order.
    var keyEvents: [KeyEvent] = []

    /// Set when anything needs to see each opcode fetch (pasting, idle
    /// detection), so the common case costs one test per cycle.
    var opcodeHooks = false
    var paste: Paste?
    var watchForIdle = false
    /// While watching for idle: a hash of the bytes the video hardware has
    /// displayed this frame, and last frame's; when anything (the picture,
    /// a drive or the cassette motor, keys still to type) last changed; and
    /// when the keyboard was last polled, and since when without a break.
    var screenHash: UInt64 = 0
    var lastScreenHash: UInt64 = 0
    var lastActivity: UInt64 = 0
    var lastKeyboardPoll: UInt64 = 0
    var pollingSince: UInt64 = 0
    /// Stop address for `runUntil(address:)`.
    var watchAddress: UInt16?
    public internal(set) var reachedWatchAddress = false
    /// Set when the CPU fetches from the OS's wait-for-key loop, or the
    /// machine has been waiting for input for `waitingCycles`.
    public internal(set) var reachedIdle = false
    /// Characters written through WRCHV while `captureOutput` is set.
    public var capturedOutput: [UInt8] = []
    public var captureOutput = false {
        didSet { updateOpcodeHooks() }
    }

    /// Called for writes to I/O addresses with no device (e.g. test
    /// programs reporting results to &FCD0).
    public var unmappedIOWriteObserver: ((UInt16, UInt8) -> Void)?

    // Video.
    var crtcLastOutput = CRTC6845.Output()
    /// The byte latched for the SAA5050 (IC15).
    var ic15Byte: UInt8 = 0
    var unit = VideoUnit()

    static let screenWrapAdjustments: InlineArray<4, UInt16> = [0x4000 >> 3, 0x2000 >> 3, 0x5000 >> 3, 0x2800 >> 3]

    /// The model and ROMs the machine was built with.
    public struct Configuration: Codable, Sendable, Equatable {
        public var model: Model
        public var os: [UInt8]
        /// Sideways ROMs by bank, 0-15: up to 16K, or bigger with a mapper.
        public var sidewaysROMs: [Int: [UInt8]]
        /// How the bigger ROMs are switched, by bank; standard if absent.
        public var romMappers: [Int: ROMMapper]
        /// Banks that are RAM. (On the B+ 128K, 0, 1, 12 and 13; on the
        /// Master, 4-7.)
        public var sidewaysRAMBanks: Set<Int>
        /// A second processor on the Tube, with this ROM (TUBE110 for the
        /// 6502, the Z80 client ROM for the Z80, the supervisor ROM for the
        /// ARM).
        public var secondProcessorROM: [UInt8]?
        public var coprocessor: Coprocessor
        /// The Model B's disc interface (the others' are built in).
        public var discInterface: DiscInterface
        /// The Model B's expansions: a memory board. (Ignored on other
        /// models.)
        public var expansions: Expansions
        /// VideoNuLA fitted in place of the Video ULA.
        public var videoNuLA: Bool
        /// An Econet module, with this station number (1-254), or none.
        /// The B, B+ and Masters take one.
        public var econetStation: Int?
        /// A disc in drive 0 at power on: the co-processor's system disc,
        /// so it boots. Not saved with the configuration (a save state has
        /// its discs).
        public var startupDisc: StartupDisc?

        public struct StartupDisc: Sendable, Equatable {
            public var name: String
            public var image: [UInt8]
            public var format: Disc.ImageFormat

            public init(name: String, image: [UInt8], format: Disc.ImageFormat) {
                self.name = name
                self.image = image
                self.format = format
            }
        }

        public init(model: Model = .modelB, os: [UInt8], sidewaysROMs: [Int: [UInt8]],
                    sidewaysRAMBanks: Set<Int>? = nil, secondProcessorROM: [UInt8]? = nil,
                    discInterface: DiscInterface = .intel8271, coprocessor: Coprocessor = .mos6502,
                    startupDisc: StartupDisc? = nil, expansions: Expansions = .none, videoNuLA: Bool = false,
                    econetStation: Int? = nil, romMappers: [Int: ROMMapper] = [:]) {
            self.econetStation = econetStation
            self.romMappers = romMappers
            self.discInterface = discInterface
            self.expansions = expansions
            self.videoNuLA = videoNuLA
            self.startupDisc = startupDisc
            self.coprocessor = coprocessor
            self.model = model
            self.os = os
            self.sidewaysROMs = sidewaysROMs
            self.secondProcessorROM = secondProcessorROM
            let standardRAMBanks: Set<Int> = switch model {
            case .modelA, .modelB: []
            case .bPlus: [0, 1, 12, 13]
            case .master128, .masterCompact: [4, 5, 6, 7]
            }
            self.sidewaysRAMBanks = sidewaysRAMBanks ?? standardRAMBanks
        }

        enum CodingKeys: CodingKey {
            case model, os, sidewaysROMs, sidewaysRAMBanks, secondProcessorROM, discInterface, coprocessor, expansions, videoNuLA
            case econetStation, romMappers
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decodeIfPresent(Model.self, forKey: .model) ?? .modelB
            os = try c.decode([UInt8].self, forKey: .os)
            sidewaysROMs = try c.decode([Int: [UInt8]].self, forKey: .sidewaysROMs)
            sidewaysRAMBanks = try c.decodeIfPresent(Set<Int>.self, forKey: .sidewaysRAMBanks) ?? []
            secondProcessorROM = try c.decodeIfPresent([UInt8].self, forKey: .secondProcessorROM)
            discInterface = try c.decodeIfPresent(DiscInterface.self, forKey: .discInterface) ?? .intel8271
            coprocessor = try c.decodeIfPresent(Coprocessor.self, forKey: .coprocessor) ?? .mos6502
            // Older save states have none.
            expansions = try c.decodeIfPresent(Expansions.self, forKey: .expansions) ?? .none
            videoNuLA = try c.decodeIfPresent(Bool.self, forKey: .videoNuLA) ?? false
            econetStation = try c.decodeIfPresent(Int.self, forKey: .econetStation)
            romMappers = try c.decodeIfPresent([Int: ROMMapper].self, forKey: .romMappers) ?? [:]
        }

        /// What's wrong with the expansions, if anything: bad wiring, or a
        /// board without its controller ROM (which does nothing on its own).
        public var expansionProblem: String? {
            let e = fittedExpansions
            if let problem = e.problem { return problem }
            if let bank = e.controllerROMBank {
                guard let rom = sidewaysROMs[bank], ROMHeader(Array(rom.prefix(0x100))) != nil else {
                    return "The \(e.board.displayName) needs its ROM in bank \(bank)"
                }
            }
            return nil
        }

        /// The expansions in effect: the Model B's, or none.
        public var fittedExpansions: Expansions {
            model == .modelB ? expansions : .none
        }
    }

    public let configuration: Configuration
    /// The disc made from `configuration.startupDisc`, if any.
    public private(set) var startupDisc: Disc?

    /// Creates a Model B with the given OS and sideways ROMs, keyed by bank
    /// 0-15.
    public convenience init(os: [UInt8], sidewaysROMs roms: [Int: [UInt8]] = [:]) {
        self.init(configuration: Configuration(os: os, sidewaysROMs: roms))
    }

    /// Creates a machine with the given ROMs. Sideways RAM banks start
    /// empty, unless `sidewaysROMs` has an image for them.
    public init(configuration: Configuration) {
        precondition(configuration.os.count == 16384, "OS ROM must be 16K")
        self.configuration = configuration
        model = configuration.model
        watfordFitted = configuration.fittedExpansions.board == .watford32K
        ariesFitted = configuration.fittedExpansions.board.isAries
        ariesB12Fitted = configuration.fittedExpansions.board == .ariesB32B12
        ariesStartUpLink = configuration.fittedExpansions.ariesStartUpLink
        nulaFitted = configuration.videoNuLA
        nula = nulaFitted ? VideoNuLA() : nil
        if let station = configuration.econetStation, configuration.model != .modelA, (1...254).contains(station) {
            econet = Econet(station: UInt8(station))
        } else {
            econet = nil
        }
        econetFitted = econet != nil
        let master = model.isMaster
        cpu = M6502(variant: master ? .cmos : .nmos)

        ram = .allocate(capacity: Self.ramSize)
        ram.initialize(repeating: 0, count: Self.ramSize)
        osROM = .allocate(capacity: 0x4000)
        osROM.initialize(from: configuration.os, count: 0x4000)
        // A sideways RAM board's banks are RAM too.
        let ramBanks = configuration.sidewaysRAMBanks.union(configuration.fittedExpansions.sidewaysRAMBanks)
        sidewaysRAMBanks = ramBanks
        // A bigger ROM's mapper; RAM is always 16K.
        let mappers = (0..<16).map { bank in
            ramBanks.contains(bank) || configuration.sidewaysROMs[bank] == nil ? ROMMapper.standard
                : configuration.romMappers[bank] ?? .standard
        }
        romMappers = mappers
        mappersFitted = mappers.contains { $0 != .standard }
        sidewaysBanks = (0..<16).map { bank in
            let data = configuration.sidewaysROMs[bank]
            let isRAM = ramBanks.contains(bank)
            guard data != nil || isRAM else { return nil }
            let size = mappers[bank].size
            precondition(data?.count ?? 0 <= size, "sideways ROM too big")
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            p.initialize(repeating: isRAM ? 0 : 0xFF, count: size)
            if let data {
                p.update(from: data, count: data.count)
            }
            return p
        }
        discardPage = .allocate(capacity: 0x1000)
        discardPage.initialize(repeating: 0, count: 0x1000)
        readPages = .allocate(capacity: 32)
        readPages.initialize(repeating: nil, count: 32)
        writePages = .allocate(capacity: 32)
        writePages.initialize(repeating: discardPage, count: 32)

        // FRED and JIM are 1MHz; so are parts of SHEILA.
        var stretchTable = [Bool](repeating: false, count: 0x300)
        for i in 0..<0x200 { stretchTable[i] = true }
        let sheila = master ? [0x00...0x1F, 0x28...0x2B, 0x40...0x9F] : [0x00...0x1F, 0x40...0x7F, 0xC0...0xDF]
        for range in sheila {
            for i in range { stretchTable[0x200 + i] = true }
        }
        self.stretchTable = stretchTable

        switch model {
        case .modelA:
            intel8271 = nil
            wd1770 = nil
            teletextBases = (0x3C00, 0x7C00)
        case .modelB:
            if configuration.discInterface == .intel8271 {
                intel8271 = Intel8271(drives: drives)
                wd1770 = nil
            } else {
                intel8271 = nil
                wd1770 = WD1770(drives: drives)
            }
            teletextBases = (0x3C00, 0x7C00)
        case .bPlus:
            intel8271 = nil
            wd1770 = WD1770(drives: drives)
            teletextBases = (0x3C00, 0x7C00)
        case .master128:
            intel8271 = nil
            wd1770 = WD1770(drives: drives)
            teletextBases = (0x7C00, 0x7C00)
            rtc.setTime(Date())
        case .masterCompact:
            intel8271 = nil
            // The 1772, with 3.5" drives.
            wd1770 = WD1770(variant: .wd1772, drives: drives)
            teletextBases = (0x7C00, 0x7C00)
        }

        let tubeROM = model.hasTube ? configuration.secondProcessorROM : nil
        let mos6502 = configuration.coprocessor == .mos6502
            || configuration.coprocessor == .masterTurbo && model == .master128
        secondProcessor = mos6502 ? tubeROM.map(SecondProcessor.init(rom:)) : nil
        parasiteMHz = configuration.coprocessor == .masterTurbo ? 4 : 3

        updatePaging()
        oldSystemVIAPB = systemVIA.b.p
        cpu.reset()
        if configuration.coprocessor == .z80, let rom = tubeROM {
            z80Processor = Z80SecondProcessor(rom: rom, machine: self)
        }
        if configuration.coprocessor == .master512, model == .master128, let rom = tubeROM {
            master512 = Master512(rom: rom, machine: self)
        }
        if configuration.coprocessor == .arm, let rom = tubeROM {
            armProcessor = ARMSecondProcessor(rom: rom, machine: self)
        }
        for drive in drives {
            drive.onEvent = { [unowned(unsafe) self, unowned(unsafe) drive] event in
                guard let sounds = self.discDriveSounds else { return }
                self.discNoises[drive.id].event(event, hasDisc: drive.disc != nil, sounds: sounds)
            }
        }
        if let startup = configuration.startupDisc {
            startupDisc = try? Disc.fromImage(startup.image, format: startup.format)
            insertDisc(startupDisc)
        }
        let cpu = cpu
        econet?.onNMI = { cpu.setNMI(NMIDevice.econet, $0) }
        // The Master's ANFS takes its station number from CMOS RAM (byte 0,
        // as *CONFIGURE STATION sets it), not the links.
        if model.isMaster, let econet {
            var cmos = rtc.ram
            cmos[0] = econet.station
            rtc.setRAM(cmos)
        }
    }

    deinit {
        ram.deallocate()
        osROM.deallocate()
        for bank in sidewaysBanks { bank?.deallocate() }
        discardPage.deallocate()
        readPages.deallocate()
        writePages.deallocate()
    }

    // MARK: Memory

    /// Rebuilds the page tables from ROMSEL and ACCCON.
    func updatePaging() {
        let master = model.isMaster, bPlus = model == .bPlus
        let bank = Int(romsel & 0x0F)
        // Master: ANDY, 4K at &8000. B+: 12K at &8000-&AFFF.
        let pagedRAM = (master || bPlus) && romsel & 0x80 != 0
        let shadowAll = master && acccon & 0x04 != 0  // X
        let shadowVDU = master ? acccon & 0x02 != 0   // E
            : bPlus && acccon & 0x80 != 0
        let hazel = master && acccon & 0x08 != 0      // Y
        // Code in &C000-&DFFF only sees shadow RAM through E when it's the
        // MOS there, not HAZEL.
        let shadowMOS = hazel ? shadowAll : shadowVDU
        let pagedRAMPages = bPlus ? 3 : 1
        // The Watford board: its RAM in place of all main RAM, or of
        // &3000-&7FFF.
        let boardAll = watfordFitted && watfordMapping == .all
        let boardUpper = watfordFitted && watfordMapping != .bbc

        for table in [0, 16] {
            let shadow = table == 0 ? shadowAll : shadowMOS
            for page in 0..<16 {
                var read: UnsafeMutablePointer<UInt8>?
                var write: UnsafeMutablePointer<UInt8>?
                switch page {
                case 0..<3:
                    read = ram + (boardAll ? Self.shadowOffset : 0) + page << 12
                    write = read
                case 4..<8 where model == .modelA:
                    // 16K: A14 isn't decoded, so the upper 16K is the lower.
                    read = ram + (page - 4) << 12
                    write = read
                case 3..<8 where ariesFitted && aries.shadow && ariesShadows(page):
                    read = ram + Self.shadowOffset + Self.ariesShadowOffset(page)
                    write = read
                case 3..<8:
                    read = ram + (shadow || boardUpper ? Self.shadowOffset : 0) + page << 12
                    write = read
                case 8..<12 where ariesFitted:
                    let offset = romMappers[bank].offset(page: page - 8, region: romRegions[bank])
                    read = ariesStorage(bank: bank).map { $0 + offset }
                    write = ariesWriteTarget().map { $0 + (page - 8) << 12 }
                case 8..<12 where pagedRAM && page - 8 < pagedRAMPages:
                    read = ram + Self.andyOffset + (page - 8) << 12
                    write = read
                case 8..<12:
                    let offset = romMappers[bank].offset(page: page - 8, region: romRegions[bank])
                    read = sidewaysBanks[bank].map { $0 + offset }
                    if sidewaysRAMBanks.contains(bank) {
                        write = read
                    }
                case 12..<14 where hazel:
                    read = ram + Self.hazelOffset + (page - 12) << 12
                    write = read
                default:
                    read = osROM + (page - 12) << 12
                }
                readPages[table + page] = read
                writePages[table + page] = write ?? discardPage
            }
        }
        for page in 0..<16 {
            let vdu = page == 0xC || page == 0xD || (bPlus && pagedRAM && page == 0xA)
            codePageTables[page] = vdu && model != .modelB ? 16 : 0
        }
        let displayShadow = master ? acccon & 0x01 != 0 : bPlus && acccon & 0x80 != 0
        videoRAMOffset = displayShadow ? Self.shadowOffset : 0
    }

    /// Reads memory as the CPU would, without side effects. I/O reads return
    /// what the device would return.
    public func peek(_ address: UInt16) -> UInt8 {
        if address >= 0xFC00 && address < 0xFF00 {
            return peekIO(address)
        }
        return readPages[Int(address >> 12)]?[Int(address & 0xFFF)] ?? 0xFF
    }

    /// Writes memory as the CPU would (for loading programs), except that
    /// I/O is ignored.
    public func poke(_ address: UInt16, _ value: UInt8) {
        if address < 0xFC00 || address >= 0xFF00 {
            writePages[Int(address >> 12)][Int(address & 0xFFF)] = value
        }
    }

    /// Writes as the CPU would at `address`, for tools: I/O through the
    /// machine's decode (so devices see it, as VideoNuLA's registers must),
    /// memory through the paging (ROM ignores it; the Watford latch sees
    /// &FFFC-&FFFF). The CPU's 1MHz stretching isn't modelled.
    public func cpuWrite(_ address: UInt16, _ value: UInt8) {
        if address >= 0xFC00 && address < 0xFF00 {
            if model.isMaster {
                writeIOMaster(address, value)
            } else {
                writeIO(address, value)
            }
        } else {
            writePages[pageTable + Int(address >> 12)][Int(address & 0xFFF)] = value
            if address >= 0xFFFC && watfordFitted {
                watfordControl(address)
            }
        }
        rewinder?.keyframe()
    }

    /// Reads the RAM the video hardware sees (shadow RAM on the Master
    /// with ACCCON D set).
    public func peekScreen(_ address: UInt16) -> UInt8 {
        ram[Int(address & videoAddressMask) + videoRAMOffset]
    }

    /// Reads main RAM, regardless of paging.
    func peekMainRAM(_ address: UInt16) -> UInt8 {
        ram[Int(address & 0x7FFF)]
    }

    /// The OS font's 8 bytes for characters 32-126: in the OS ROM at &C000
    /// (OS 1.20), or in bank 15 at &B900 (MOS 3.20, whose bank 15 is part
    /// of the OS).
    func fontGlyph(_ character: Int) -> [UInt8] {
        let offset = (character - 32) * 8
        if model.isMaster, let bank = sidewaysBanks[15] {
            return (0..<8).map { bank[0x3900 + offset + $0] }
        }
        return (0..<8).map { osROM[offset + $0] }
    }

    func peekIO(_ address: UInt16) -> UInt8 {
        if model.isMaster {
            switch address & 0xFFE0 {
            case 0xFE00:
                if address & 0x18 == 0x18 { return model.hasADC ? adc.peek(Int(address)) : 0xFF }
                if address & 0x18 == 0x08 { return serial.peekACIA(Int(address)) }
                if address & 0x19 == 1 { return crtc.readData() }
            case 0xFE20:
                switch address & 0x1C {
                case 0x08: return wd1770!.peek(Int(address))
                case 0x10: return romsel
                case 0x14: return acccon
                default: break
                }
            case 0xFE40: return systemVIA.peek(Int(address))
            case 0xFE60: return userVIA.peek(Int(address))
            case 0xFEA0 where econetFitted: return econet!.adlc.peek(Int(address & 3))
        case 0xFEE0 where tubeAccessible: return tube.hostPeek(Int(address))
            case 0xFC40 where scsi != nil && address < 0xFC44: return scsi!.peek(Int(address & 3))
            default: break
            }
            return 0xFF
        }
        switch address & 0xFFE0 {
        case 0xFEA0 where econetFitted: return econet!.adlc.peek(Int(address & 3))
        case 0xFE00 where econetFitted && address & 0x18 == 0x18: return econet!.station
        case 0xFE40: return systemVIA.peek(Int(address))
        case 0xFE60 where model.hasUserVIA: return userVIA.peek(Int(address))
        case 0xFEE0 where tubeAccessible: return tube.hostPeek(Int(address))
        case 0xFE80:
            if let fdc = intel8271 { return fdc.peek(Int(address)) }
            if let fdc = wd1770 {
                let (latchAt, fdcAt) = boardAddresses
                if address & 0x1F == latchAt { return boardLayout.isReadable ? fdc.latch : 0xFF }
                if address & 0x1C == fdcAt { return fdc.peek(Int(address)) }
            }
            return 0xFF
        case 0xFEC0 where model.hasADC: return adc.peek(Int(address))
        case 0xFE00 where address & 0x19 == 1: return crtc.readData()
        case 0xFE00 where address & 0x18 == 0x08: return serial.peekACIA(Int(address))
        case 0xFC40 where scsi != nil && address < 0xFC44: return scsi!.peek(Int(address & 3))
        default: return 0xFF
        }
    }

    @inline(__always)
    private func readIO(_ address: UInt16) -> UInt8 {
        switch address & 0xFFE0 {
        case 0xFE00:
            switch address & 0x18 {
            case 0x00:
                // CRTC (&FE00-&FE07): address/data on A0.
                return address & 1 == 0 ? crtc.readAddress() : crtc.readData()
            case 0x08:
                // ACIA (&FE08-&FE0F): status/data on A0.
                return serial.readACIA(Int(address))
            case 0x18 where econetFitted:
                // The station number links, and INTOFF.
                return econet!.readStation(now: cycles)
            default:
                // Serial ULA: there's no read/write line, so a read writes
                // the stale bus. Reads give 0 on the B (as b2).
                writeSerialULA(cpu.dbus)
                return 0
            }
        case 0xFE20 where econetFitted && address & 0x10 == 0:
            // A read of the Video ULA's addresses is INTON.
            econet!.inton(now: cycles)
        case 0xFEA0 where econetFitted:
            return econet!.read(Int(address & 3), now: cycles)
        case 0xFE40:
            if watchForIdle {
                systemVIARead(address)
            }
            return systemVIA.read(Int(address))
        case 0xFE60 where model.hasUserVIA:
            return userVIA.read(Int(address))
        case 0xFEE0 where tubeAccessible:
            return tube.hostRead(Int(address))
        case 0xFE80:
            if let fdc = intel8271 {
                return fdc.read(Int(address))
            }
            // A 1770 board: the latch (readable on some) and the controller.
            if let fdc = wd1770 {
                let (latchAt, fdcAt) = boardAddresses
                if address & 0x1F == latchAt && boardLayout.isReadable { return fdc.latch }
                if address & 0x1C == fdcAt { return fdc.read(Int(address)) }
            }
        case 0xFEC0 where model.hasADC:
            return adc.read(Int(address))
        case 0xFC40 where scsi != nil && address < 0xFC44:
            return scsi!.read(Int(address & 3))
        default:
            break
        }
        // Unmapped: the data bus keeps its previous value.
        return cpu.dbus
    }

    @inline(__always)
    private func writeIO(_ address: UInt16, _ value: UInt8) {
        switch address & 0xFFE0 {
        case 0xFE00:
            switch address & 0x18 {
            case 0x00:
                if address & 1 == 0 {
                    crtc.writeAddress(value)
                } else {
                    crtc.writeData(value)
                }
            case 0x08:
                serial.writeACIA(Int(address), value)
            case 0x18 where econetFitted:
                econet!.intoff(now: cycles)
            default:
                writeSerialULA(value)
            }
        case 0xFEA0 where econetFitted:
            econet!.write(Int(address & 3), value, now: cycles)
        case 0xFE20:
            if address & 0x10 == 0 {
                // Video ULA (&FE20-&FE2F); with VideoNuLA, A1 set is its
                // registers.
                if nulaFitted && address & 2 != 0 {
                    if address & 1 == 0 {
                        nula!.writeControl(value, ula: &videoULA)
                    } else {
                        nula!.writePalette(value, ula: &videoULA)
                    }
                } else if address & 1 == 0 {
                    videoULA.writeControl(value)
                    if nulaFitted { nula!.updatePixelBufferOffset(fast6845: videoULA.fast6845) }
                } else {
                    videoULA.writePalette(value)
                }
            } else if model == .bPlus {
                switch address & 0x0C {
                case 0x00:
                    // ROMSEL (&FE30-&FE33): bank, and bit 7 for the 12K.
                    romsel = value & 0x8F
                    updatePaging()
                case 0x04:
                    // ACCCON (&FE34-&FE37): bit 7 is shadow.
                    acccon = value & 0x80
                    updatePaging()
                default:
                    break
                }
            } else if ariesFitted {
                ariesControl(address, value)
            } else {
                // ROMSEL (&FE30-&FE3F).
                romsel = value & 0x0F
                updatePaging()
            }
        case 0xFE40:
            systemVIA.write(Int(address), value)
        case 0xFE60 where model.hasUserVIA:
            userVIA.write(Int(address), value)
        case 0xFEE0 where tubeAccessible:
            tube.hostWrite(Int(address), value)
        case 0xFE80:
            if let fdc = intel8271 {
                fdc.write(Int(address), value)
            } else if let fdc = wd1770 {
                let (latchAt, fdcAt) = boardAddresses
                if address & 0x1F == latchAt {
                    fdc.writeControl(value, layout: boardLayout)
                } else if address & 0x1C == fdcAt {
                    fdc.write(Int(address), value)
                }
            }
        case 0xFEC0 where model.hasADC:
            adc.write(Int(address), value)
        case 0xFC40 where scsi != nil && address < 0xFC44:
            writeSCSI(address, value)
        default:
            if address < 0xFE00 {
                // FRED and JIM: nothing fitted.
                unmappedIOWriteObserver?(address, value)
            }
        }
    }

    /// A bigger ROM's mapper sees every access to &8000-&BFFF while its
    /// bank is selected, and may switch what's showing (before the access,
    /// as b2 does).
    func mapperAccess(_ address: UInt16) {
        let bank = Int(romsel & 0x0F)
        guard let region = romMappers[bank].region(for: address, current: romRegions[bank]),
              region != romRegions[bank] else { return }
        romRegions[bank] = region
        updatePaging()
    }

    /// A sideways bank's storage: its socket's, or an Aries B32's pool.
    func sidewaysStorage(_ bank: Int) -> UnsafeMutablePointer<UInt8>? {
        ariesFitted ? ariesStorage(bank: bank) : sidewaysBanks[bank]
    }

    /// Whether a sideways bank is RAM (an Aries B32's banks 13 and 14
    /// included).
    public func isSidewaysRAM(_ bank: Int) -> Bool {
        sidewaysRAMBanks.contains(bank) || (ariesFitted && (bank == 13 || bank == 14))
    }

    // MARK: Aries B32

    /// Whether a page of &3000-&7FFF is shadowed with shadow RAM on:
    /// &4000-&6FFF always, &3000 and &7000 by their switches.
    func ariesShadows(_ page: Int) -> Bool {
        switch page {
        case 3: aries.shadowLow
        case 7: aries.shadowHigh
        default: true
        }
    }

    /// Where a shadowed page is in the pool: &4000-&7FFF is bank 13's 16K,
    /// and &3000-&3FFF the top 4K of bank 14 (&B000-&BFFF). (The manual:
    /// shadow RAM comes from bank 13 first, and 20K takes the top 4K of
    /// bank 14; the ROM's *XTEST checks 20K of shadow and 12K of bank 14
    /// from &8000 don't overlap.)
    static func ariesShadowOffset(_ page: Int) -> Int {
        page == 3 ? 0x7000 : (page - 4) << 12
    }

    /// A sideways bank's storage with an Aries board: 13 and 14 are the
    /// pool; the rest are sockets.
    func ariesStorage(bank: Int) -> UnsafeMutablePointer<UInt8>? {
        switch bank {
        case 13: ram + Self.shadowOffset
        case 14: ram + Self.shadowOffset + 0x4000
        default: sidewaysBanks[bank]
        }
    }

    /// Where writes to &8000-&BFFF go: the bank in RAMSEL (&FE32), whatever
    /// ROMSEL is reading ("write-through"). 13 and 14 are the B32's RAM; 15
    /// is its ROM socket, so writes are lost (the ROM's *RWRITE OFF writes
    /// 15); 0-12 pass the write on to the BBC's bus (*RWRITE EXTERNAL writes
    /// 0), where the B12's RAM takes every write, as its manual says, and a
    /// sideways RAM module takes them while its bank is selected.
    func ariesWriteTarget() -> UnsafeMutablePointer<UInt8>? {
        switch Int(aries.ramsel & 0x0F) {
        case 13, 14:
            return ariesStorage(bank: Int(aries.ramsel & 0x0F))
        case 15:
            return nil
        default:
            // On the bus: the B12's RAM takes every write; a module in a
            // motherboard socket takes them while its bank is selected.
            if ariesB12Fitted { return sidewaysBanks[0] }
            let bank = Int(romsel & 0x0F)
            return configuration.fittedExpansions.moduleBanks.contains(bank) ? sidewaysBanks[bank] : nil
        }
    }

    /// A write to &FE30-&FE3F with an Aries B32: ROMSEL, RAMSEL and the
    /// shadow switches, by address (the data only matters for ROMSEL and
    /// RAMSEL).
    func ariesControl(_ address: UInt16, _ value: UInt8) {
        switch address & 0x0F {
        case 0x0: romsel = value & 0x0F
        case 0x2: aries.ramsel = value
        case 0x4: aries.shadowHigh = false
        case 0x6: aries.shadowHigh = true
        // The ROM's start-up link test: shadow RAM as the link sets it.
        case 0x8: aries.shadow = ariesStartUpLink
        case 0xA: aries.shadowLow = true
        case 0xC: aries.shadowLow = false
        case 0xE: aries.shadow = false
        case 0xF: aries.shadow = true
        default: break
        }
        noteControllerWrite(address, value)
        updatePaging()
    }

    func noteControllerWrite(_ address: UInt16, _ value: UInt8) {
        if controllerWrites.count >= 64 {
            controllerWrites.removeFirst(controllerWrites.count - 63)
        }
        controllerWrites.append(ControllerWrite(cycle: cycles, address: address, value: value))
    }

    /// A write to &FFFC-&FFFF with the Watford board fitted: the address
    /// sets the mapping (the OS ROM there ignores the write itself).
    func watfordControl(_ address: UInt16) {
        noteControllerWrite(address, 0)
        switch address & 3 {
        case 0: watfordMapping = .all
        case 2: watfordMapping = .bbc
        case 3: watfordMapping = .upper
        default:
            // &FFFD: decoded by the board, but nothing documents what it
            // does (MAME ignores it). Counted, so it shows if it matters.
            watfordFFFDWrites += 1
            return
        }
        updatePaging()
    }

    /// Whether the host sees the Tube: always on the B and B+; on the
    /// Master, while ACCCON's ITU bit selects the Tube the co-processor's
    /// on (internal for the Master Turbo, external for the rest).
    var tubeAccessible: Bool {
        (secondProcessor != nil || z80Processor != nil || master512 != nil || armProcessor != nil)
            && (!model.isMaster || (acccon & 0x10 != 0) == configuration.coprocessor.isInternal)
    }

    // MARK: Master I/O

    @inline(__always)
    private func readIOMaster(_ address: UInt16) -> UInt8 {
        // TST: the OS ROM appears in place of I/O.
        if acccon & 0x40 != 0 {
            return osROM[Int(address - 0xC000)]
        }
        switch address & 0xFFE0 {
        case 0xFE00:
            switch address & 0x18 {
            case 0x00:
                return address & 1 == 0 ? crtc.readAddress() : crtc.readData()
            case 0x08:
                return serial.readACIA(Int(address))
            case 0x10:
                // Serial ULA: every access is a write (of the stale bus).
                writeSerialULA(lastVideoByte)
                return lastVideoByte
            default:
                if model.hasADC {
                    return adc.read(Int(address))
                }
            }
        case 0xFE20:
            switch address & 0x1C {
            case 0x08: return wd1770!.read(Int(address))
            case 0x10: return romsel
            case 0x14: return acccon
            case 0x18 where econetFitted: return econet!.readStation(now: cycles)
            case 0x1C where econetFitted:
                econet!.inton(now: cycles)
            default: break
            }
        case 0xFEA0 where econetFitted:
            return econet!.read(Int(address & 3), now: cycles)
        case 0xFE40:
            if watchForIdle {
                systemVIARead(address)
            }
            return systemVIA.read(Int(address))
        case 0xFE60:
            return userVIA.read(Int(address))
        case 0xFEE0 where tubeAccessible:
            return tube.hostRead(Int(address))
        case 0xFC40 where scsi != nil && address < 0xFC44:
            return scsi!.read(Int(address & 3))
        default:
            break
        }
        return lastVideoByte
    }

    @inline(__always)
    private func writeIOMaster(_ address: UInt16, _ value: UInt8) {
        switch address & 0xFFE0 {
        case 0xFE00:
            switch address & 0x18 {
            case 0x00:
                if address & 1 == 0 {
                    crtc.writeAddress(value)
                } else {
                    crtc.writeData(value)
                }
            case 0x08:
                serial.writeACIA(Int(address), value)
            case 0x10:
                writeSerialULA(value)
            default:
                if model.hasADC {
                    adc.write(Int(address), value)
                }
            }
        case 0xFE20:
            switch address & 0x1C {
            case 0x00:
                if nulaFitted && address & 2 != 0 {
                    if address & 1 == 0 {
                        nula!.writeControl(value, ula: &videoULA)
                    } else {
                        nula!.writePalette(value, ula: &videoULA)
                    }
                } else if address & 1 == 0 {
                    videoULA.writeControl(value)
                    if nulaFitted { nula!.updatePixelBufferOffset(fast6845: videoULA.fast6845) }
                } else {
                    videoULA.writePalette(value)
                }
            case 0x04:
                wd1770!.writeControl(value, layout: .master128)
            case 0x08:
                wd1770!.write(Int(address), value)
            case 0x10:
                romsel = value & 0x8F
                updatePaging()
            case 0x14:
                acccon = value
                updatePaging()
                cpu.setIRQ(IRQDevice.acccon, value & 0x80 != 0)
            case 0x18 where econetFitted:
                econet!.intoff(now: cycles)
            default:
                break
            }
        case 0xFEA0 where econetFitted:
            econet!.write(Int(address & 3), value, now: cycles)
        case 0xFE40:
            systemVIA.write(Int(address), value)
        case 0xFE60:
            userVIA.write(Int(address), value)
        case 0xFEE0 where tubeAccessible:
            tube.hostWrite(Int(address), value)
        case 0xFC40 where scsi != nil && address < 0xFC44:
            writeSCSI(address, value)
        default:
            if address < 0xFE00 {
                unmappedIOWriteObserver?(address, value)
            }
        }
    }

    /// Where a 1770 board's latch and controller are, from &FE80: Opus
    /// swaps them.
    var boardAddresses: (latch: UInt16, controller: UInt16) {
        boardLayout == .opus ? (0x04, 0x00) : (0x00, 0x04)
    }

    private func writeSerialULA(_ value: UInt8) {
        if serial.writeControl(value) {
            onCassetteMotor?(serial.motorOn)
        }
    }

    /// Sends audio, at `sampleRate`, to `ring`.
    public func attachAudio(sampleRate: Int, ring: SampleRing) {
        mixer = SoundMixer(outputRate: sampleRate)
        sampleRing = ring
    }

    public func detachAudio() {
        mixer = nil
        sampleRing = nil
    }

    /// The machine's indicator lights.
    public struct Lights: Equatable, Sendable {
        public var capsLock = false
        public var shiftLock = false
        public var cassetteMotor = false
        /// Each drive's activity light (its motor).
        public var drives = [false, false]
        /// The hard disc's, while a command's running.
        public var hardDisc = false

        public init() {}
    }

    public var lights: Lights {
        var lights = Lights()
        // The keyboard LEDs light when their latch bits are low.
        lights.capsLock = addressableLatch & 0x40 == 0
        lights.shiftLock = addressableLatch & 0x80 == 0
        lights.cassetteMotor = serial.motorOn
        lights.drives = drives.map(\.spinning)
        lights.hardDisc = scsi?.activeDrive != nil
        return lights
    }

    /// Connects a hard disc to the SCSI interface as drive `drive` (0-3;
    /// nil disconnects it). The interface is fitted with the first.
    public func attachHardDisc(_ disc: HardDisc?, drive: Int = 0) {
        guard (0..<AcornSCSI.driveCount).contains(drive) else { return }
        if scsi == nil {
            guard disc != nil else { return }
            scsi = AcornSCSI()
        }
        scsi?.discs[drive] = disc
    }

    /// The hard disc attached as `drive`, if any.
    public func hardDisc(_ drive: Int = 0) -> HardDisc? {
        scsi?.discs[drive]
    }

    private func writeSCSI(_ address: UInt16, _ value: UInt8) {
        guard let scsi else { return }
        scsi.write(Int(address & 3), value)
        cpu.setIRQ(IRQDevice.scsi, scsi.irq)
    }

    /// Puts a disc in drive 0 or 1 (nil ejects).
    public func insertDisc(_ disc: Disc?, drive: Int = 0) {
        drives[drive].insert(disc)
        rewinder?.keyframe()
    }

    /// Whether the disc in `drive` can be changed from outside the BBC, as
    /// if swapped for another: its motor's been off for 3 seconds. ADFS
    /// trusts the map and directory it remembers for about 4 seconds after
    /// it last used the drive (which stops 2 seconds after), then checks
    /// the disc ID and says "Disc changed" if it's different. Before then,
    /// it would write its old map over the changes.
    public func discIsIdle(drive: Int) -> Bool {
        let d = drives[drive]
        guard !d.spinning else { return false }
        let now = intel8271?.time ?? wd1770?.time ?? 0
        return now - d.speedTime >= 3_000_000
    }

    /// After a power cycle, puts the discs `old` had back in the drives.
    /// Its startup disc stays only if this machine has the same one (so
    /// changing co-processor changes system disc); an empty drive keeps
    /// this machine's.
    public func insertDiscs(from old: BBCMicro) {
        for drive in drives.indices {
            guard let disc = old.drives[drive].disc else { continue }
            if disc === old.startupDisc {
                guard old.configuration.startupDisc == configuration.startupDisc else { continue }
                // The same one, with anything written to it.
                startupDisc = disc
            }
            insertDisc(disc, drive: drive)
        }
        // Hard discs are fixed: they stay connected.
        for drive in 0..<AcornSCSI.driveCount {
            if let disc = old.hardDisc(drive) { attachHardDisc(disc, drive: drive) }
        }
    }

    /// Puts a tape in the cassette recorder (nil ejects).
    public func insertTape(_ newTape: Tape?) {
        tape = newTape
        rewinder?.keyframe()
    }

    /// Rewinds the tape to the start.
    public func rewindTape() {
        tape?.rewind()
        rewinder?.keyframe()
    }

    // MARK: Mouse

    /// Moves the AMX mouse by counts: right and down are positive.
    public func moveMouse(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        rewinder?.record(.mouseMove(dx: dx, dy: dy))
        mouse.move(dx: dx, dy: dy)
    }

    /// Whether software is using the mouse: the user VIA's CB1 or CB2
    /// interrupts (the mouse's clocks) are enabled.
    public var mouseInUse: Bool {
        model != .masterCompact && userVIA.ier & (VIA6522.IRQ.cb1 | VIA6522.IRQ.cb2) != 0
    }

    /// Roughly how far, in TV pixels, a count moves the pointer: measured
    /// for GEM on the Master 512 (8); for AMX software a guess (2, a pixel
    /// in Mode 1 or 4).
    public var mouseTVPixelsPerCount: Double { master512 != nil ? 8 : 2 }

    public func setMouseButtons(_ buttons: AMXMouse.Buttons) {
        guard buttons != mouse.buttons else { return }
        rewinder?.record(.mouseButtons(buttons))
        mouse.buttons = buttons
    }

    // MARK: Joysticks

    /// Sets analogue joystick 0 or 1: `x` and `y` from -1 (left/down) to 1
    /// (right/up), and its fire button.
    public func setJoystick(_ index: Int, x: Double, y: Double, fire: Bool) {
        rewinder?.record(.joystick(index, x: x, y: y, fire: fire))
        applyJoystick(index, x: x, y: y, fire: fire)
    }

    func applyJoystick(_ index: Int, x: Double, y: Double, fire: Bool) {
        precondition(index == 0 || index == 1)
        if model == .masterCompact {
            // A digital joystick: the stick's direction, past halfway.
            guard index == 0 else { return }
            digitalJoystick = (x > 0.5 ? 0x10 : 0) | (y > 0.5 ? 0x08 : 0) | (y < -0.5 ? 0x04 : 0)
                | (x < -0.5 ? 0x02 : 0) | (fire ? 0x01 : 0)
            return
        }
        // The BBC reads high values for left and up.
        func channel(_ value: Double, inverted: Bool) -> UInt16 {
            let v = max(-1, min(1, value))
            return UInt16(((inverted ? -v : v) + 1) / 2 * 1023)
        }
        adc.channels[index * 2] = channel(x, inverted: true)
        adc.channels[index * 2 + 1] = channel(y, inverted: false)
        let bit: UInt8 = index == 0 ? 0x10 : 0x20
        if fire {
            notJoystickButtons &= ~bit
        } else {
            notJoystickButtons |= bit
        }
    }

    // MARK: Keyboard

    public func isKeyDown(_ key: BeebKey) -> Bool {
        keyColumns[key.column] & UInt8(1 << key.row) != 0
    }

    /// Presses or releases a key. Break halts the CPU while held and resets
    /// it on release.
    public func setKey(_ key: BeebKey, down: Bool) {
        rewinder?.record(.key(key, down: down))
        applyKey(key, down: down)
    }

    /// `setKey` without recording it for rewind (for the machine's own key
    /// presses: typing, pasting, replay).
    func applyKey(_ key: BeebKey, down: Bool) {
        var key = key
        if key.isKeypad && !model.hasKeypad {
            guard let equivalent = key.mainKeyboardEquivalent else { return }
            key = equivalent
        }
        if key == .breakKey {
            guard down != resetting else { return }
            resetting = down
            if down {
                cpu.halt()
                secondProcessor?.cpu.halt()
            } else {
                cpu.reset()
                econet?.reset(now: cycles)
                if let secondProcessor {
                    secondProcessor.reset()
                    tube.reset()
                }
                if let z80Processor {
                    z80Processor.reset()
                    tube.reset()
                }
                if let master512 {
                    master512.reset()
                    tube.reset()
                }
                if let armProcessor {
                    armProcessor.reset()
                    tube.reset()
                }
            }
            return
        }
        if down {
            keyColumns[key.column] |= UInt8(1 << key.row)
        } else {
            keyColumns[key.column] &= ~UInt8(1 << key.row)
        }
    }

    // MARK: Running

    /// Set by watches (idle, address) to end `run` early.
    var stopRequested = false

    /// Runs up to `count` 2MHz cycles, stopping early (on the exact cycle)
    /// if a watch fires: see `watchForIdle(_:)` and `watch(address:)`.
    /// Returns the cycles run.
    @discardableResult
    public func run(cycles count: Int) -> Int {
        // A debugger stop holds until it's resumed.
        if isStoppedByDebugger {
            return 0
        }
        rewinder?.flushKeyframe()
        stopRequested = false
        var done = 0
        while done < count && !stopRequested {
            // Key events are applied every 0.5ms, on absolute cycle counts,
            // so how the run is divided up doesn't matter (for replay).
            let chunk = min(count - done, 1000 - Int(cycles % 1000))
            if cycles % 1000 == 0 {
                processKeyEvents()
                rewinder?.tick()
            }
            var i = 0
            while i < chunk {
                step()
                i += 1
                if stopRequested { break }
            }
            done += i
        }
        return done
    }

    /// Runs for `seconds` of emulated time.
    public func run(seconds: Double) {
        run(cycles: Int(seconds * 2_000_000))
    }

    /// Runs one 2MHz cycle.
    @inline(__always)
    public func step() {
        let trailingEdge = cycles & 1 != 0

        // CPU.
        if stretch {
            if trailingEdge {
                stretch = false
            }
        } else {
            cpu.tick()
            let address = cpu.abus
            if address >= 0xFC00 && address < 0xFF00 {
                stretch = stretchTable[Int(address - 0xFC00)]
            }
        }

        if !stretch {
            let address = cpu.abus
            if mappersFitted && address & 0xC000 == 0x8000 {
                mapperAccess(address)
            }
            let io = address >= 0xFC00 && address < 0xFF00
            if cpu.access == .write {
                if io {
                    if model.isMaster {
                        writeIOMaster(address, cpu.dbus)
                    } else {
                        writeIO(address, cpu.dbus)
                    }
                } else {
                    writePages[pageTable + Int(address >> 12)][Int(address & 0xFFF)] = cpu.dbus
                    if address >= 0xFFFC && watfordFitted {
                        watfordControl(address)
                    }
                }
            } else {
                if cpu.access == .opcode {
                    pageTable = codePageTables[Int(address >> 12)]
                }
                if io {
                    cpu.dbus = model.isMaster ? readIOMaster(address) : readIO(address)
                } else if let page = readPages[pageTable + Int(address >> 12)] {
                    cpu.dbus = page[Int(address & 0xFFF)]
                } else if model.isMaster {
                    cpu.dbus = lastVideoByte
                }
                // (An empty socket on the B leaves the data bus alone.)
                if opcodeHooks && cpu.access == .opcode {
                    opcodeFetched()
                }
            }
            if debugHooks {
                debugger.hostAccessed(address, cpu.access)
            }
        }
        if debugHooks {
            debugger.hostCycle()
        }

        // Second processor, at 3MHz (or 4MHz). A debugger stop can leave a
        // cycle owed until the next host cycle.
        if let secondProcessor {
            parasiteCredit += parasiteMHz
            while parasiteCredit >= 2 && !(debugHooks && stopRequested) {
                secondProcessor.step(tube: &tube)
                parasiteCredit -= 2
            }
            cpu.setIRQ(IRQDevice.tube, tubeAccessible && tube.hostIRQ)
        } else if let z80Processor, !resetting {
            z80Processor.step()
            cpu.setIRQ(IRQDevice.tube, tubeAccessible && tube.hostIRQ)
        } else if let master512, !resetting {
            master512.step()
            cpu.setIRQ(IRQDevice.tube, tubeAccessible && tube.hostIRQ)
        } else if let armProcessor, !resetting {
            armProcessor.step()
            cpu.setIRQ(IRQDevice.tube, tubeAccessible && tube.hostIRQ)
        }

        // Video.
        if videoULA.fast6845 || trailingEdge {
            updateVideo(trailingEdge: trailingEdge)
        }
        emitVideo()

        // Sound: 250kHz. The chip takes port A while IC32 bit 0 is low.
        if cycles & 7 == 0 {
            let output = soundChip.update(write: addressableLatch & 1 == 0, value: systemVIA.a.p)
            var noise: Float = 0
            if mixer != nil, let sounds = discDriveSounds {
                noise = (discNoises[0].next(sounds, step: discNoiseStep) + discNoises[1].next(sounds, step: discNoiseStep))
                    * Self.discNoiseGain
            }
            if mixer != nil, let sample = mixer!.mix(output, extra: noise) {
                sampleRing?.write(sample)
                recordingAudio?.write(sample)
            }
        }

        // VIAs.
        if trailingEdge {
            updateTrailingEdge()
        } else {
            systemVIAIRQ = systemVIA.updatePhi2LeadingEdge()
            userVIAIRQ = userVIA.updatePhi2LeadingEdge()
        }

        // Econet: the line and the ADLC's own timing.
        if econetFitted && cycles >= econet.unsafelyUnwrapped.nextEvent {
            econet.unsafelyUnwrapped.advance(to: cycles)
        }

        cycles &+= 1
    }

    @inline(__always)
    private func updateVideo(trailingEdge: Bool) {
        let output = crtc.update(lightpen: systemVIA.b.c2 != 0)
        if debugVideoHooks {
            debugger.video(output, last: crtcLastOutput)
        }

        var address = output.address
        if address & 0x2000 != 0 {
            // Mode 7: 1K at &7C00 (or &3C00 on the Master).
            address = (address & 0x3FF) | (address & 0x800 == 0 ? teletextBases.0 : teletextBases.1)
        } else {
            if address & 0x1000 != 0 {
                address &-= Self.screenWrapAdjustments[Int(addressableLatch >> 4 & 3)]
                address &= ~0x1000
            }
            // When raster >= 8 this address is bogus; it isn't displayed.
            address = (address << 3 | UInt16(output.raster & 7)) & 0x7FFF
        }

        // (In the 2MHz modes vsync can start on either edge.)
        if watchForIdle && output.vsync && !crtcLastOutput.vsync {
            checkWaiting()
        }
        if trailingEdge {
            if output.vsync && !crtcLastOutput.vsync {
                saa5050.vsync()
            }
            if videoULA.teletext {
                // Line boundaries come from DISPEN on the SAA5050's LOSE pin.
                if output.display {
                    if !crtcLastOutput.display {
                        saa5050.startOfLine()
                    }
                } else {
                    ic15Byte |= 0x40
                    if crtcLastOutput.display {
                        saa5050.endOfLine()
                    }
                }
            }
        }
        let value = ram[Int(address & videoAddressMask) + videoRAMOffset]
        videoMetadata = Self.videoMetadata(address: address, raster: output.raster, display: output.display,
                                           teletext: videoULA.teletext)
        lastVideoByte = value
        if watchForIdle && output.display {
            screenHash = (screenHash ^ UInt64(value)) &* 0x100_0000_01B3
        }
        if trailingEdge {
            saa5050.byte(ic15Byte, dispen: output.display)
            ic15Byte = output.address & 0x2000 != 0 ? value : 0
        }

        // VideoNuLA starts a line's scroll and blanking as the display
        // comes on (b2 does it for each byte fetched while it was off).
        // Done even in teletext mode: the cursor flag sets up the cursor.
        if nulaFitted {
            nulaByte(value, cudisp: output.cudisp)
        } else {
            videoULA.byte(value, cudisp: output.cudisp)
        }
        crtcLastOutput = output
    }

    /// A byte fetched with VideoNuLA fitted: NuLA starts a line's scroll and
    /// blanking as the display comes on (b2 does it for each byte fetched
    /// while it was off), then the ULA takes the byte.
    private func nulaByte(_ value: UInt8, cudisp: Bool) {
        if !videoULA.teletext && !crtcLastOutput.display {
            nula!.displayEnabled(ula: &videoULA)
        }
        videoULA.byte(value, cudisp: cudisp)
        nula!.originalByte = value
    }

    /// Video output with VideoNuLA fitted: emitVideo, with NuLA's pixels
    /// and colours.
    private func emitVideoNuLA() {
        if videoULA.teletext {
            saa5050.emitPixels(&unit, palette: nula!.outputPalette)
            if videoULA.cursorPattern & 1 != 0 {
                unit.pixels[0] ^= cursorXOR
                unit.pixels[1] ^= cursorXOR
            }
            videoULA.cursorPattern >>= 1
        } else if crtcLastOutput.display && crtcLastOutput.raster < 8 {
            nula!.emit(&unit, ula: &videoULA)
        } else {
            videoULA.emitBlank(&unit)
        }
    }

    @inline(__always)
    private func emitVideo() {
        if nulaFitted {
            emitVideoNuLA()
        } else if videoULA.teletext {
            saa5050.emitPixels(&unit, palette: VideoULA.outputPalette)
            if videoULA.cursorPattern & 1 != 0 {
                unit.pixels[0] ^= cursorXOR
                unit.pixels[1] ^= cursorXOR
            }
            videoULA.cursorPattern >>= 1
        } else if crtcLastOutput.display && crtcLastOutput.raster < 8 {
            videoULA.emitPixels(&unit)
        } else {
            videoULA.emitBlank(&unit)
        }

        var flags: UInt16 = 0
        if crtcLastOutput.hsync { flags |= VideoUnit.hsyncFlag }
        if crtcLastOutput.vsync { flags |= VideoUnit.vsyncFlag }
        unit.pixels[1] = (unit.pixels[1] & 0x0FFF) | flags << 12

        tv?.update(unit, metadata: videoMetadata)
    }

    @inline(__always)
    private func updateTrailingEdge() {
        // CA1 is vsync.
        if !crtcLastOutput.vsync {
            systemVIA.a.c1 = 0
        }

        if let printer {
            printer.tick(&userVIA, cycles: cycles)
        }
        systemVIAIRQ |= systemVIA.updatePhi2TrailingEdge()
        userVIAIRQ |= userVIA.updatePhi2TrailingEdge()
        cpu.setIRQ(IRQDevice.systemVIA, systemVIAIRQ != 0)
        cpu.setIRQ(IRQDevice.userVIA, userVIAIRQ != 0)

        // Cassette and serial, at 1MHz.
        serial.update(tape: tape)
        cpu.setIRQ(IRQDevice.acia, serial.irq)

        // Keyboard. With IC32 bit 3 high the keyboard scans itself and
        // raises CA2 when a key (other than row 0) is down in the current
        // column; otherwise port A selects a key to test.
        if addressableLatch & 0x08 != 0 {
            if keyColumns[keyScanColumn] & 0xFE == 0 {
                systemVIA.a.c2 = 0
            }
            keyScanColumn = (keyScanColumn + 1) & 0x0F
        } else {
            let key = systemVIA.a.p & 0x7F
            let column = keyColumns[Int(key & 0x0F)]
            // Row 0 doesn't cause an interrupt.
            if column & 0xFE == 0 {
                systemVIA.a.c2 = 0
            }
            if column & UInt8(1 << (key >> 4)) == 0 {
                systemVIA.a.p &= 0x7F
            }
        }

        if model == .masterCompact {
            // The digital joystick on the user VIA: PB4 right, 3 up, 2 down,
            // 1 left, 0 fire, active low.
            userVIA.b.p = (userVIA.b.p & ~0x1F) | (0x1F ^ digitalJoystick)
        } else {
            // Analogue joysticks' fire buttons.
            systemVIA.b.p = (systemVIA.b.p & ~0x30) | notJoystickButtons
            mouse.tick(&userVIA, master512: master512 != nil)
        }

        // The disc controller's INT is NMI.
        if let fdc = intel8271 {
            fdc.tick()
            cpu.setNMI(NMIDevice.fdc, fdc.nmi)
        } else if let fdc = wd1770 {
            fdc.tick()
            cpu.setNMI(NMIDevice.fdc, fdc.nmi)
        }

        // ADC end of conversion is CB1.
        systemVIA.b.c1 = adc.update() ? 1 : 0

        // Addressable latch: PB0-2 select a bit, PB3 is its value.
        let pb = systemVIA.b.p
        if pb != oldSystemVIAPB {
            let mask = UInt8(1 << (pb & 7))
            addressableLatch &= ~mask
            if pb & 0x08 != 0 {
                addressableLatch |= mask
            }
            // Master RTC: PB6 is chip select, PB7 address strobe; the
            // address is latched on AS 1->0.
            if model == .master128 && pb & 0x40 != 0 && oldSystemVIAPB & 0x80 != 0 && pb & 0x80 == 0 {
                rtc.setAddress(systemVIA.a.p)
            }
            // Compact EEPROM: PB5 is the clock, PB4 data.
            if model == .masterCompact {
                eeprom.update(clock: pb & 0x20 != 0, data: pb & 0x10 != 0)
            }
            oldSystemVIAPB = pb
        }
        if model == .masterCompact {
            systemVIA.b.p = (systemVIA.b.p & ~0x10) | (eeprom.dataOutput ? 0x10 : 0)
        }

        if model == .master128 {
            // With AS low, latch bit 1 selects read; in write mode, data
            // is written on DS (latch bit 2) 1->0.
            if pb & 0x40 != 0 && pb & 0x80 == 0 {
                if addressableLatch & 0x02 != 0 {
                    systemVIA.a.p &= rtc.read()
                } else if oldAddressableLatch & 0x04 != 0 && addressableLatch & 0x04 == 0 {
                    rtc.setData(systemVIA.a.p)
                }
            }
            rtc.update()
        }
        oldAddressableLatch = addressableLatch
    }
}
